param(
    [string]$NodesFile = ".\operator\nodes.csv",

    [string]$Vps3Alias = "vps3",

    [string]$SshUser = "useradmin",

    [string]$SshKeyFile = ".\operator\vps3\admin_key",

    [string]$RemoteNodesFile = "/tmp/ai-service-platform.nodes.csv",

    [string]$RemotePrepareScript = "/opt/ai-service-platform/tools/bootstrap/prepare_vps3_inventory.sh",

    [string]$Include = ""
)

$ErrorActionPreference = "Stop"
$ExpectedHeader = "current_alias,endpoint,connection,ansible_group,roles,root_password"

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Require-File($Path, $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Label not found: $Path"
    }
}

function New-SanitizedNodesFile($SourcePath) {
    $tempFile = (New-TemporaryFile).FullName
    Set-Content -LiteralPath $tempFile -Value $ExpectedHeader -Encoding ascii

    $lines = Get-Content -LiteralPath $SourcePath
    if (-not $lines -or $lines.Count -eq 0) {
        Fail "nodes.csv is empty: $SourcePath"
    }
    if ($lines[0] -ne $ExpectedHeader) {
        Fail "nodes.csv header must be exactly: $ExpectedHeader"
    }

    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        if (-not $line) {
            continue
        }
        $fields = $line -split ",", 6
        if ($fields.Count -ne 6) {
            Fail "nodes.csv row has invalid column count: $line"
        }
        $fields[5] = ""
        Add-Content -LiteralPath $tempFile -Value ($fields -join ",") -Encoding ascii
    }

    return $tempFile
}

Require-File $NodesFile "NodesFile"
Require-File $SshKeyFile "SshKeyFile"

if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
    Fail "plink not found in PATH"
}
if (-not (Get-Command pscp -ErrorAction SilentlyContinue)) {
    Fail "pscp not found in PATH"
}

$firstLine = Get-Content -LiteralPath $NodesFile -TotalCount 1
if ($firstLine -ne $ExpectedHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedHeader"
}

$rows = Import-Csv -LiteralPath $NodesFile
$vps3 = $rows | Where-Object { $_.current_alias -eq $Vps3Alias } | Select-Object -First 1
if (-not $vps3) {
    Fail "VPS3 alias not found in nodes file: $Vps3Alias"
}
if ($vps3.endpoint -eq "local" -or $vps3.connection -eq "local") {
    Fail "Cannot sync to VPS3 when endpoint/connection is local in operator nodes.csv: $Vps3Alias"
}

$sanitized = New-SanitizedNodesFile $NodesFile
$remote = "$SshUser@$($vps3.endpoint)"

try {
    Write-Host "Syncing sanitized nodes.csv to $remote"
    & pscp -i $SshKeyFile $sanitized "${remote}:$RemoteNodesFile"
    if ($LASTEXITCODE -ne 0) { Fail "pscp sanitized nodes.csv failed" }

    $prepareCommand = "sudo bash '$RemotePrepareScript' --source-nodes-file '$RemoteNodesFile'"
    if ($Include) {
        $prepareCommand = "$prepareCommand --include '$Include'"
    }
    $remoteCommand = "set -e; $prepareCommand; rm -f '$RemoteNodesFile'"

    Write-Host "Running VPS3 inventory preparation"
    & plink -batch -i $SshKeyFile $remote $remoteCommand
    if ($LASTEXITCODE -ne 0) { Fail "remote prepare_vps3_inventory.sh failed" }

    Write-Host "VPS3 nodes.csv and inventory.ini are in sync"
} finally {
    Remove-Item -LiteralPath $sanitized -Force -ErrorAction SilentlyContinue
}
