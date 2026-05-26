param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Service,

    [Parameter(Mandatory=$true, Position=1)]
    [ValidateSet("plan", "apply", "absent", "purge", "reseed")]
    [string]$Action,

    [string]$NodesFile = ".\operator\nodes.csv",

    [string]$StateFile = ".\operator\state.csv",

    [string]$Inventory = "inventory.ini",

    [string]$Playbook = "",

    [string]$Limit,

    [switch]$Check,

    [switch]$ConfirmPurge
)

$ErrorActionPreference = "Stop"
$ExpectedHeader = "current_alias,endpoint,connection,root_password"
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
    if (-not $Value) {
        return @()
    }
    return @($Value -split "\+" | Where-Object { $_ })
}

function Require-Command($Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Fail "$Name not found in PATH"
    }
}

function Invoke-External($FilePath, $Arguments) {
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        Fail "$FilePath failed with exit code $LASTEXITCODE"
    }
}

function Get-ServicePlaybook($Name) {
    switch ($Name) {
        "edge_haproxy" { return "infra\ansible\edge_haproxy.yml" }
        "vpn_edge" { return "infra\ansible\vpn.yml" }
        "vpn_cascade" { return "infra\ansible\vpn_cascade.yml" }
        default { Fail "No default playbook for service: $Name" }
    }
}

function Get-ServiceExtraVars($Name, $State, $PurgeData, $ReseedConfig = "false") {
    switch ($Name) {
        "edge_haproxy" {
            return @("-e", "edge_haproxy_state=$State", "-e", "edge_haproxy_purge_data=$PurgeData")
        }
        "vpn_edge" {
            return @("-e", "vpn_state=$State", "-e", "vpn_purge_data=$PurgeData", "-e", "vpn_reseed_config=$ReseedConfig")
        }
        "vpn_cascade" {
            return @("-e", "vpn_cascade_state=$State", "-e", "vpn_cascade_purge_data=$PurgeData", "-e", "vpn_cascade_reseed_config=$ReseedConfig")
        }
        default {
            Fail "Unsupported service '$Name'. Supported now: edge_haproxy, vpn_edge, vpn_cascade."
        }
    }
}

if ($Service -eq "vpn") {
    Fail "Unsupported service 'vpn'. Use canonical service name: vpn_edge"
}
if ($Service -notin @("edge_haproxy", "vpn_edge", "vpn_cascade")) {
    Fail "Unsupported service '$Service'. Supported now: edge_haproxy, vpn_edge, vpn_cascade."
}

Require-File $NodesFile "NodesFile"
Require-File $StateFile "StateFile"

$firstLine = Get-Content -LiteralPath $NodesFile -TotalCount 1
if ($firstLine -ne $ExpectedHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedHeader"
}
$stateFirstLine = Get-Content -LiteralPath $StateFile -TotalCount 1
if ($stateFirstLine -ne $ExpectedStateHeader) {
    Fail "state.csv header must be exactly: $ExpectedStateHeader"
}

$rows = Import-Csv -LiteralPath $NodesFile
$stateRows = Import-Csv -LiteralPath $StateFile
$serviceRow = $stateRows | Where-Object { $_.kind -eq "service" -and $_.name -eq $Service } | Select-Object -First 1
if (-not $serviceRow) {
    Fail "state.csv must contain a service row for $Service"
}
if ($serviceRow.state -notin @("present", "absent", "purged")) {
    Fail "$Service state must be one of: present, absent, purged"
}
if (-not $serviceRow.ansible_group) {
    Fail "$Service ansible_group is empty in state.csv"
}

$desiredNodes = @(Split-AliasList $serviceRow.active_aliases)

if ($Action -eq "plan") {
    Write-Host "Service: $Service"
    Write-Host "State file: $StateFile"
    Write-Host "Service state: $($serviceRow.state)"
    Write-Host "Ansible group: $($serviceRow.ansible_group)"
    Write-Host "Nodes file: $NodesFile"
    Write-Host ""
    foreach ($row in $rows) {
        $desired = "absent"
        if ($serviceRow.state -eq "present" -and ($desiredNodes -contains $row.current_alias)) {
            $desired = "present"
        }
        Write-Host ("{0}: desired {1}" -f $row.current_alias, $desired)
    }
    if ($serviceRow.candidate_aliases) {
        Write-Host ""
        Write-Host "Candidates: $($serviceRow.candidate_aliases)"
    }
    if ($serviceRow.old_aliases) {
        Write-Host "Old: $($serviceRow.old_aliases)"
    }
    exit 0
}

Require-Command ansible-playbook
Require-File $Inventory "Inventory"
if (-not $Playbook) {
    $Playbook = Get-ServicePlaybook $Service
}
Require-File $Playbook "Playbook"

if ($Action -eq "apply" -and $serviceRow.state -ne "present") {
    Fail "$Service apply requires state=present in $StateFile"
}
if ($Action -eq "apply" -and $desiredNodes.Count -eq 0) {
    Fail "No active aliases for $Service found in $StateFile"
}
if ($Action -eq "purge" -and -not $ConfirmPurge) {
    Fail "purge requires -ConfirmPurge"
}
if ($Action -eq "reseed" -and $Service -notin @("vpn_edge", "vpn_cascade")) {
    Fail "reseed is supported only for vpn_edge and vpn_cascade"
}
if ($Action -eq "reseed" -and -not $Limit) {
    Fail "$Service reseed requires -Limit ALIAS"
}
if ($Action -eq "reseed" -and $serviceRow.state -ne "present") {
    Fail "$Service reseed requires state=present in $StateFile"
}

$serviceState = "present"
$servicePurgeData = "false"
if ($Action -eq "absent" -or $Action -eq "purge") {
    $serviceState = "absent"
}
if ($Action -eq "purge") {
    $servicePurgeData = "true"
}
$serviceReseedConfig = "false"
if ($Action -eq "reseed") {
    $serviceReseedConfig = "true"
}

$args = @(
    "-i", $Inventory,
    $Playbook
)
$args += Get-ServiceExtraVars $Service $serviceState $servicePurgeData $serviceReseedConfig

if ($Limit) {
    $args += @("--limit", $Limit)
} else {
    $args += @("--limit", $serviceRow.ansible_group)
}
if ($Check) {
    $args += "--check"
}

Write-Host "Running: ansible-playbook $($args -join ' ')"
Invoke-External "ansible-playbook" $args
