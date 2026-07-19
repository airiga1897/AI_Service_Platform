param([Parameter(Mandatory=$true)][string]$TargetAlias)

$ErrorActionPreference = "Stop"
$sources = [ordered]@{ redis = "redis:7-alpine"; nginx = "nginx:alpine" }
foreach ($command in @("docker")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "$command не найден в PATH" }
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.site-runtime-support." + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir | Out-Null
$transportTags = @()
try {
    $images = @()
    foreach ($entry in $sources.GetEnumerator()) {
        & docker image pull --platform linux/amd64 $entry.Value
        if ($LASTEXITCODE -ne 0) { throw "Не удалось загрузить support image $($entry.Value)" }
        $inspect = (& docker image inspect $entry.Value | ConvertFrom-Json)[0]
        if ($inspect.Os -ne "linux" -or $inspect.Architecture -ne "amd64") { throw "$($entry.Value) должен иметь platform linux/amd64" }
        $resolvedRef = @($inspect.RepoDigests | Where-Object { $_ -match '^[^@]+@sha256:[0-9a-f]{64}$' })[0]
        if (-not $resolvedRef) { throw "У $($entry.Value) отсутствует immutable RepoDigest" }
        $digest = ($resolvedRef -split '@sha256:', 2)[1]
        $transportTag = "ai-service-platform/site-runtime-support:$($entry.Key)-sha256-$digest"
        & docker image tag $entry.Value $transportTag
        if ($LASTEXITCODE -ne 0) { throw "Не удалось создать transport tag $transportTag" }
        $transportTags += $transportTag
        $images += [ordered]@{
            name = $entry.Key
            source_ref = $entry.Value
            resolved_ref = $resolvedRef
            distribution_digest = "sha256:$digest"
            transport_tag = $transportTag
            config_image_id = $inspect.Id
            platform = "linux/amd64"
        }
    }
    $archivePath = Join-Path $tempDir "support-images.tar"
    & docker image save --output $archivePath @transportTags
    if ($LASTEXITCODE -ne 0) { throw "Не удалось сохранить support images в tar" }
    $archiveSha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifestPath = Join-Path $tempDir "support-images-manifest.json"
    $manifest = [ordered]@{
        schema_version = 1
        kind = "site-runtime-support-images"
        target_alias = $TargetAlias
        platform = "linux/amd64"
        archive_sha256 = $archiveSha
        images = $images
    }
    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ temp_dir=$tempDir; archive_path=$archivePath; manifest_path=$manifestPath } | ConvertTo-Json -Compress
} catch {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    throw
} finally {
    foreach ($tag in $transportTags) { & docker image rm $tag 1>$null 2>$null }
}
