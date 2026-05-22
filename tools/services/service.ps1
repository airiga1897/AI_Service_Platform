param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet("vpn")]
    [string]$Service,

    [Parameter(Mandatory=$true, Position=1)]
    [ValidateSet("plan", "apply", "absent", "purge")]
    [string]$Action,

    [string]$NodesFile = ".\operator\nodes.csv",

    [string]$StateFile = ".\operator\state.csv",

    [string]$Inventory = "inventory.ini",

    [string]$Playbook = "infra\ansible\vpn.yml",

    [string]$Limit,

    [switch]$Check,

    [switch]$ConfirmPurge
)

$ErrorActionPreference = "Stop"
$ExpectedHeader = "current_alias,endpoint,connection,ansible_group,roles,root_password"
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
$vpnRow = $stateRows | Where-Object { $_.kind -eq "service" -and $_.name -eq "vpn" } | Select-Object -First 1
if (-not $vpnRow) {
    Fail "state.csv must contain a service row for vpn"
}
if ($vpnRow.state -notin @("present", "absent", "purged")) {
    Fail "vpn state must be one of: present, absent, purged"
}
$desiredNodes = @(Split-AliasList $vpnRow.active_aliases)

if ($Action -eq "plan") {
    Write-Host "Service: vpn"
    Write-Host "State file: $StateFile"
    Write-Host "Service state: $($vpnRow.state)"
    Write-Host "Ansible group: $($vpnRow.ansible_group)"
    Write-Host "Nodes file: $NodesFile"
    Write-Host ""
    foreach ($row in $rows) {
        $state = "absent"
        if ($vpnRow.state -eq "present" -and ($desiredNodes -contains $row.current_alias)) {
            $state = "present"
        }
        Write-Host ("{0}: desired {1}" -f $row.current_alias, $state)
    }
    if ($vpnRow.candidate_aliases) {
        Write-Host ""
        Write-Host "Candidates: $($vpnRow.candidate_aliases)"
    }
    if ($vpnRow.old_aliases) {
        Write-Host "Old: $($vpnRow.old_aliases)"
    }
    exit 0
}

Require-Command ansible-playbook
Require-File $Inventory "Inventory"
Require-File $Playbook "Playbook"

if ($desiredNodes.Count -eq 0 -and ($Action -eq "apply")) {
    Fail "No active aliases for vpn found in $StateFile"
}
if ($Action -eq "apply" -and $vpnRow.state -ne "present") {
    Fail "vpn apply requires state=present in $StateFile"
}
if ($Action -eq "purge" -and -not $ConfirmPurge) {
    Fail "purge requires -ConfirmPurge"
}

$vpnState = "present"
$vpnPurgeData = "false"
if ($Action -eq "absent" -or $Action -eq "purge") {
    $vpnState = "absent"
}
if ($Action -eq "purge") {
    $vpnPurgeData = "true"
}

$args = @(
    "-i", $Inventory,
    $Playbook,
    "-e", "vpn_state=$vpnState",
    "-e", "vpn_purge_data=$vpnPurgeData"
)

if ($Limit) {
    $args += @("--limit", $Limit)
} else {
    $args += @("--limit", $vpnRow.ansible_group)
}
if ($Check) {
    $args += "--check"
}

Write-Host "Running: ansible-playbook $($args -join ' ')"
Invoke-External "ansible-playbook" $args
