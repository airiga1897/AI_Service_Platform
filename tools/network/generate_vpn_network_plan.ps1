param(
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$StateFile = ".\operator\state.csv",
    [string]$OverrideFile = ".\operator\networks.override.csv",
    [string]$OutputFile = ".\operator\networks.csv",
    [switch]$Check,
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$ExpectedNetworkHeader = "alias,policy_subnet,edge_ip,cascade_ip,cascade_router_ip,policy_gateway_ip"

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

function Expand-StateAliasToken($Token, $Kind) {
    if ($Kind -eq "cascade_topology" -and $Token -match "^([^>]+)>([^>]+)$") {
        return @($Matches[1], $Matches[2])
    }
    return @($Token)
}

function ConvertTo-IPv4Int($Address) {
    $parts = @([string]$Address -split "\.")
    if ($parts.Count -ne 4) {
        Fail "Invalid IPv4 address: $Address"
    }
    $value = [uint32]0
    foreach ($part in $parts) {
        if ($part -notmatch '^\d+$') {
            Fail "Invalid IPv4 address: $Address"
        }
        $octet = [int]$part
        if ($octet -lt 0 -or $octet -gt 255) {
            Fail "Invalid IPv4 address: $Address"
        }
        $value = ($value -shl 8) -bor [uint32]$octet
    }
    return $value
}

function Get-CidrRange($Cidr) {
    if ($Cidr -notmatch '^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/([0-9]{1,2})$') {
        Fail "Invalid CIDR: $Cidr"
    }
    $ip = ConvertTo-IPv4Int $Matches[1]
    $prefix = [int]$Matches[2]
    if ($prefix -lt 1 -or $prefix -gt 32) {
        Fail "Invalid CIDR prefix: $Cidr"
    }
    $allOnes = [uint64]4294967295
    $mask = if ($prefix -eq 32) { [uint32]4294967295 } else { [uint32](($allOnes -shl (32 - $prefix)) -band $allOnes) }
    $network = [uint32]($ip -band $mask)
    $broadcast = [uint32]($network + ([uint32]4294967295 -bxor $mask))
    return @{ Start = $network; End = $broadcast }
}

function Test-CidrOverlap($Left, $Right) {
    $a = Get-CidrRange $Left
    $b = Get-CidrRange $Right
    return $a.Start -le $b.End -and $b.Start -le $a.End
}

function Validate-Header($Path, $Expected) {
    $first = Get-Content -LiteralPath $Path -TotalCount 1
    if ($first -ne $Expected) {
        Fail "$(Split-Path -Leaf $Path) header must be exactly: $Expected"
    }
}

Require-File $NodesFile "NodesFile"
Require-File $StateFile "StateFile"
Validate-Header $NodesFile $ExpectedNodesHeader
Validate-Header $StateFile $ExpectedStateHeader

$nodes = @(Import-Csv -LiteralPath $NodesFile | Where-Object { $_.current_alias })
$stateRows = @(Import-Csv -LiteralPath $StateFile)
$nodeAliases = @{}
foreach ($node in $nodes) {
    if ($nodeAliases.ContainsKey($node.current_alias)) {
        Fail "nodes.csv has duplicate alias: $($node.current_alias)"
    }
    $nodeAliases[$node.current_alias] = $true
}

$referenced = @{}
foreach ($row in $stateRows) {
    foreach ($field in @("active_aliases", "candidate_aliases")) {
        foreach ($token in (Split-AliasList $row.$field)) {
            foreach ($alias in (Expand-StateAliasToken $token $row.kind)) {
                if (-not $nodeAliases.ContainsKey($alias)) {
                    Fail "state.csv references alias '$alias' in $($row.kind):$($row.name), but nodes.csv has no such alias"
                }
                $referenced[$alias] = $true
            }
        }
    }
    foreach ($token in (Split-AliasList $row.old_aliases)) {
        foreach ($alias in (Expand-StateAliasToken $token $row.kind)) {
            if ($nodeAliases.ContainsKey($alias)) {
                $referenced[$alias] = $true
            }
        }
    }
}

$overrides = @{}
if (Test-Path -LiteralPath $OverrideFile -PathType Leaf) {
    Validate-Header $OverrideFile $ExpectedNetworkHeader
    foreach ($row in @(Import-Csv -LiteralPath $OverrideFile)) {
        if (-not $row.alias) {
            continue
        }
        if (-not $nodeAliases.ContainsKey($row.alias)) {
            Fail "networks override references unknown alias: $($row.alias)"
        }
        if ($overrides.ContainsKey($row.alias)) {
            Fail "networks override has duplicate alias: $($row.alias)"
        }
        $overrides[$row.alias] = $row
    }
}

$plan = @()
foreach ($node in ($nodes | Sort-Object current_alias)) {
    $alias = [string]$node.current_alias
    if ($overrides.ContainsKey($alias)) {
        $item = $overrides[$alias]
    } elseif ($alias -match '^vps([1-9][0-9]{0,2})$') {
        $n = [int]$Matches[1]
        if ($n -lt 1 -or $n -gt 254) {
            Fail "Alias '$alias' maps to unsupported VPS number $n; expected 1..254"
        }
        $networkId = 255 - $n
        $item = [pscustomobject]@{
            alias = $alias
            policy_subnet = "172.22.$networkId.0/24"
            edge_ip = "172.22.$networkId.2"
            cascade_ip = "172.22.$networkId.3"
            cascade_router_ip = "172.23.0.$networkId"
            policy_gateway_ip = "172.22.$networkId.4"
        }
    } else {
        Fail "Alias '$alias' is not vpsN. Add an explicit row to $OverrideFile"
    }
    $plan += [pscustomobject]@{
        alias = [string]$item.alias
        policy_subnet = [string]$item.policy_subnet
        edge_ip = [string]$item.edge_ip
        cascade_ip = [string]$item.cascade_ip
        cascade_router_ip = [string]$item.cascade_router_ip
        policy_gateway_ip = [string]$item.policy_gateway_ip
    }
}

$seenSubnets = @{}
$seenIps = @{}
$reserved = @("172.20.0.0/24", "172.21.0.0/24")
foreach ($row in $plan) {
    foreach ($reservedCidr in $reserved) {
        if (Test-CidrOverlap $row.policy_subnet $reservedCidr) {
            Fail "Policy subnet for $($row.alias) overlaps reserved network ${reservedCidr}: $($row.policy_subnet)"
        }
    }
    if ($seenSubnets.ContainsKey($row.policy_subnet)) {
        Fail "Duplicate policy_subnet $($row.policy_subnet) for $($row.alias) and $($seenSubnets[$row.policy_subnet])"
    }
    $seenSubnets[$row.policy_subnet] = $row.alias
    foreach ($field in @("edge_ip", "cascade_ip", "cascade_router_ip", "policy_gateway_ip")) {
        $ip = $row.$field
        [void](ConvertTo-IPv4Int $ip)
        if ($seenIps.ContainsKey($ip)) {
            Fail "Duplicate IP $ip for $($row.alias).$field and $($seenIps[$ip])"
        }
        $seenIps[$ip] = "$($row.alias).$field"
    }
    $range = Get-CidrRange $row.policy_subnet
    foreach ($field in @("edge_ip", "cascade_ip", "policy_gateway_ip")) {
        $ipInt = ConvertTo-IPv4Int $row.$field
        if ($ipInt -lt $range.Start -or $ipInt -gt $range.End) {
            Fail "$($row.alias).$field $($row.$field) is outside $($row.policy_subnet)"
        }
    }
}

if ($Check) {
    Write-Host "[OK] VPN network plan is valid for $($plan.Count) aliases"
} else {
    $outputDir = Split-Path -Parent $OutputFile
    if ($outputDir) {
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    }
    $lines = @($ExpectedNetworkHeader)
    foreach ($row in $plan) {
        $lines += ("{0},{1},{2},{3},{4},{5}" -f $row.alias, $row.policy_subnet, $row.edge_ip, $row.cascade_ip, $row.cascade_router_ip, $row.policy_gateway_ip)
    }
    $newContent = ($lines -join "`r`n") + "`r`n"
    if (Test-Path -LiteralPath $OutputFile -PathType Leaf) {
        $existingContent = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $OutputFile).Path)
        if ($existingContent -eq $newContent -or ($existingContent -replace "`r`n?", "`n") -eq ($newContent -replace "`r`n?", "`n")) {
            Write-Host "[OK] VPN network plan already up to date: $OutputFile"
            return
        }
    }
    Set-Content -LiteralPath $OutputFile -Value $lines -Encoding ascii
    Write-Host "[OK] VPN network plan written: $OutputFile"
}

if ($PassThru) {
    $plan
}
