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

    [string]$PolicyRouterImageRef = "",

    [switch]$BuildPolicyRouterImage,

    [switch]$ReinitStandby,

    [switch]$Check,

    [switch]$ConfirmPurge
)

$ErrorActionPreference = "Stop"
$ExpectedHeader = "current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$ExpectedNetworksHeader = "alias,policy_subnet,edge_ip,cascade_ip,cascade_router_ip,policy_gateway_ip"

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

function Split-LimitList($Value) {
    if (-not $Value) {
        return @()
    }
    return @($Value -split "[:+,]" | Where-Object { $_ })
}

function ConvertTo-AnsibleLimit($Value) {
    if (-not $Value) {
        return ""
    }
    return ((Split-LimitList $Value) -join ":")
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
        "policy_gateway" { return "infra\ansible\policy_gateway.yml" }
        "edge_candidate_collector" { return "infra\ansible\edge_candidate_collector.yml" }
        "edge_banlist" { return "infra\ansible\edge_banlist.yml" }
        "postgres_runtime" { return "infra\ansible\postgres_runtime.yml" }
        "softether_l3_vps" { return "infra\ansible\softether_l3_vps.yml" }
        "platform_networks" { return "infra\ansible\platform_networks.yml" }
        default { Fail "No default playbook for service: $Name" }
    }
}

function Get-ServiceExtraVars($Name, $State, $PurgeData, $ReseedConfig = "false", $PolicyRouterImageRef = "", $BuildPolicyRouterImage = $false, $ReinitStandby = $false) {
    switch ($Name) {
        "edge_haproxy" {
            return @("-e", "edge_haproxy_state=$State", "-e", "edge_haproxy_purge_data=$PurgeData")
        }
        "vpn_edge" {
            return @("-e", "vpn_state=$State", "-e", "vpn_purge_data=$PurgeData", "-e", "vpn_reseed_config=$ReseedConfig")
        }
        "vpn_cascade" {
            $vars = @("-e", "vpn_cascade_state=$State", "-e", "vpn_cascade_purge_data=$PurgeData", "-e", "vpn_cascade_reseed_config=$ReseedConfig")
            if ($PolicyRouterImageRef) {
                $vars += @("-e", "vpn_cascade_policy_router_image=$PolicyRouterImageRef", "-e", "vpn_cascade_policy_router_image_explicit=true")
            }
            if ($BuildPolicyRouterImage) {
                $vars += @("-e", "vpn_cascade_build_policy_router_image=true", "-e", "vpn_cascade_policy_router_image_mode=always")
            }
            return $vars
        }
        "policy_gateway" {
            return @("-e", "policy_gateway_state=$State", "-e", "policy_gateway_purge_data=$PurgeData")
        }
        "edge_candidate_collector" {
            return @("-e", "edge_candidate_collector_state=$State", "-e", "edge_candidate_collector_purge_data=$PurgeData")
        }
        "edge_banlist" {
            return @("-e", "edge_banlist_state=$State", "-e", "edge_banlist_purge_data=$PurgeData")
        }
        "postgres_runtime" {
            $reinitValue = if ($ReinitStandby) { "true" } else { "false" }
            return @("-e", "postgres_runtime_state=$State", "-e", "postgres_runtime_purge_data=$PurgeData", "-e", "postgres_runtime_reinit_standby=$reinitValue")
        }
        "softether_l3_vps" {
            return @("-e", "softether_l3_vps_state=$State", "-e", "softether_l3_vps_purge_data=$PurgeData")
        }
        "platform_networks" {
            return @("-e", "platform_networks_state=$State")
        }
        default {
            Fail "Unsupported service '$Name'. Supported now: edge_haproxy, vpn_edge, vpn_cascade, policy_gateway, edge_candidate_collector, edge_banlist, postgres_runtime, softether_l3_vps, platform_networks."
        }
    }
}

if ($Service -eq "vpn") {
    Fail "Unsupported service 'vpn'. Use canonical service name: vpn_edge"
}
if ($Service -notin @("edge_haproxy", "vpn_edge", "vpn_cascade", "policy_gateway", "edge_candidate_collector", "edge_banlist", "postgres_runtime", "softether_l3_vps", "platform_networks")) {
    Fail "Unsupported service '$Service'. Supported now: edge_haproxy, vpn_edge, vpn_cascade, policy_gateway, edge_candidate_collector, edge_banlist, postgres_runtime, softether_l3_vps, platform_networks."
}
if ($PolicyRouterImageRef -and $Service -ne "vpn_cascade") {
    Fail "-PolicyRouterImageRef is supported only for service vpn_cascade"
}
if ($BuildPolicyRouterImage -and $Service -ne "vpn_cascade") {
    Fail "-BuildPolicyRouterImage is supported only for service vpn_cascade"
}
if ($ReinitStandby -and $Service -ne "postgres_runtime") {
    Fail "-ReinitStandby is supported only for service postgres_runtime"
}
if ($ReinitStandby -and $Action -ne "apply") {
    Fail "-ReinitStandby requires action apply"
}
if ($ReinitStandby -and -not $Limit) {
    Fail "-ReinitStandby requires -Limit for the intended standby alias"
}
if ($BuildPolicyRouterImage -and $PolicyRouterImageRef) {
    Fail "-BuildPolicyRouterImage and -PolicyRouterImageRef are mutually exclusive"
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
if ($Service -in @("vpn_edge", "vpn_cascade", "policy_gateway", "softether_l3_vps")) {
    $networksFile = Join-Path (Split-Path -Parent $StateFile) "networks.csv"
    Require-File $networksFile "NetworksFile"
    $networksFirstLine = Get-Content -LiteralPath $networksFile -TotalCount 1
    if ($networksFirstLine -ne $ExpectedNetworksHeader) {
        Fail "networks.csv header must be exactly: $ExpectedNetworksHeader. Run sync_to_orchestration before $Service $Action."
    }
}

$rows = Import-Csv -LiteralPath $NodesFile
$stateRows = Import-Csv -LiteralPath $StateFile
$serviceRows = @($stateRows | Where-Object { $_.kind -eq "service" -and $_.name -eq $Service })
$serviceRow = $null
if ($Limit) {
    $limitAliases = @(Split-LimitList $Limit)
    $coveredAliases = @{}
    $selectedRows = @()
    $selectedActiveAliases = @()
    $selectedCandidateAliases = @()
    $selectedOldAliases = @()
    $selectedGroup = $null
    $selectedState = $null

    foreach ($row in $serviceRows) {
        $active = @(Split-AliasList $row.active_aliases)
        $candidate = @(Split-AliasList $row.candidate_aliases)
        $targetAliases = @($active)
        if ($Service -in @("postgres_runtime", "softether_l3_vps", "platform_networks")) {
            $targetAliases += $candidate
        }
        $rowSelectedAliases = @($limitAliases | Where-Object { $targetAliases -contains $_ })
        if ($rowSelectedAliases.Count -eq 0) {
            continue
        }

        foreach ($alias in $rowSelectedAliases) {
            if ($coveredAliases.ContainsKey($alias)) {
                Fail "state.csv has multiple $Service rows covering alias $alias for -Limit $Limit"
            }
            $coveredAliases[$alias] = $true
        }
        if ($selectedGroup -and $selectedGroup -ne $row.ansible_group) {
            Fail "state.csv has multiple ansible groups for $Service matching -Limit $Limit"
        }
        if ($selectedState -and $selectedState -ne $row.state) {
            Fail "state.csv has mixed states for $Service matching -Limit $Limit"
        }

        $selectedRows += $row
        $selectedGroup = $row.ansible_group
        $selectedState = $row.state
        $selectedActiveAliases += $rowSelectedAliases
        $selectedCandidateAliases += @(Split-AliasList $row.candidate_aliases)
        $selectedOldAliases += @(Split-AliasList $row.old_aliases)
    }

    foreach ($alias in $limitAliases) {
        if (-not $coveredAliases.ContainsKey($alias)) {
            Fail "state.csv must contain a service row for $Service alias $alias matching -Limit $Limit"
        }
    }

    if ($selectedRows.Count -gt 0) {
        $serviceRow = [pscustomobject]@{
            kind = "service"
            name = $Service
            ansible_group = $selectedGroup
            active_aliases = (($selectedActiveAliases | Select-Object -Unique) -join "+")
            candidate_aliases = (($selectedCandidateAliases | Where-Object { $_ } | Select-Object -Unique) -join "+")
            old_aliases = (($selectedOldAliases | Where-Object { $_ } | Select-Object -Unique) -join "+")
            state = $selectedState
        }
    }
} else {
    $serviceRow = $serviceRows | Select-Object -First 1
}
if (-not $serviceRow) {
    if ($Limit) {
        Fail "state.csv must contain a service row for $Service matching -Limit $Limit"
    }
    Fail "state.csv must contain a service row for $Service"
}
if ($serviceRow.state -notin @("present", "absent", "purged")) {
    Fail "$Service state must be one of: present, absent, purged"
}
if (-not $serviceRow.ansible_group) {
    Fail "$Service ansible_group is empty in state.csv"
}

$desiredNodes = @(Split-AliasList $serviceRow.active_aliases)
if ($Service -in @("postgres_runtime", "softether_l3_vps", "platform_networks")) {
    $desiredNodes += @(Split-AliasList $serviceRow.candidate_aliases)
    $desiredNodes = @($desiredNodes | Where-Object { $_ } | Select-Object -Unique)
}

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
    Fail "No active/candidate aliases for $Service found in $StateFile"
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
$args += Get-ServiceExtraVars $Service $serviceState $servicePurgeData $serviceReseedConfig $PolicyRouterImageRef ([bool]$BuildPolicyRouterImage) ([bool]$ReinitStandby)

if ($Limit) {
    $args += @("--limit", (ConvertTo-AnsibleLimit $Limit))
} elseif ($Service -in @("postgres_runtime", "softether_l3_vps", "platform_networks") -and $serviceRow.candidate_aliases) {
    $args += @("--limit", "$($serviceRow.ansible_group):candidate_$($serviceRow.ansible_group)")
} else {
    $args += @("--limit", $serviceRow.ansible_group)
}
if ($Check) {
    $args += "--check"
}

Write-Host "Running: ansible-playbook $($args -join ' ')"
Invoke-External "ansible-playbook" $args
