param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet("vpn")]
    [string]$Service,

    [Parameter(Mandatory=$true, Position=1)]
    [ValidateSet("plan", "apply", "absent", "purge")]
    [string]$Action,

    [string]$NodesFile = ".\operator\nodes.csv",

    [string]$Inventory = "inventory.ini",

    [string]$Playbook = "infra\ansible\vpn.yml",

    [string]$Limit,

    [switch]$Check,

    [switch]$ConfirmPurge
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

function Has-Role($Roles, $Role) {
    return ("+$Roles+").Contains("+$Role+")
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
$firstLine = Get-Content -LiteralPath $NodesFile -TotalCount 1
if ($firstLine -ne $ExpectedHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedHeader"
}

$rows = Import-Csv -LiteralPath $NodesFile
$desiredNodes = @()
foreach ($row in $rows) {
    if (Has-Role $row.roles "vpn-edge") {
        $desiredNodes += $row.current_alias
    }
}

if ($Action -eq "plan") {
    Write-Host "Service: vpn"
    Write-Host "Desired role: vpn-edge"
    Write-Host "Nodes file: $NodesFile"
    Write-Host ""
    foreach ($row in $rows) {
        $state = "absent"
        if (Has-Role $row.roles "vpn-edge") {
            $state = "present"
        }
        Write-Host ("{0}: desired {1}" -f $row.current_alias, $state)
    }
    exit 0
}

Require-Command ansible-playbook
Require-File $Inventory "Inventory"
Require-File $Playbook "Playbook"

if ($desiredNodes.Count -eq 0 -and ($Action -eq "apply")) {
    Fail "No nodes with role vpn-edge found in $NodesFile"
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
    $args += @("--limit", "vpn_edges")
}
if ($Check) {
    $args += "--check"
}

Write-Host "Running: ansible-playbook $($args -join ' ')"
Invoke-External "ansible-playbook" $args
