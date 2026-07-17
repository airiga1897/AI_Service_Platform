param(
    [Parameter(Mandatory=$true)][string]$Instance,
    [Parameter(Mandatory=$true)][string]$ImageRef,
    [Parameter(Mandatory=$true)][string]$TargetAlias
)

$ErrorActionPreference = "Stop"
if ($ImageRef -notmatch '^(?<repository>[a-z0-9.-]+(?:/[a-z0-9._-]+)+)@sha256:(?<digest>[0-9a-f]{64})$') {
    throw "ImageRef must be an immutable repository@sha256 digest"
}
$distributionDigest = "sha256:$($matches.digest)"
$digestHex = $matches.digest
$originalDockerConfig = [Environment]::GetEnvironmentVariable("DOCKER_CONFIG", "Process")
$transportTag = $null
foreach ($command in @("gh", "docker")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "$command not found in PATH" }
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.site-runtime-image." + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $env:DOCKER_CONFIG = Join-Path $tempDir "docker-config"
    New-Item -ItemType Directory -Path $env:DOCKER_CONFIG | Out-Null
    & gh auth status --hostname github.com 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) { throw "gh authentication for github.com is required" }
    $username = (& gh api user --jq .login).Trim()
    $token = (& gh auth token --hostname github.com).Trim()
    if (-not $username -or -not $token) { throw "failed to resolve gh username/token" }
    $login = New-Object System.Diagnostics.Process
    $login.StartInfo.FileName = (Get-Command docker).Source
    $login.StartInfo.Arguments = "login ghcr.io --username $username --password-stdin"
    $login.StartInfo.UseShellExecute = $false
    $login.StartInfo.RedirectStandardInput = $true
    $login.StartInfo.RedirectStandardOutput = $true
    $login.StartInfo.RedirectStandardError = $true
    [void]$login.Start()
    $login.StandardInput.WriteLine($token)
    $login.StandardInput.Close()
    $token = $null
    $login.WaitForExit()
    if ($login.ExitCode -ne 0) { throw "docker login to ghcr.io failed" }

    & docker image pull --platform linux/amd64 $ImageRef
    if ($LASTEXITCODE -ne 0) { throw "docker pull failed" }
    $inspect = (& docker image inspect $ImageRef | ConvertFrom-Json)[0]
    if ($inspect.RepoDigests -notcontains $ImageRef) { throw "pulled image RepoDigests does not contain requested identity" }
    if ($inspect.Os -ne "linux" -or $inspect.Architecture -ne "amd64") { throw "image platform must be linux/amd64" }

    # Одноразовые данные авторизации больше не нужны после проверенного pull.
    if ($null -eq $originalDockerConfig) {
        Remove-Item Env:DOCKER_CONFIG -ErrorAction SilentlyContinue
    } else {
        $env:DOCKER_CONFIG = $originalDockerConfig
    }
    Remove-Item -LiteralPath (Join-Path $tempDir "docker-config") -Recurse -Force -ErrorAction SilentlyContinue

    $transportTag = "ai-service-platform/site-runtime-import:${Instance}-sha256-$digestHex"
    & docker image tag $ImageRef $transportTag
    if ($LASTEXITCODE -ne 0) { throw "failed to create transport tag" }
    $archivePath = Join-Path $tempDir "image.tar"
    & docker image save --output $archivePath $transportTag
    if ($LASTEXITCODE -ne 0) { throw "docker image save failed" }
    $archiveSha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifestPath = Join-Path $tempDir "manifest.json"
    $labels = if ($inspect.Config.Labels) { $inspect.Config.Labels } else { @{} }
    $manifest = [ordered]@{
        schema_version = 1
        instance = $Instance
        target_alias = $TargetAlias
        image_ref = $ImageRef
        distribution_digest = $distributionDigest
        transport_tag = $transportTag
        config_image_id = $inspect.Id
        platform = "linux/amd64"
        archive_sha256 = $archiveSha
        source_label = $labels.'org.opencontainers.image.source'
        revision_label = $labels.'org.opencontainers.image.revision'
        version_label = $labels.'org.opencontainers.image.version'
    }
    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ temp_dir=$tempDir; archive_path=$archivePath; manifest_path=$manifestPath; transport_tag=$transportTag; config_image_id=$inspect.Id } | ConvertTo-Json -Compress
} catch {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    throw
} finally {
    if ($transportTag) {
        & docker image rm $transportTag 1>$null 2>$null
    }
    if ($null -eq $originalDockerConfig) {
        Remove-Item Env:DOCKER_CONFIG -ErrorAction SilentlyContinue
    } else {
        $env:DOCKER_CONFIG = $originalDockerConfig
    }
}
