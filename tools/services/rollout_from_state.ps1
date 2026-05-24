param(
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$StateFile = ".\operator\state.csv",
    [string]$OperatorDir = ".\operator",
    [string]$ControlRole = "orchestration",
    [string]$ControlAlias = "",
    [string]$SyncScript = "tools/bootstrap/sync_to_orchestration.ps1",
    [string]$ServiceRemoteScript = "tools/services/service_remote.ps1",
    [switch]$AutoAcceptHostKey,
    [switch]$SkipSync,
    [switch]$SkipPostcheck
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,connection,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$SupportedServices = @("edge_haproxy", "vpn_edge")
$ReservedServices = @("vpn_cascade")

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

function Invoke-ChildScript($ScriptPath, $Arguments, $Label) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label failed with exit code $LASTEXITCODE"
    }
}

function Invoke-ServiceRemote($Service, $Action, $Limit, [switch]$Check, [switch]$ConfirmPurge) {
    $args = @(
        $Service,
        $Action,
        "-NodesFile", $NodesFile,
        "-StateFile", $StateFile,
        "-OperatorDir", $OperatorDir,
        "-ControlRole", $ControlRole
    )
    if ($ControlAlias) { $args += @("-ControlAlias", $ControlAlias) }
    if ($Limit) { $args += @("-Limit", $Limit) }
    if ($Check) { $args += "-Check" }
    if ($ConfirmPurge) { $args += "-ConfirmPurge" }
    Invoke-ChildScript $ServiceRemoteScript $args "$Service $Action"
}

function Invoke-Sync() {
    $args = @(
        "-NodesFile", $NodesFile,
        "-StateFile", $StateFile,
        "-OperatorDir", $OperatorDir,
        "-ControlRole", $ControlRole
    )
    if ($ControlAlias) { $args += @("-ControlAlias", $ControlAlias) }
    if ($AutoAcceptHostKey) { $args += "-AutoAcceptHostKey" }
    Invoke-ChildScript $SyncScript $args "sync to orchestration"
}

function Invoke-Postcheck($Service, $State, $Alias) {
    if ($SkipPostcheck) {
        Write-Host "Postcheck skipped for $Service on $Alias"
        return
    }

    switch ($Service) {
        "edge_haproxy" {
            switch ($State) {
                "present" {
                    Invoke-ServiceRemote $Service "plan" $Alias
                    Write-Host "[OK] edge_haproxy postcheck placeholder completed for $Alias"
                }
                "absent" {
                    Write-Host "[OK] edge_haproxy absent requested for $Alias; config/data should remain on target"
                }
                "purged" {
                    Write-Host "[OK] edge_haproxy purge requested for $Alias; runtime directory removal is handled by the role"
                }
            }
        }
        default {
            Write-Host "No postcheck implemented yet for $Service on $Alias"
        }
    }
}

Require-File $NodesFile "NodesFile"
Require-File $StateFile "StateFile"
Require-File $SyncScript "SyncScript"
Require-File $ServiceRemoteScript "ServiceRemoteScript"

$nodesHeader = Get-Content -LiteralPath $NodesFile -TotalCount 1
if ($nodesHeader -ne $ExpectedNodesHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedNodesHeader"
}
$stateHeader = Get-Content -LiteralPath $StateFile -TotalCount 1
if ($stateHeader -ne $ExpectedStateHeader) {
    Fail "state.csv header must be exactly: $ExpectedStateHeader"
}

$stateRows = Import-Csv -LiteralPath $StateFile
$serviceRows = @($stateRows | Where-Object { $_.kind -eq "service" })
if ($serviceRows.Count -eq 0) {
    Fail "state.csv has no service rows"
}

if (-not $SkipSync) {
    Write-Host "Step 1/3: sync operator state to active orchestration node"
    Invoke-Sync
} else {
    Write-Host "Step 1/3: sync skipped by -SkipSync"
}

$summary = New-Object System.Collections.Generic.List[string]
Write-Host ""
Write-Host "Step 2/3: rollout services from state.csv"

foreach ($serviceRow in $serviceRows) {
    $service = $serviceRow.name
    $state = $serviceRow.state
    $aliases = @(Split-AliasList $serviceRow.active_aliases)

    if ($state -notin @("present", "absent", "purged")) {
        Fail "$service state must be one of: present, absent, purged"
    }

    if ($ReservedServices -contains $service) {
        Write-Host "${service}: reserved/not implemented; skipped"
        $summary.Add("${service}: skipped reserved") | Out-Null
        continue
    }
    if ($SupportedServices -notcontains $service) {
        Write-Host "${service}: not implemented yet; skipped"
        $summary.Add("${service}: skipped not implemented") | Out-Null
        continue
    }

    Write-Host ""
    Write-Host "Service: $service"
    Write-Host "State:   $state"
    Invoke-ServiceRemote $service "plan" ""

    if ($aliases.Count -eq 0) {
        if ($state -eq "present") {
            Fail "$service has state=present but active_aliases is empty"
        }
        Write-Host "${service}: no active_aliases for state=$state; no-op"
        $summary.Add("${service}: no-op") | Out-Null
        continue
    }

    foreach ($alias in $aliases) {
        if ($state -eq "present") {
            Write-Host "$service on ${alias}: dry-run"
            Invoke-ServiceRemote $service "apply" $alias -Check
            Write-Host "$service on ${alias}: apply"
            Invoke-ServiceRemote $service "apply" $alias
            Invoke-Postcheck $service $state $alias
            $summary.Add("$service ${alias}: present") | Out-Null
        } elseif ($state -eq "absent") {
            Write-Host "$service on ${alias}: absent"
            Invoke-ServiceRemote $service "absent" $alias
            Invoke-Postcheck $service $state $alias
            $summary.Add("$service ${alias}: absent") | Out-Null
        } elseif ($state -eq "purged") {
            Write-Host "$service on ${alias}: purge"
            Invoke-ServiceRemote $service "purge" $alias -ConfirmPurge
            Invoke-Postcheck $service $state $alias
            $summary.Add("$service ${alias}: purged") | Out-Null
        }
    }
}

Write-Host ""
Write-Host "Step 3/3: summary"
foreach ($item in $summary) {
    Write-Host "  $item"
}
Write-Host "Rollout from state completed."
