param(
    [Parameter(Mandatory=$true)]
    [string]$Alias,

    [string]$NodesFile = ".\operator\nodes.csv",

    [string]$StateFile = ".\operator\state.csv",

    [string]$OperatorDir = ".\operator",

    [string]$ControlRole = "orchestration",

    [string]$SyncScript = "tools/bootstrap/sync_to_orchestration.ps1",

    [string]$SshUser = "useradmin",

    [string]$SshKeyFile = "",

    [string]$Include = "",

    [switch]$AutoAcceptHostKey,

    [switch]$SkipVerify,

    [switch]$SkipServicePlan
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,connection,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Require-File($Path, $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Label not found: $Path"
    }
}

function Split-AliasList($Value) {
    if (-not $Value) { return @() }
    return @($Value -split "\+" | Where-Object { $_ })
}

function Join-AliasList($Aliases) {
    return (@($Aliases | Where-Object { $_ }) -join "+")
}

function Write-StateCsv($Path, $Rows) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($ExpectedStateHeader)
    foreach ($row in $Rows) {
        $lines.Add(("{0},{1},{2},{3},{4},{5},{6}" -f
            $row.kind,
            $row.name,
            $row.ansible_group,
            $row.active_aliases,
            $row.candidate_aliases,
            $row.old_aliases,
            $row.state))
    }
    Set-Content -LiteralPath $Path -Value $lines -Encoding ascii
}

function Invoke-ChildScript($ScriptPath, $Arguments, $Label) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label failed with exit code $LASTEXITCODE"
    }
}

Require-File $NodesFile "NodesFile"
Require-File $StateFile "StateFile"
Require-File $SyncScript "SyncScript"

$nodesHeader = Get-Content -LiteralPath $NodesFile -TotalCount 1
if ($nodesHeader -ne $ExpectedNodesHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedNodesHeader"
}
$stateHeader = Get-Content -LiteralPath $StateFile -TotalCount 1
if ($stateHeader -ne $ExpectedStateHeader) {
    Fail "state.csv header must be exactly: $ExpectedStateHeader"
}

$nodeRows = Import-Csv -LiteralPath $NodesFile
$targetNode = $nodeRows | Where-Object { $_.current_alias -eq $Alias } | Select-Object -First 1
if (-not $targetNode) {
    Fail "Standby orchestration alias '$Alias' is not present in nodes.csv"
}
if ($targetNode.connection -ne "ssh" -or $targetNode.endpoint -eq "local") {
    Fail "Standby orchestration alias '$Alias' must use connection=ssh and a real endpoint in nodes.csv"
}

$stateRows = @(Import-Csv -LiteralPath $StateFile)
$roleRows = @($stateRows | Where-Object { ($_.kind -eq "platform_role" -or $_.kind -eq "role") -and $_.name -eq $ControlRole -and $_.state -eq "present" })
if ($roleRows.Count -eq 0) {
    Fail "state.csv has no present platform_role '$ControlRole'"
}
if ($roleRows.Count -gt 1) {
    Fail "state.csv has multiple present platform_role '$ControlRole' rows; keep exactly one"
}

$roleRow = $roleRows[0]
$activeAliases = @(Split-AliasList $roleRow.active_aliases)
$candidateAliases = @(Split-AliasList $roleRow.candidate_aliases)
$oldAliases = @(Split-AliasList $roleRow.old_aliases)

if ($activeAliases.Count -ne 1) {
    Fail "platform_role '$ControlRole' must have exactly one active alias before preparing standby"
}
if ($activeAliases[0] -eq $Alias) {
    Fail "Alias '$Alias' is already active for '$ControlRole'; standby preparation expects a candidate alias"
}
if ($candidateAliases -notcontains $Alias) {
    Fail "Alias '$Alias' must be listed in candidate_aliases for platform_role '$ControlRole'"
}

$tempState = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.standby-state." + [guid]::NewGuid().ToString("N") + ".csv")
try {
    $promotedRows = @()
    foreach ($row in $stateRows) {
        $copy = [pscustomobject]@{
            kind = $row.kind
            name = $row.name
            ansible_group = $row.ansible_group
            active_aliases = $row.active_aliases
            candidate_aliases = $row.candidate_aliases
            old_aliases = $row.old_aliases
            state = $row.state
        }
        if (($copy.kind -eq "platform_role" -or $copy.kind -eq "role") -and $copy.name -eq $ControlRole -and $copy.state -eq "present") {
            $copy.kind = "platform_role"
            $copy.active_aliases = $Alias
            $copy.candidate_aliases = Join-AliasList (@($candidateAliases | Where-Object { $_ -ne $Alias }))
            $copy.old_aliases = Join-AliasList (@($oldAliases + $activeAliases | Select-Object -Unique))
        }
        $promotedRows += $copy
    }

    Write-StateCsv $tempState $promotedRows

    Write-Host "Preparing standby orchestration node '$Alias'"
    Write-Host "Current active orchestration remains local state: $($activeAliases[0])"
    Write-Host "Temporary promotion state will be synced only to standby: $Alias"

    $args = @(
        "-NodesFile", $NodesFile,
        "-StateFile", $tempState,
        "-OperatorDir", $OperatorDir,
        "-ControlRole", $ControlRole,
        "-SshUser", $SshUser,
        "-ControlAlias", $Alias
    )
    if ($SshKeyFile) { $args += @("-SshKeyFile", $SshKeyFile) }
    if ($Include) { $args += @("-Include", $Include) }
    if ($AutoAcceptHostKey) { $args += "-AutoAcceptHostKey" }
    if ($SkipVerify) { $args += "-SkipVerify" }
    if ($SkipServicePlan) { $args += "-SkipServicePlan" }

    Invoke-ChildScript $SyncScript $args "standby orchestration preparation"

    Write-Host ""
    Write-Host "[OK] Standby orchestration node '$Alias' prepared"
    Write-Host "Local $StateFile was not modified. To promote manually, set active_aliases=$Alias for platform_role '$ControlRole'."
} finally {
    Remove-Item -LiteralPath $tempState -Force -ErrorAction SilentlyContinue
}
