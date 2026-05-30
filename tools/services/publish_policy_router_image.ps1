[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Dockerfile = ".\infra\docker\policy-router\Dockerfile",
    [string]$ContextDir = ".\infra\docker\policy-router",
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$StateFile = ".\operator\state.csv",
    [string]$OperatorDir = ".\operator",
    [string[]]$Alias = @(),
    [string]$ImageRepository = "ai-service-platform/policy-router",
    [string]$ImageRef = "",
    [string]$SshUser = "useradmin",
    [string]$SshPath = "ssh",
    [string]$ScpPath = "scp",
    [int]$TimeoutSeconds = 20,
    [switch]$AutoAcceptHostKey = $true,
    [switch]$Plan
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,connection,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"

. (Join-Path $PSScriptRoot "..\common\private_key_acl.ps1")

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Require-File($Path, $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Label not found: $Path"
    }
}

function Require-Command($Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Fail "$Name not found in PATH"
    }
}

function Quote-BashArg($Value) {
    $text = [string]$Value
    return "'" + ($text -replace "'", "'\''") + "'"
}

function Split-AliasList($Value) {
    if (-not $Value) {
        return @()
    }
    return @($Value -split "\+" | Where-Object { $_ })
}

function Get-OpenSshCommonArgs($KeyFile) {
    $args = @(
        "-i", $KeyFile,
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=$TimeoutSeconds",
        "-o", "IdentitiesOnly=yes",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "PasswordAuthentication=no",
        "-o", "PreferredAuthentications=publickey",
        "-o", "RequestTTY=no"
    )
    if ($AutoAcceptHostKey) {
        $args += @("-o", "StrictHostKeyChecking=accept-new")
    }
    return $args
}

function Invoke-External($FilePath, $Arguments, $Label) {
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label failed with exit code $LASTEXITCODE"
    }
}

function Invoke-ExternalCapture($FilePath, $Arguments, $Label) {
    $output = & $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ }
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label failed with exit code $LASTEXITCODE`n$(@($output) -join "`n")"
    }
    return @($output) -join "`n"
}

function Get-GitShortSha {
    try {
        $output = @(& git rev-parse --short=12 HEAD 2>$null)
        if ($output.Count -gt 0 -and $output[0]) {
            return [string]$output[0]
        }
    } catch {
    }
    return "nogit"
}

function Get-PolicyRouterAliases($StateFilePath) {
    Require-File $StateFilePath "StateFile"
    $stateHeader = Get-Content -LiteralPath $StateFilePath -TotalCount 1
    if ($stateHeader -ne $ExpectedStateHeader) {
        Fail "state.csv header must be exactly: $ExpectedStateHeader"
    }
    $rows = @(Import-Csv -LiteralPath $StateFilePath | Where-Object {
        $_.kind -eq "service" -and $_.name -eq "vpn_cascade" -and $_.state -eq "present"
    })
    if ($rows.Count -ne 1) {
        Fail "state.csv must contain exactly one present service row for vpn_cascade"
    }
    $aliases = @(Split-AliasList $rows[0].active_aliases)
    if ($aliases.Count -eq 0) {
        Fail "vpn_cascade service row has no active_aliases"
    }
    return $aliases
}

function Resolve-SshExecutable($Path, $Label) {
    try {
        return [string](Get-Command $Path -ErrorAction Stop).Path
    } catch {
        Fail "$Label executable not found: $Path"
    }
}

Require-File $Dockerfile "Dockerfile"
if (-not (Test-Path -LiteralPath $ContextDir -PathType Container)) {
    Fail "ContextDir not found: $ContextDir"
}
Require-File $NodesFile "NodesFile"
$nodesHeader = Get-Content -LiteralPath $NodesFile -TotalCount 1
if ($nodesHeader -ne $ExpectedNodesHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedNodesHeader"
}

$nodes = @{}
foreach ($row in @(Import-Csv -LiteralPath $NodesFile)) {
    $nodes[[string]$row.current_alias] = $row
}

$targetAliases = @($Alias | Where-Object { $_ })
if ($targetAliases.Count -eq 0) {
    $targetAliases = @(Get-PolicyRouterAliases $StateFile)
}
foreach ($aliasName in $targetAliases) {
    if (-not $nodes.ContainsKey($aliasName)) {
        Fail "nodes.csv has no row for alias: $aliasName"
    }
    if ($nodes[$aliasName].connection -ne "ssh") {
        Fail "alias $aliasName must use connection=ssh"
    }
    $keyFile = Join-Path (Join-Path $OperatorDir $aliasName) "admin_key"
    Require-File $keyFile "admin key for $aliasName"
}

$dockerfileHash = (Get-FileHash -LiteralPath $Dockerfile -Algorithm SHA256).Hash.ToLowerInvariant().Substring(0, 12)
if (-not $ImageRef) {
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $ImageRef = "${ImageRepository}:${stamp}-$(Get-GitShortSha)-$dockerfileHash"
}

$effectivePlan = [bool]$Plan -or [bool]$WhatIfPreference
$sshExe = Resolve-SshExecutable $SshPath "SSH"
$scpExe = Resolve-SshExecutable $ScpPath "SCP"

Write-Host "Policy-router image ref: $ImageRef"
Write-Host "Dockerfile:              $Dockerfile"
Write-Host "Context:                 $ContextDir"
Write-Host "Targets:                 $($targetAliases -join ', ')"
Write-Host ""

if ($effectivePlan) {
    Write-Host "[plan] docker build -t $ImageRef -f $Dockerfile $ContextDir"
    foreach ($aliasName in $targetAliases) {
        $node = $nodes[$aliasName]
        Write-Host "[plan] docker save/load $ImageRef -> $aliasName ($($node.endpoint))"
    }
    Write-Host ""
    Write-Host "Rollout command after publish:"
    Write-Host ".\tools\services\service_remote.ps1 vpn_cascade apply -Limit $($targetAliases -join '+') -PolicyRouterImageRef $ImageRef -DetachedRemoteJob"
    exit 0
}

Require-Command "docker"

foreach ($aliasName in $targetAliases) {
    $keyFile = Join-Path (Join-Path $OperatorDir $aliasName) "admin_key"
    Ensure-OpenSshPrivateKeyAcl $keyFile
}

if ($PSCmdlet.ShouldProcess($ImageRef, "build policy-router image")) {
    Invoke-External "docker" @("build", "-t", $ImageRef, "-f", $Dockerfile, $ContextDir) "docker build"
}
$localImageId = (Invoke-ExternalCapture "docker" @("image", "inspect", "--format", "{{.Id}}", $ImageRef) "local docker image inspect").Trim()
Invoke-External "docker" @("run", "--rm", "--network", "none", $ImageRef, "sh", "-c", "ip -V >/dev/null && iptables --version >/dev/null") "local policy-router smoke test"

$archivePath = Join-Path ([System.IO.Path]::GetTempPath()) ("policy-router." + [guid]::NewGuid().ToString("N") + ".tar")
try {
    Invoke-External "docker" @("save", "-o", $archivePath, $ImageRef) "docker save"
    foreach ($aliasName in $targetAliases) {
        $node = $nodes[$aliasName]
        $keyFile = Join-Path (Join-Path $OperatorDir $aliasName) "admin_key"
        $remote = "${SshUser}@$($node.endpoint)"
        $remoteTar = "/tmp/ai-service-platform-policy-router-$([guid]::NewGuid().ToString('N')).tar"
        $sshArgs = @("-n", "-T") + @(Get-OpenSshCommonArgs $keyFile)
        $scpArgs = @("-B") + @(Get-OpenSshCommonArgs $keyFile)

        Write-Host "[publish] Uploading $ImageRef to $aliasName..."
        Invoke-External $scpExe ($scpArgs + @($archivePath, "${remote}:$remoteTar")) "scp image archive to $aliasName"
        try {
            $loadCommand = @(
                "set -e",
                "sudo docker load -i $(Quote-BashArg $remoteTar) >/dev/null",
                "sudo rm -f $(Quote-BashArg $remoteTar)",
                "sudo docker image inspect --format '{{.Id}}' $(Quote-BashArg $ImageRef)",
                "sudo docker run --rm --network none $(Quote-BashArg $ImageRef) sh -c $(Quote-BashArg "ip -V >/dev/null && iptables --version >/dev/null")"
            ) -join "; "
            $remoteOutput = Invoke-ExternalCapture $sshExe ($sshArgs + @($remote, $loadCommand)) "remote docker load/verify on $aliasName"
            $remoteImageId = [string](@($remoteOutput -split "`n" | Where-Object { $_ -match '^sha256:' } | Select-Object -First 1))
            if ([string]::IsNullOrWhiteSpace($remoteImageId)) {
                Fail "remote image inspect did not return an image ID on ${aliasName}: $remoteOutput"
            }
            if ($remoteImageId -ne $localImageId) {
                Fail "remote image ID mismatch on ${aliasName}: local=$localImageId remote=$remoteImageId"
            }
            Write-Host "[OK] $aliasName has $ImageRef ($remoteImageId)"
        } catch {
            Invoke-ExternalCapture $sshExe ($sshArgs + @($remote, "rm -f $(Quote-BashArg $remoteTar) 2>/dev/null || true")) "remote archive cleanup on $aliasName" | Out-Null
            throw
        }
    }
} finally {
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "[OK] policy-router image published to: $($targetAliases -join ', ')"
Write-Host "ImageRef: $ImageRef"
Write-Host "ImageId:  $localImageId"
Write-Host ""
Write-Host "Next rollout command:"
Write-Host ".\tools\services\service_remote.ps1 vpn_cascade apply -Limit $($targetAliases -join '+') -PolicyRouterImageRef $ImageRef -DetachedRemoteJob"
