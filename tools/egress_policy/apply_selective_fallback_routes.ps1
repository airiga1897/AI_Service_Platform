param(
    [ValidateSet("plan", "apply", "verify", "rollback", "cleanup", "refresh")]
    [string]$Action = "plan",
    [string]$ProposalDir = ".\operator\egress_policy\proposals",
    [string]$AppliedRoutesDir = ".\operator\egress_policy\applied_routes",
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$StateFile = ".\operator\state.csv",
    [string]$NetworksFile = ".\operator\networks.csv",
    [string]$CascadeConfigFile = ".\operator\softether\cascade\secrets\lab-cascade.json",
    [string]$OperatorDir = ".\operator",
    [string[]]$Id = @(),
    [string[]]$TargetIp = @(),
    [string]$SshUser = "useradmin",
    [string]$SshPath = "ssh",
    [string]$EdgeSourceIp = "172.20.0.2",
    [int]$TimeoutSeconds = 10,
    [switch]$AutoAcceptHostKey = $true,
    [switch]$SkipVerify,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,connection,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$ExpectedNetworksHeader = "alias,policy_subnet,edge_ip,cascade_ip,cascade_router_ip,policy_gateway_ip"
$PolicyGatewayContainer = "policy-gateway"
$CascadeContainer = "softether-cascade"
$EdgeContainer = "softether-edge"
$TapInterface = "tap_vpnpolicy"
$RouteMode = "hybrid_cascade_canary"
$script:RefreshApplyContext = $null
$script:RefreshStateBackups = @()

function Fail($Message) {
    if ($script:RefreshApplyContext) {
        foreach ($backup in @($script:RefreshStateBackups)) {
            if (-not (Test-Path -LiteralPath $backup.Path -PathType Leaf)) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup.Path) | Out-Null
                $backup.State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $backup.Path -Encoding utf8
                Write-Error "restored stale applied route state after refresh failure: $($backup.Path)"
            }
        }
        Write-Error "refresh failed while applying current route $($script:RefreshApplyContext.id) -> $($script:RefreshApplyContext.target_ip). Existing state file was restored when possible, but runtime may be partially applied. Run cleanup for current target IPs, then retry refresh."
    }
    Write-Error $Message
    exit 1
}

function Require-File($Path, $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Label not found: $Path"
    }
}

function Read-JsonFile($Path, $Label) {
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        Fail "Failed to parse ${Label}: $Path"
    }
}

function Quote-BashArg($Value) {
    $text = [string]$Value
    return "'" + ($text -replace "'", "'\''") + "'"
}

function Resolve-SshExecutable($Path) {
    try {
        $command = Get-Command $Path -ErrorAction Stop
    } catch {
        Fail "SSH executable not found: $Path"
    }
    $resolvedPath = [string]$command.Path
    $lowerPath = $resolvedPath.ToLowerInvariant()
    if ($lowerPath -like "*.sbx-denybin*" -or $lowerPath.EndsWith(".bat") -or $lowerPath.EndsWith(".cmd")) {
        Fail "Resolved SSH path is not a real OpenSSH executable: $resolvedPath"
    }
    return $resolvedPath
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

function Invoke-SshText($AliasName, $Command) {
    $node = $script:Nodes[$AliasName]
    if (-not $node) {
        Fail "Unknown node alias: $AliasName"
    }
    $keyFile = Join-Path (Join-Path $OperatorDir $AliasName) "admin_key"
    Require-File $keyFile "admin key for $AliasName"
    $remote = "${SshUser}@$($node.endpoint)"
    $sshArgs = @("-n", "-T") + @(Get-OpenSshCommonArgs $keyFile) + @($remote, $Command)
    $output = @()
    $exitCode = 0
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $script:ErrorActionPreference = "Continue"
            $output = & $script:SshExecutablePath @sshArgs 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $script:ErrorActionPreference = $previousErrorActionPreference
        }
        if ($exitCode -eq 0) {
            break
        }
        $text = @($output) -join "`n"
        $isTransportTimeout = $exitCode -eq 255 -and $text -match 'timed out|banner exchange|Connection to .* port 22 timed out|ssh: connect to host .* port 22: Connection timed out|Connection closed|Connection reset by'
        if (-not $isTransportTimeout -or $attempt -eq 3) {
            break
        }
        Write-Host "[WARN] SSH transport timeout on ${AliasName}; retrying $attempt/3..."
        Start-Sleep -Seconds 2
    }
    if ($exitCode -ne 0) {
        Fail "SSH command failed on ${AliasName}: $(@($output) -join "`n")"
    }
    return @($output) -join "`n"
}

function Test-RemoteCommand($AliasName, $Command) {
    $node = $script:Nodes[$AliasName]
    if (-not $node) {
        Fail "Unknown node alias: $AliasName"
    }
    $keyFile = Join-Path (Join-Path $OperatorDir $AliasName) "admin_key"
    Require-File $keyFile "admin key for $AliasName"
    $remote = "${SshUser}@$($node.endpoint)"
    $sshArgs = @("-n", "-T") + @(Get-OpenSshCommonArgs $keyFile) + @($remote, $Command)
    $output = @()
    $exitCode = 0
    $transport_error = $false
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $script:ErrorActionPreference = "Continue"
            $output = & $script:SshExecutablePath @sshArgs 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $script:ErrorActionPreference = $previousErrorActionPreference
        }
        $text = @($output) -join "`n"
        $transport_error = $exitCode -eq 255 -and $text -match 'timed out|banner exchange|Connection to .* port 22 timed out|ssh: connect to host .* port 22: Connection timed out|Connection closed|Connection reset by'
        if ($exitCode -eq 0 -or -not $transport_error -or $attempt -eq 6) {
            break
        }
        Write-Host "[WARN] SSH transport timeout on ${AliasName}; retrying preflight $attempt/6..."
        Start-Sleep -Seconds 2
    }
    return [pscustomobject]@{
        ok = ($exitCode -eq 0)
        exit_code = $exitCode
        output = @($output) -join "`n"
        transport_error = $transport_error
    }
}

function Load-CsvMap($Path, $ExpectedHeader, $KeyField, $Label) {
    Require-File $Path $Label
    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -eq 0 -or $lines[0] -ne $ExpectedHeader) {
        Fail "$Label header must be exactly: $ExpectedHeader"
    }
    $map = @{}
    foreach ($row in @(Import-Csv -LiteralPath $Path)) {
        $key = [string]$row.$KeyField
        if (-not $key) {
            continue
        }
        if ($map.ContainsKey($key)) {
            Fail "$Label has duplicate ${KeyField}: $key"
        }
        $map[$key] = $row
    }
    return $map
}

function Load-StateRows {
    Require-File $StateFile "state.csv"
    $lines = @(Get-Content -LiteralPath $StateFile)
    if ($lines.Count -eq 0 -or $lines[0] -ne $ExpectedStateHeader) {
        Fail "state.csv header must be exactly: $ExpectedStateHeader"
    }
    return @(Import-Csv -LiteralPath $StateFile)
}

function Split-AliasList($Value) {
    return @(([string]$Value) -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-ActiveCascadeAliases {
    $aliases = New-Object System.Collections.ArrayList
    foreach ($row in @($script:StateRows)) {
        if ([string]$row.kind -eq "service" -and [string]$row.name -eq "vpn_cascade" -and [string]$row.state -eq "present") {
            foreach ($aliasName in @(Split-AliasList $row.active_aliases)) {
                [void]$aliases.Add($aliasName)
            }
        }
    }
    return @($aliases.ToArray() | Sort-Object -Unique)
}

function Get-CascadeTopologyRows {
    return @($script:StateRows | Where-Object { [string]$_.kind -eq "cascade_topology" -and [string]$_.state -eq "present" })
}

function Split-CascadeEdgeList($Value) {
    if (-not $Value) { return @() }
    return @(([string]$Value) -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Load-CascadeTopologyFabric {
    $rows = @(Get-CascadeTopologyRows)
    if ($rows.Count -eq 0) {
        return $null
    }
    if ($rows.Count -gt 1) {
        Fail "state.csv has multiple present cascade_topology rows; keep exactly one"
    }
    $row = $rows[0]
    $activeEdges = @(Split-CascadeEdgeList $row.active_aliases)
    $oldEdges = @(Split-CascadeEdgeList $row.old_aliases)
    $activeSet = @{}
    $oldSet = @{}
    foreach ($edge in $activeEdges) {
        if ($edge -notmatch '^[A-Za-z0-9_.-]+>[A-Za-z0-9_.-]+$') {
            Fail "cascade_topology $($row.name) has invalid active edge '$edge'; expected alias>alias"
        }
        $activeSet[$edge] = $true
    }
    foreach ($edge in $oldEdges) {
        if ($edge -notmatch '^[A-Za-z0-9_.-]+>[A-Za-z0-9_.-]+$') {
            Fail "cascade_topology $($row.name) has invalid old edge '$edge'; expected alias>alias"
        }
        $oldSet[$edge] = $true
    }
    return [pscustomobject]@{
        name = [string]$row.name
        active_edges = $activeSet
        old_edges = $oldSet
    }
}

function Load-ActiveCascadeLinks {
    if (-not (Test-Path -LiteralPath $CascadeConfigFile -PathType Leaf)) {
        return @()
    }
    $config = Read-JsonFile $CascadeConfigFile "cascade config"
    return @($config.links | Where-Object { [string]$_.state -eq "active" })
}

function Test-ActiveCascadePath($Path) {
    if ($script:CascadeTopologyFabric) {
        $hops = @()
        if ($Path.cascade_path -and @($Path.cascade_path).Count -gt 0) {
            $hops = @($Path.cascade_path | ForEach-Object { "$($_.ingress_alias)>$($_.egress_alias)" })
        } else {
            $hops = @("$($Path.ingress_alias)>$($Path.egress_alias)")
        }
        foreach ($edge in @($hops)) {
            if (-not $script:CascadeTopologyFabric.active_edges.ContainsKey($edge)) {
                return $false
            }
        }
        return $true
    }

    $links = @($script:ActiveCascadeLinks)
    if ($links.Count -eq 0) {
        return $false
    }
    $hops = @()
    if ($Path.cascade_path -and @($Path.cascade_path).Count -gt 0) {
        $hops = @($Path.cascade_path | ForEach-Object {
            [pscustomobject]@{
                connection = [string]$_.connection
                ingress_alias = [string]$_.ingress_alias
                egress_alias = [string]$_.egress_alias
            }
        })
    } else {
        $hops = @([pscustomobject]@{
            connection = [string]$Path.cascade_connection
            ingress_alias = [string]$Path.ingress_alias
            egress_alias = [string]$Path.egress_alias
        })
    }
    foreach ($hop in @($hops)) {
        $match = @($links | Where-Object {
            [string]$_.ingress_alias -eq [string]$hop.ingress_alias -and
            [string]$_.egress_alias -eq [string]$hop.egress_alias -and
            ((-not $hop.connection) -or [string]$_.connection_name -eq [string]$hop.connection)
        })
        if ($match.Count -eq 0) {
            return $false
        }
    }
    return $true
}

function Assert-CurrentCascadeEgress($Proposal, $Label) {
    if (-not $Proposal.recommended_path -or [string]$Proposal.recommended_path.mode -ne "cascade") {
        Fail "$Label is not a cascade fallback proposal"
    }
    $ingressAlias = [string]$Proposal.recommended_path.ingress_alias
    $egressAlias = [string]$Proposal.recommended_path.egress_alias
    if (-not (Test-ActiveCascadePath $Proposal.recommended_path)) {
        $edge = "$ingressAlias>$egressAlias"
        if ($script:CascadeTopologyFabric) {
            Fail "stale selective fallback proposal: $edge is not active in cascade_topology $($script:CascadeTopologyFabric.name)"
        }
        Fail "$Label points to stale cascade path $ingressAlias->${egressAlias}: no matching active link in $CascadeConfigFile"
    }
    if (-not $script:Nodes.ContainsKey($egressAlias)) {
        Fail "$Label points to stale egress alias '$egressAlias': alias is not present in nodes.csv"
    }
    if (-not $script:Networks.ContainsKey($egressAlias)) {
        Fail "$Label points to stale egress alias '$egressAlias': alias is not present in networks.csv"
    }
    if ($script:ActiveCascadeAliases -notcontains $ingressAlias) {
        Fail "$Label points to inactive cascade ingress '$ingressAlias': alias is not active for service vpn_cascade in state.csv"
    }
    if ($script:ActiveCascadeAliases -notcontains $egressAlias) {
        Fail "$Label points to inactive cascade egress '$egressAlias': alias is not active for service vpn_cascade in state.csv"
    }
}

function Get-Proposals {
    if (-not (Test-Path -LiteralPath $ProposalDir -PathType Container)) {
        return @()
    }
    $filter = @($Id | Where-Object { $_ })
    $items = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $ProposalDir -Filter "*.json" -File | Sort-Object Name)) {
        $proposal = Read-JsonFile $file.FullName "proposal"
        if ($filter.Count -gt 0 -and $filter -notcontains $proposal.id) {
            continue
        }
        if ($proposal.status -ne "accepted" -or $proposal.type -ne "fallback_available") {
            continue
        }
        if (-not $proposal.recommended_path -or $proposal.recommended_path.mode -ne "cascade") {
            continue
        }
        $items += [pscustomobject]@{ Proposal = $proposal; Path = $file.FullName }
    }
    return $items
}

function Resolve-TargetIps($Target, $IngressAlias) {
    if ($Target.type -eq "ip") {
        return @([string]$Target.value)
    }
    $allIps = New-Object System.Collections.ArrayList
    try {
        foreach ($address in [System.Net.Dns]::GetHostAddresses([string]$Target.value)) {
            if ($address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                [void]$allIps.Add($address.IPAddressToString)
            }
        }
    } catch {
        Write-Host "[WARN] local DNS resolve failed for $($Target.value): $($_.Exception.Message)"
    }
    $python = @'
import socket
import sys
import time

host = sys.argv[1]
attempts = int(sys.argv[2])
ips = set()
for _ in range(attempts):
    try:
        ips.update(info[4][0] for info in socket.getaddrinfo(host, None, family=socket.AF_INET, type=socket.SOCK_STREAM))
    except Exception:
        pass
    time.sleep(0.2)
print("\n".join(sorted(ips)))
'@
    $pythonB64 = ConvertTo-Base64Utf8 $python
    $command = "python3 -c $(Quote-BashArg "import base64,sys; exec(base64.b64decode('$pythonB64'))") $(Quote-BashArg ([string]$Target.value)) 12"
    $output = Invoke-SshText $IngressAlias $command
    foreach ($ip in @($output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })) {
        [void]$allIps.Add($ip)
    }
    $ips = @($allIps.ToArray() | Sort-Object -Unique)
    if ($ips.Count -eq 0) {
        Fail "Failed to resolve target $($Target.value) from ingress alias $IngressAlias"
    }
    return $ips
}

function New-StableRouteIds($Proposal, $TargetIp) {
    $inputText = "$($Proposal.id)|$TargetIp|$($Proposal.target.protocol)|$($Proposal.target.port)"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($inputText))
    } finally {
        $sha.Dispose()
    }
    $value = [System.BitConverter]::ToUInt32($hash, 0)
    $markValue = 1048576 + ($value % 15728639)
    return [pscustomobject]@{
        mark = ("0x{0:x}" -f $markValue)
        table = 0
        priority = 0
    }
}

function Get-RouteProtocol($Protocol) {
    if ($Protocol -in @("http", "https")) {
        return "tcp"
    }
    return [string]$Protocol
}

function Get-IptablesMatch($Step) {
    $routeProtocol = Get-RouteProtocol $Step.protocol
    if ($routeProtocol -in @("tcp", "udp")) {
        return "-p $routeProtocol -d $($Step.target_ip)/32 --dport $($Step.port)"
    }
    if ($routeProtocol -eq "icmp") {
        return "-p icmp -d $($Step.target_ip)/32"
    }
    Fail "Unsupported route protocol for apply: $($Step.protocol)"
}

function Get-BaseIptablesComment($Step) {
    if ($Step.iptables_comment) {
        return [string]$Step.iptables_comment
    }
    return "ai-sp:$($Step.id):$($Step.target_ip)"
}

function Get-IngressNatComment($Step) {
    if ($Step.ingress_nat_comment) {
        return [string]$Step.ingress_nat_comment
    }
    return "$(Get-BaseIptablesComment $Step):ingress-snat"
}

function Get-EgressNatComment($Step) {
    if ($Step.egress_nat_comment) {
        return [string]$Step.egress_nat_comment
    }
    return "$(Get-BaseIptablesComment $Step):egress-masq"
}

function Test-IPv4($Value) {
    $text = [string]$Value
    if ($text -notmatch '^(\d{1,3}\.){3}\d{1,3}$') {
        return $false
    }
    foreach ($part in @($text -split '\.')) {
        if ([int]$part -gt 255) {
            return $false
        }
    }
    return $true
}

function Test-Cidr($Value) {
    $text = [string]$Value
    if ($text -notmatch '^(.+)/(\d{1,2})$') {
        return $false
    }
    return (Test-IPv4 $Matches[1]) -and ([int]$Matches[2] -ge 0) -and ([int]$Matches[2] -le 32)
}

function Assert-StepValid($Step, $Label) {
    $requiredTextFields = @(
        "id",
        "target",
        "target_ip",
        "protocol",
        "ingress_alias",
        "egress_alias",
        "ingress_gateway_ip",
        "ingress_cascade_ip",
        "ingress_edge_ip",
        "edge_source_ip",
        "ingress_policy_subnet",
        "egress_policy_subnet",
        "ingress_router_ip",
        "egress_router_ip",
        "tunnel_source_ip",
        "tunnel_destination_ip",
        "iptables_comment",
        "ingress_nat_comment",
        "egress_nat_comment"
    )
    foreach ($field in $requiredTextFields) {
        if ([string]::IsNullOrWhiteSpace([string]$Step.$field)) {
            Fail "$Label is missing required field: $field"
        }
    }
    foreach ($field in @("target_ip", "ingress_gateway_ip", "ingress_cascade_ip", "ingress_edge_ip", "edge_source_ip", "ingress_router_ip", "egress_router_ip", "tunnel_source_ip", "tunnel_destination_ip")) {
        if (-not (Test-IPv4 $Step.$field)) {
            Fail "$Label has invalid IPv4 field ${field}: $($Step.$field)"
        }
    }
    if (-not (Test-Cidr $Step.ingress_policy_subnet)) {
        Fail "$Label has invalid ingress_policy_subnet: $($Step.ingress_policy_subnet)"
    }
    if (-not (Test-Cidr $Step.egress_policy_subnet)) {
        Fail "$Label has invalid egress_policy_subnet: $($Step.egress_policy_subnet)"
    }
    if ([int]$Step.port -lt 0 -or [int]$Step.port -gt 65535) {
        Fail "$Label has invalid port: $($Step.port)"
    }
    [void](Get-IptablesMatch $Step)
}

function ConvertTo-AppliedStepV3($Step) {
    $baseComment = if ($Step.iptables_comment) { [string]$Step.iptables_comment } else { "ai-sp:$($Step.id):$($Step.target_ip)" }
    $ingressAlias = [string]$Step.ingress_alias
    $egressAlias = [string]$Step.egress_alias
    $ingressNetwork = $script:Networks[$ingressAlias]
    $egressNetwork = $script:Networks[$egressAlias]
    return [pscustomobject]@{
        id = [string]$Step.id
        profile = [string]$Step.profile
        target_type = [string]$Step.target_type
        target = [string]$Step.target
        path = if ($Step.path) { [string]$Step.path } else { "/" }
        target_ip = [string]$Step.target_ip
        protocol = [string]$Step.protocol
        port = [int]$Step.port
        ingress_alias = $ingressAlias
        egress_alias = $egressAlias
        ingress_gateway_ip = if ($Step.ingress_gateway_ip) { [string]$Step.ingress_gateway_ip } elseif ($ingressNetwork) { [string]$ingressNetwork.policy_gateway_ip } else { [string]$Step.ingress_cascade_ip }
        ingress_cascade_ip = if ($Step.ingress_cascade_ip) { [string]$Step.ingress_cascade_ip } elseif ($ingressNetwork) { [string]$ingressNetwork.cascade_ip } else { "" }
        ingress_edge_ip = if ($Step.ingress_edge_ip) { [string]$Step.ingress_edge_ip } elseif ($ingressNetwork) { [string]$ingressNetwork.edge_ip } else { "" }
        edge_source_ip = if ($Step.edge_source_ip) { [string]$Step.edge_source_ip } else { [string]$EdgeSourceIp }
        ingress_policy_subnet = if ($Step.ingress_policy_subnet) { [string]$Step.ingress_policy_subnet } elseif ($ingressNetwork) { [string]$ingressNetwork.policy_subnet } else { "" }
        egress_policy_subnet = if ($Step.egress_policy_subnet) { [string]$Step.egress_policy_subnet } elseif ($egressNetwork) { [string]$egressNetwork.policy_subnet } else { "" }
        ingress_router_ip = if ($Step.ingress_router_ip) { [string]$Step.ingress_router_ip } elseif ($ingressNetwork) { [string]$ingressNetwork.cascade_router_ip } else { "" }
        egress_router_ip = if ($Step.egress_router_ip) { [string]$Step.egress_router_ip } elseif ($egressNetwork) { [string]$egressNetwork.cascade_router_ip } else { "" }
        tunnel_source_ip = if ($Step.tunnel_source_ip) { [string]$Step.tunnel_source_ip } elseif ($Step.ingress_gateway_ip) { [string]$Step.ingress_gateway_ip } elseif ($ingressNetwork) { [string]$ingressNetwork.policy_gateway_ip } else { "" }
        tunnel_destination_ip = if ($Step.tunnel_destination_ip) { [string]$Step.tunnel_destination_ip } elseif ($Step.egress_router_ip) { [string]$Step.egress_router_ip } elseif ($egressNetwork) { [string]$egressNetwork.cascade_router_ip } else { "" }
        iptables_comment = $baseComment
        ingress_nat_comment = if ($Step.ingress_nat_comment) { [string]$Step.ingress_nat_comment } else { "$baseComment`:ingress-snat" }
        egress_nat_comment = if ($Step.egress_nat_comment) { [string]$Step.egress_nat_comment } else { "$baseComment`:egress-masq" }
        route_mark = [string]$Step.route_mark
        route_table = [int]$Step.route_table
        route_priority = [int]$Step.route_priority
        mode = if ($Step.mode) { [string]$Step.mode } else { $RouteMode }
    }
}

function Get-NatPacketCount($Text, $Comment) {
    $commentRegex = [regex]::Escape([string]$Comment)
    $matches = [regex]::Matches([string]$Text, "(?m)^\s*(\d+)\s+\d+\s+.*$commentRegex")
    $count = [int64]0
    foreach ($match in $matches) {
        $count += [int64]$match.Groups[1].Value
    }
    return $count
}

function Get-NatPacketCountForTargetPort($Text, $Step) {
    $targetRegex = [regex]::Escape([string]$Step.target_ip)
    $portRegex = [regex]::Escape([string]$Step.port)
    $protocol = Get-RouteProtocol $Step.protocol
    if ($protocol -notin @("tcp", "udp")) {
        return [int64]0
    }
    $matches = [regex]::Matches([string]$Text, "(?m)^\s*(\d+)\s+\d+\s+\S+\s+\d+\s+--\s+.*\s+$targetRegex\s+.*\b$protocol\s+dpt:$portRegex\b")
    $count = [int64]0
    foreach ($match in $matches) {
        $count += [int64]$match.Groups[1].Value
    }
    return $count
}

function Get-StepDisplay($Step) {
    $match = Get-IptablesMatch $Step
    $baseComment = Get-BaseIptablesComment $Step
    $ingressComment = Get-IngressNatComment $Step
    $egressComment = Get-EgressNatComment $Step
    return [pscustomobject]@{
        id = [string]$Step.id
        target = [string]$Step.target
        target_ip = [string]$Step.target_ip
        protocol = [string]$Step.protocol
        port = [int]$Step.port
        ingress_alias = [string]$Step.ingress_alias
        egress_alias = [string]$Step.egress_alias
        ingress_policy_gateway = $PolicyGatewayContainer
        ingress_cascade = $CascadeContainer
        egress_cascade = $CascadeContainer
        mode = $RouteMode
        edge_route = "ip route replace $($Step.target_ip)/32 via $($Step.ingress_gateway_ip)"
        ingress_edge_return_route = "ip route replace $($Step.edge_source_ip)/32 via $($Step.ingress_edge_ip)"
        ingress_gateway_route = "ip route replace $($Step.target_ip)/32 via $($Step.ingress_cascade_ip)"
        ingress_snat = "iptables -t nat -A POSTROUTING -s $($Step.edge_source_ip)/32 $match -m comment --comment '$ingressComment' -j SNAT --to-source $($Step.tunnel_source_ip)"
        ingress_cascade_route = "ip route replace $($Step.target_ip)/32 via $($Step.egress_router_ip) dev $TapInterface"
        egress_return_route = "ip route replace $($Step.ingress_policy_subnet) via $($Step.ingress_router_ip) dev $TapInterface"
        egress_nat = "iptables -t nat -A POSTROUTING $match -m comment --comment '$egressComment' -j MASQUERADE"
        iptables_comment = $baseComment
    }
}

function New-Step($Proposal, $TargetIp) {
    $path = $Proposal.recommended_path
    $ingress = [string]$path.ingress_alias
    $egress = [string]$path.egress_alias
    $ingressNetwork = $script:Networks[$ingress]
    $egressNetwork = $script:Networks[$egress]
    if (-not $ingressNetwork) { Fail "networks.csv has no row for ingress alias: $ingress" }
    if (-not $egressNetwork) { Fail "networks.csv has no row for egress alias: $egress" }
    $routeIds = New-StableRouteIds $Proposal $TargetIp
    return [pscustomobject]@{
        id = [string]$Proposal.id
        profile = [string]$Proposal.profile
        target_type = [string]$Proposal.target.type
        target = [string]$Proposal.target.value
        path = if ($Proposal.target.path) { [string]$Proposal.target.path } else { "/" }
        target_ip = [string]$TargetIp
        protocol = [string]$Proposal.target.protocol
        port = [int]$Proposal.target.port
        ingress_alias = $ingress
        egress_alias = $egress
        ingress_gateway_ip = [string]$ingressNetwork.policy_gateway_ip
        ingress_cascade_ip = [string]$ingressNetwork.cascade_ip
        ingress_edge_ip = [string]$ingressNetwork.edge_ip
        edge_source_ip = [string]$EdgeSourceIp
        ingress_policy_subnet = [string]$ingressNetwork.policy_subnet
        egress_policy_subnet = [string]$egressNetwork.policy_subnet
        ingress_router_ip = [string]$ingressNetwork.cascade_router_ip
        egress_router_ip = [string]$egressNetwork.cascade_router_ip
        tunnel_source_ip = [string]$ingressNetwork.policy_gateway_ip
        tunnel_destination_ip = [string]$egressNetwork.cascade_router_ip
        mode = $RouteMode
        iptables_comment = "ai-sp:$($Proposal.id):$($TargetIp)"
        ingress_nat_comment = "ai-sp:$($Proposal.id):$($TargetIp):ingress-snat"
        egress_nat_comment = "ai-sp:$($Proposal.id):$($TargetIp):egress-masq"
        route_mark = [string]$routeIds.mark
        route_table = [int]$routeIds.table
        route_priority = [int]$routeIds.priority
    }
}

function Get-AppliedRouteStates {
    if (-not (Test-Path -LiteralPath $AppliedRoutesDir -PathType Container)) {
        return @()
    }
    $filter = @($Id | Where-Object { $_ })
    $items = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $AppliedRoutesDir -Filter "*.json" -File | Sort-Object Name)) {
        $state = Read-JsonFile $file.FullName "applied route state"
        if ($filter.Count -gt 0 -and $filter -notcontains $state.proposal_id) {
            continue
        }
        $items += [pscustomobject]@{ State = $state; Path = $file.FullName }
    }
    return $items
}

function Write-AppliedRouteStates($Steps) {
    New-Item -ItemType Directory -Force -Path $AppliedRoutesDir | Out-Null
    foreach ($group in @($Steps | Group-Object id)) {
        $statePath = Join-Path $AppliedRoutesDir "$($group.Name).json"
        $state = [ordered]@{
            schema_version = 4
            mode = $RouteMode
            proposal_id = $group.Name
            applied_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            steps = @($group.Group)
        }
        $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding utf8
        Write-Host "[OK] applied route state written: $statePath"
    }
}

function Get-AppliedRouteSteps($AppliedStates) {
    $steps = @()
    foreach ($item in $AppliedStates) {
        foreach ($step in @($item.State.steps)) {
            $steps += ConvertTo-AppliedStepV3 $step
        }
    }
    return @($steps)
}

function ConvertTo-Base64Utf8($Text) {
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$Text))
}

function Invoke-StepTrafficCheck($Step) {
    $protocol = [string]$Step.protocol
    if ($protocol -eq "udp") {
        return [pscustomobject]@{
            ok = $true
            skipped = $true
            reason = "generic UDP verification is route-only without protocol-specific probe"
        }
    }

    $path = if ($Step.path) { [string]$Step.path } else { "/" }
    $payload = @{
        host = [string]$Step.target
        target_ip = [string]$Step.target_ip
        protocol = $protocol
        port = [int]$Step.port
        path = $path
        timeout = [int]$TimeoutSeconds
    } | ConvertTo-Json -Compress
    $payloadB64 = ConvertTo-Base64Utf8 $payload
    $python = @"
import base64, json, socket, ssl, subprocess, sys, time
payload = json.loads(base64.b64decode(sys.argv[1]).decode("utf-8"))
host = payload["host"]
target_ip = payload["target_ip"]
protocol = payload["protocol"]
port = int(payload["port"])
path = payload.get("path") or "/"
timeout = float(payload["timeout"])
result = {"ok": False, "protocol": protocol, "http_status": None, "first_line": None, "elapsed_ms": None, "error": None}
start = time.monotonic()
try:
    if protocol in ("http", "https"):
        sock = socket.create_connection((target_ip, port), timeout=timeout)
        if protocol == "https":
            sock = ssl.create_default_context().wrap_socket(sock, server_hostname=host)
        request = f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: ai-service-platform-selective-fallback-verify/1\r\nConnection: close\r\n\r\n"
        sock.sendall(request.encode("ascii", "ignore"))
        data = b""
        while b"\r\n" not in data and len(data) < 4096:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        sock.close()
        first = data.split(b"\r\n", 1)[0].decode("iso-8859-1", "replace")
        result["first_line"] = first
        parts = first.split()
        if len(parts) >= 2 and parts[0].startswith("HTTP/"):
            result["http_status"] = int(parts[1])
            result["ok"] = 200 <= result["http_status"] < 400
        else:
            result["error"] = "response did not start with HTTP status line"
    elif protocol == "tcp":
        sock = socket.create_connection((target_ip, port), timeout=timeout)
        sock.close()
        result["ok"] = True
    elif protocol == "icmp":
        proc = subprocess.run(["ping", "-c", "1", "-W", str(max(1, int(timeout))), target_ip], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout + 1)
        result["ok"] = proc.returncode == 0
        if proc.returncode != 0:
            result["error"] = ((proc.stdout or "") + "\n" + (proc.stderr or "")).strip() or f"ping exited {proc.returncode}"
    else:
        result["error"] = f"unsupported protocol: {protocol}"
except Exception as exc:
    result["error"] = str(exc)
finally:
    result["elapsed_ms"] = round((time.monotonic() - start) * 1000, 2)
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
"@
    $pythonB64 = ConvertTo-Base64Utf8 $python
    $remoteCommand = @(
        "set -euo pipefail",
        "pid=`$(sudo docker inspect -f '{{.State.Pid}}' $(Quote-BashArg $EdgeContainer))",
        "printf '%s' $(Quote-BashArg $pythonB64) | base64 -d | sudo nsenter -t `"`$pid`" -n python3 - $(Quote-BashArg $payloadB64)"
    ) -join "; "
    $output = Invoke-SshText $Step.ingress_alias $remoteCommand
    try {
        return $output | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{
            ok = $false
            error = "traffic verification returned non-JSON output: $output"
        }
    }
}

function Test-StepApplied($Step) {
    $ingressComment = Get-IngressNatComment $Step
    $egressComment = Get-EgressNatComment $Step
    $targetRegex = [regex]::Escape([string]$Step.target_ip)
    $ingressGatewayRegex = [regex]::Escape([string]$Step.ingress_gateway_ip)
    $ingressCascadeRegex = [regex]::Escape([string]$Step.ingress_cascade_ip)
    $edgeSourceRegex = [regex]::Escape([string]$Step.edge_source_ip)
    $ingressEdgeRegex = [regex]::Escape([string]$Step.ingress_edge_ip)
    $egressRouterRegex = [regex]::Escape([string]$Step.egress_router_ip)
    $ingressSubnetRegex = [regex]::Escape([string]$Step.ingress_policy_subnet)
    $ingressRouterRegex = [regex]::Escape([string]$Step.ingress_router_ip)
    $ingressCommentRegex = [regex]::Escape($ingressComment)
    $egressCommentRegex = [regex]::Escape($egressComment)

    $edgeRoutes = Invoke-SshText $Step.ingress_alias "sudo docker exec -u 0 $(Quote-BashArg $EdgeContainer) ip route 2>/dev/null || true"
    $ingressGatewayRoutes = Invoke-SshText $Step.ingress_alias "sudo docker exec -u 0 $(Quote-BashArg $PolicyGatewayContainer) ip route 2>/dev/null || true"
    $ingressNat = Invoke-SshText $Step.ingress_alias "sudo docker exec -u 0 $(Quote-BashArg $PolicyGatewayContainer) iptables -t nat -S POSTROUTING 2>/dev/null || true"
    $ingressNatCountersBefore = Invoke-SshText $Step.ingress_alias "sudo docker exec -u 0 $(Quote-BashArg $PolicyGatewayContainer) iptables -t nat -L POSTROUTING -v -n -x 2>/dev/null || true"
    $ingressCascadeRoutes = Invoke-SshText $Step.ingress_alias "sudo docker exec -u 0 $(Quote-BashArg $CascadeContainer) ip route 2>/dev/null || true"
    $egressCascadeRoutes = Invoke-SshText $Step.egress_alias "sudo docker exec -u 0 $(Quote-BashArg $CascadeContainer) ip route 2>/dev/null || true"
    $egressNat = Invoke-SshText $Step.egress_alias "sudo docker exec -u 0 $(Quote-BashArg $CascadeContainer) iptables -t nat -S POSTROUTING 2>/dev/null || true"
    $egressNatCountersBefore = Invoke-SshText $Step.egress_alias "sudo docker exec -u 0 $(Quote-BashArg $CascadeContainer) iptables -t nat -L POSTROUTING -v -n -x 2>/dev/null || true"
    $traffic = Invoke-StepTrafficCheck $Step
    $ingressNatCountersAfter = Invoke-SshText $Step.ingress_alias "sudo docker exec -u 0 $(Quote-BashArg $PolicyGatewayContainer) iptables -t nat -L POSTROUTING -v -n -x 2>/dev/null || true"
    $egressNatCountersAfter = Invoke-SshText $Step.egress_alias "sudo docker exec -u 0 $(Quote-BashArg $CascadeContainer) iptables -t nat -L POSTROUTING -v -n -x 2>/dev/null || true"

    $edgeRouteOk = $edgeRoutes -match "(?m)^$targetRegex\s+via\s+$ingressGatewayRegex(\s|$)"
    $ingressEdgeReturnRouteOk = $ingressGatewayRoutes -match "(?m)^$edgeSourceRegex\s+via\s+$ingressEdgeRegex(\s|$)"
    $ingressGatewayRouteOk = $ingressGatewayRoutes -match "(?m)^$targetRegex\s+via\s+$ingressCascadeRegex(\s|$)"
    $ingressCascadeRouteOk = $ingressCascadeRoutes -match "(?m)^$targetRegex\s+via\s+$egressRouterRegex\b.*\b$TapInterface\b"
    $egressReturnRouteOk = $egressCascadeRoutes -match "(?m)^$ingressSubnetRegex\s+via\s+$ingressRouterRegex\b.*\b$TapInterface\b"
    $ingressNatOk = $ingressNat -match $ingressCommentRegex
    $egressNatOk = $egressNat -match $egressCommentRegex
    $ingressNatBefore = Get-NatPacketCount $ingressNatCountersBefore $ingressComment
    $ingressNatAfter = Get-NatPacketCount $ingressNatCountersAfter $ingressComment
    $egressNatBefore = Get-NatPacketCount $egressNatCountersBefore $egressComment
    $egressNatAfter = Get-NatPacketCount $egressNatCountersAfter $egressComment
    $ingressNatAnyBefore = Get-NatPacketCountForTargetPort $ingressNatCountersBefore $Step
    $ingressNatAnyAfter = Get-NatPacketCountForTargetPort $ingressNatCountersAfter $Step
    $egressNatAnyBefore = Get-NatPacketCountForTargetPort $egressNatCountersBefore $Step
    $egressNatAnyAfter = Get-NatPacketCountForTargetPort $egressNatCountersAfter $Step
    $counterCheckRequired = [string]$Step.protocol -ne "udp"
    $syntheticProbeBypassesSecureNatSource = $counterCheckRequired -and ([bool]$traffic.ok) -and (($egressNatAfter -gt $egressNatBefore) -or ($egressNatAnyAfter -gt $egressNatAnyBefore)) -and ($ingressNatAfter -le $ingressNatBefore)
    $ingressNatCounterShadowedByDuplicate = $counterCheckRequired -and ([bool]$traffic.ok) -and ($ingressNatAfter -le $ingressNatBefore) -and ($ingressNatAnyAfter -gt $ingressNatAnyBefore)
    $egressNatCounterShadowedByDuplicate = $counterCheckRequired -and ([bool]$traffic.ok) -and ($egressNatAfter -le $egressNatBefore) -and ($egressNatAnyAfter -gt $egressNatAnyBefore)
    $ingressNatCounterOk = (-not $counterCheckRequired) -or ($ingressNatAfter -gt $ingressNatBefore) -or $syntheticProbeBypassesSecureNatSource -or $ingressNatCounterShadowedByDuplicate
    $egressNatCounterOk = (-not $counterCheckRequired) -or ($egressNatAfter -gt $egressNatBefore) -or $egressNatCounterShadowedByDuplicate
    $trafficOk = [bool]$traffic.ok

    return [pscustomobject]@{
        id = [string]$Step.id
        target = [string]$Step.target
        target_ip = [string]$Step.target_ip
        protocol = [string]$Step.protocol
        port = [int]$Step.port
        ingress_alias = [string]$Step.ingress_alias
        egress_alias = [string]$Step.egress_alias
        edge_route_ok = [bool]$edgeRouteOk
        ingress_edge_return_route_ok = [bool]$ingressEdgeReturnRouteOk
        ingress_gateway_route_ok = [bool]$ingressGatewayRouteOk
        ingress_cascade_route_ok = [bool]$ingressCascadeRouteOk
        egress_return_route_ok = [bool]$egressReturnRouteOk
        ingress_nat_ok = [bool]$ingressNatOk
        ingress_nat_counter_ok = [bool]$ingressNatCounterOk
        ingress_nat_counter_skipped_for_synthetic_probe = [bool]$syntheticProbeBypassesSecureNatSource
        ingress_nat_counter_shadowed_by_duplicate = [bool]$ingressNatCounterShadowedByDuplicate
        ingress_nat_counter_note = if ($syntheticProbeBypassesSecureNatSource) { "synthetic nsenter probe originates from edge namespace, not SecureNAT source $($Step.edge_source_ip); validate ingress SNAT counter with real VPN client traffic" } elseif ($ingressNatCounterShadowedByDuplicate) { "per-proposal ingress NAT counter did not increment because another equivalent target/port NAT rule matched first" } else { "" }
        ingress_nat_packets_before = $ingressNatBefore
        ingress_nat_packets_after = $ingressNatAfter
        ingress_nat_any_packets_before = $ingressNatAnyBefore
        ingress_nat_any_packets_after = $ingressNatAnyAfter
        egress_nat_ok = [bool]$egressNatOk
        egress_nat_counter_ok = [bool]$egressNatCounterOk
        egress_nat_counter_shadowed_by_duplicate = [bool]$egressNatCounterShadowedByDuplicate
        egress_nat_counter_note = if ($egressNatCounterShadowedByDuplicate) { "per-proposal egress NAT counter did not increment because another equivalent target/port NAT rule matched first" } else { "" }
        egress_nat_packets_before = $egressNatBefore
        egress_nat_packets_after = $egressNatAfter
        egress_nat_any_packets_before = $egressNatAnyBefore
        egress_nat_any_packets_after = $egressNatAnyAfter
        traffic_ok = $trafficOk
        traffic = $traffic
        ok = [bool]($edgeRouteOk -and $ingressEdgeReturnRouteOk -and $ingressGatewayRouteOk -and $ingressCascadeRouteOk -and $egressReturnRouteOk -and $ingressNatOk -and $ingressNatCounterOk -and $egressNatOk -and $egressNatCounterOk -and $trafficOk)
    }
}

function Test-StepAbsent($Step) {
    $ingressComment = Get-IngressNatComment $Step
    $egressComment = Get-EgressNatComment $Step
    $targetRegex = [regex]::Escape([string]$Step.target_ip)
    $ingressCommentRegex = [regex]::Escape($ingressComment)
    $egressCommentRegex = [regex]::Escape($egressComment)
    $edgeRoutes = Invoke-SshText $Step.ingress_alias "sudo docker exec -u 0 $(Quote-BashArg $EdgeContainer) ip route 2>/dev/null || true"
    $ingressGatewayRoutes = Invoke-SshText $Step.ingress_alias "sudo docker exec -u 0 $(Quote-BashArg $PolicyGatewayContainer) ip route 2>/dev/null || true"
    $ingressCascadeRoutes = Invoke-SshText $Step.ingress_alias "sudo docker exec -u 0 $(Quote-BashArg $CascadeContainer) ip route 2>/dev/null || true"
    $ingressNat = Invoke-SshText $Step.ingress_alias "sudo docker exec -u 0 $(Quote-BashArg $PolicyGatewayContainer) iptables -t nat -S POSTROUTING 2>/dev/null || true"
    $egressNat = ""
    if ($script:Nodes.ContainsKey([string]$Step.egress_alias)) {
        $egressNat = Invoke-SshText $Step.egress_alias "sudo docker exec -u 0 $(Quote-BashArg $CascadeContainer) iptables -t nat -S POSTROUTING 2>/dev/null || true"
    } else {
        Write-Host "[WARN] skipping absent-route egress NAT check for retired alias $($Step.egress_alias)"
    }
    $edgeRoutePresent = $edgeRoutes -match "(?m)^$targetRegex\b"
    $ingressGatewayRoutePresent = $ingressGatewayRoutes -match "(?m)^$targetRegex\b"
    $ingressCascadeRoutePresent = $ingressCascadeRoutes -match "(?m)^$targetRegex\b"
    $ingressNatPresent = $ingressNat -match $ingressCommentRegex
    $egressNatPresent = $egressNat -match $egressCommentRegex
    return [pscustomobject]@{
        id = [string]$Step.id
        target_ip = [string]$Step.target_ip
        edge_route_absent = -not $edgeRoutePresent
        ingress_gateway_route_absent = -not $ingressGatewayRoutePresent
        ingress_cascade_route_absent = -not $ingressCascadeRoutePresent
        ingress_nat_absent = -not $ingressNatPresent
        egress_nat_absent = -not $egressNatPresent
        ok = [bool]((-not $edgeRoutePresent) -and (-not $ingressGatewayRoutePresent) -and (-not $ingressCascadeRoutePresent) -and (-not $ingressNatPresent) -and (-not $egressNatPresent))
    }
}

function Invoke-VerifyApplied($Steps) {
    $results = @()
    foreach ($step in $Steps) {
        $result = Test-StepApplied $step
        $results += $result
        if ($result.ok) {
            Write-Host "[OK] verified selective fallback route $($step.id) -> $($step.target_ip)"
        } else {
            Write-Host "[FAIL] selective fallback verification failed for $($step.id) -> $($step.target_ip)"
        }
    }
    if ($Json) {
        $results | ConvertTo-Json -Depth 10
    }
    $failed = @($results | Where-Object { -not $_.ok })
    if ($failed.Count -gt 0) {
        Fail "selective fallback verification failed; inspect failed stages above and run rollback for the affected proposal"
    }
}

function Invoke-VerifyAbsent($Steps) {
    $results = @()
    foreach ($step in $Steps) {
        $result = Test-StepAbsent $step
        $results += $result
        if ($result.ok) {
            Write-Host "[OK] verified selective fallback route removed $($step.id) -> $($step.target_ip)"
        } else {
            Write-Host "[FAIL] selective fallback rollback verification failed for $($step.id) -> $($step.target_ip)"
        }
    }
    if ($Json) {
        $results | ConvertTo-Json -Depth 10
    }
    $failed = @($results | Where-Object { -not $_.ok })
    if ($failed.Count -gt 0) {
        Fail "selective fallback rollback verification failed; exact route or NAT state is still present"
    }
}

function Invoke-StepApply($Step) {
    $ingressComment = Get-IngressNatComment $Step
    $egressComment = Get-EgressNatComment $Step
    $match = Get-IptablesMatch $Step
    $edgeCommand = @(
        "set -euo pipefail",
        "sudo docker exec -u 0 $(Quote-BashArg $EdgeContainer) sh -c $(Quote-BashArg "ip route replace $($Step.target_ip)/32 via $($Step.ingress_gateway_ip)")"
    ) -join "; "
    Invoke-SshText $Step.ingress_alias $edgeCommand | Out-Null

    $ingressGatewayCommand = @(
        "set -euo pipefail",
        "sudo docker exec -u 0 $(Quote-BashArg $PolicyGatewayContainer) sh -c $(Quote-BashArg "sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true; ip route replace $($Step.edge_source_ip)/32 via $($Step.ingress_edge_ip); ip route replace $($Step.target_ip)/32 via $($Step.ingress_cascade_ip); iptables -t nat -C POSTROUTING -s $($Step.edge_source_ip)/32 $match -m comment --comment '$ingressComment' -j SNAT --to-source $($Step.tunnel_source_ip) 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s $($Step.edge_source_ip)/32 $match -m comment --comment '$ingressComment' -j SNAT --to-source $($Step.tunnel_source_ip)")"
    ) -join "; "
    Invoke-SshText $Step.ingress_alias $ingressGatewayCommand | Out-Null

    $ingressCascadeCommand = @(
        "set -euo pipefail",
        "sudo docker exec -u 0 $(Quote-BashArg $CascadeContainer) sh -c $(Quote-BashArg "ip route replace $($Step.target_ip)/32 via $($Step.egress_router_ip) dev $TapInterface")"
    ) -join "; "
    Invoke-SshText $Step.ingress_alias $ingressCascadeCommand | Out-Null

    $egressCommand = @(
        "set -euo pipefail",
        "sudo docker exec -u 0 $(Quote-BashArg $CascadeContainer) sh -c $(Quote-BashArg "ip route replace $($Step.ingress_policy_subnet) via $($Step.ingress_router_ip) dev $TapInterface; iptables -t nat -C POSTROUTING $match -m comment --comment '$egressComment' -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 $match -m comment --comment '$egressComment' -j MASQUERADE")"
    ) -join "; "
    Invoke-SshText $Step.egress_alias $egressCommand | Out-Null
}

function Assert-StepApplyPrerequisites($Step) {
    $checks = @(
        [pscustomobject]@{ alias = [string]$Step.ingress_alias; container = $EdgeContainer; label = "ingress edge" },
        [pscustomobject]@{ alias = [string]$Step.ingress_alias; container = $PolicyGatewayContainer; label = "ingress policy gateway" },
        [pscustomobject]@{ alias = [string]$Step.ingress_alias; container = $CascadeContainer; label = "ingress cascade" },
        [pscustomobject]@{ alias = [string]$Step.egress_alias; container = $CascadeContainer; label = "egress cascade" }
    )
    foreach ($check in $checks) {
        $result = Test-RemoteCommand $check.alias "sudo docker inspect $(Quote-BashArg $check.container) >/dev/null 2>&1"
        if (-not $result.ok) {
            if ($result.transport_error) {
                Fail "SSH transport failed during preflight for $($Step.id) -> $($Step.target_ip): $($check.label) '$($check.container)' on $($check.alias). Retry the action; this does not prove the container is missing. Output: $($result.output)"
            }
            Fail "Required container missing for $($Step.id) -> $($Step.target_ip): $($check.label) '$($check.container)' on $($check.alias). Deploy policy_gateway/cascade readiness before apply."
        }
    }
}

function Invoke-StepRollback($Step) {
    $ingressComment = Get-IngressNatComment $Step
    $egressComment = Get-EgressNatComment $Step
    $baseComment = Get-BaseIptablesComment $Step
    $match = Get-IptablesMatch $Step
    Invoke-SshText $Step.ingress_alias ("sudo docker exec -u 0 $(Quote-BashArg $EdgeContainer) ip route del $(Quote-BashArg "$($Step.target_ip)/32") 2>/dev/null || true") | Out-Null
    $ingressCommand = "sudo docker exec -u 0 $(Quote-BashArg $PolicyGatewayContainer) sh -c $(Quote-BashArg "ip route del $($Step.target_ip)/32 2>/dev/null || true; iptables -t nat -D POSTROUTING -s $($Step.edge_source_ip)/32 $match -m comment --comment '$ingressComment' -j SNAT --to-source $($Step.tunnel_source_ip) 2>/dev/null || true") 2>/dev/null || true"
    Invoke-SshText $Step.ingress_alias $ingressCommand | Out-Null
    $ingressCascadeCommand = "sudo docker exec -u 0 $(Quote-BashArg $CascadeContainer) sh -c $(Quote-BashArg "ip route del $($Step.target_ip)/32 2>/dev/null || true") 2>/dev/null || true"
    Invoke-SshText $Step.ingress_alias $ingressCascadeCommand | Out-Null
    if ($script:Nodes.ContainsKey([string]$Step.egress_alias)) {
        $egressCommand = "sudo docker exec -u 0 $(Quote-BashArg $CascadeContainer) sh -c $(Quote-BashArg "iptables -t nat -D POSTROUTING $match -m comment --comment '$egressComment' -j MASQUERADE 2>/dev/null || true; iptables -t nat -D POSTROUTING $match -m comment --comment '$baseComment' -j MASQUERADE 2>/dev/null || true") 2>/dev/null || true"
        Invoke-SshText $Step.egress_alias $egressCommand | Out-Null
    } else {
        Write-Host "[WARN] skipping egress cleanup for retired alias $($Step.egress_alias); ingress-side route state was still rolled back"
    }
}

$script:SshExecutablePath = Resolve-SshExecutable $SshPath
$script:Nodes = Load-CsvMap $NodesFile $ExpectedNodesHeader "current_alias" "nodes.csv"
$script:Networks = Load-CsvMap $NetworksFile $ExpectedNetworksHeader "alias" "networks.csv"
$script:StateRows = @(Load-StateRows)
$script:ActiveCascadeAliases = @(Get-ActiveCascadeAliases)
$script:ActiveCascadeLinks = @(Load-ActiveCascadeLinks)
$script:CascadeTopologyFabric = Load-CascadeTopologyFabric

if ($Action -in @("verify", "rollback")) {
    $appliedStates = @(Get-AppliedRouteStates)
    if ($appliedStates.Count -eq 0) {
        Write-Host "No applied selective fallback route state selected."
        exit 0
    }
    $stateSteps = @(Get-AppliedRouteSteps $appliedStates)
    foreach ($step in $stateSteps) {
        Assert-StepValid $step "applied route state $($step.id) -> $($step.target_ip)"
    }
    if ($Action -eq "verify") {
        if ($Json) {
            $stateSteps | ForEach-Object { Get-StepDisplay $_ } | ConvertTo-Json -Depth 8
        } else {
            $stateSteps | ForEach-Object { Get-StepDisplay $_ } | Format-List
        }
        Invoke-VerifyApplied $stateSteps
        exit 0
    }
    if ($Json) {
        $stateSteps | ForEach-Object { Get-StepDisplay $_ } | ConvertTo-Json -Depth 8
    } else {
        $stateSteps | ForEach-Object { Get-StepDisplay $_ } | Format-List
    }
    foreach ($step in $stateSteps) {
        Invoke-StepRollback $step
        Write-Host "[OK] rolled back selective fallback route $($step.id) -> $($step.target_ip)"
    }
    Invoke-VerifyAbsent $stateSteps
    foreach ($item in $appliedStates) {
        Remove-Item -LiteralPath $item.Path -Force
        Write-Host "[OK] removed applied route state: $($item.Path)"
    }
    exit 0
}

$proposals = @(Get-Proposals)
if ($proposals.Count -eq 0) {
    Write-Host "No accepted fallback_available proposals selected."
    exit 0
}

$steps = @()
$explicitTargetIps = @($TargetIp | Where-Object { $_ })
foreach ($ip in $explicitTargetIps) {
    if (-not (Test-IPv4 $ip)) {
        Fail "Invalid explicit target IP: $ip"
    }
}
foreach ($item in $proposals) {
    if ($Action -in @("apply", "refresh")) {
        Assert-CurrentCascadeEgress $item.Proposal "proposal $($item.Proposal.id)"
    }
    $ingressAlias = [string]$item.Proposal.recommended_path.ingress_alias
    $candidateIps = if ($explicitTargetIps.Count -gt 0) { $explicitTargetIps } else { @(Resolve-TargetIps $item.Proposal.target $ingressAlias) }
    foreach ($ip in $candidateIps) {
        $steps += New-Step $item.Proposal $ip
    }
}

foreach ($step in $steps) {
    Assert-StepValid $step "planned route step $($step.id) -> $($step.target_ip)"
}

if ($Json) {
    $steps | ForEach-Object { Get-StepDisplay $_ } | ConvertTo-Json -Depth 8
} else {
    $steps | ForEach-Object { Get-StepDisplay $_ } | Format-List
}

if ($Action -eq "plan") {
    exit 0
}

if ($Action -eq "cleanup") {
    foreach ($step in $steps) {
        Invoke-StepRollback $step
        Write-Host "[OK] cleaned selective fallback route candidate $($step.id) -> $($step.target_ip)"
    }
    if (-not $SkipVerify) {
        Invoke-VerifyAbsent $steps
    }
    exit 0
}

$selectedIds = @($steps | ForEach-Object { [string]$_.id } | Select-Object -Unique)
$existingStates = @(Get-AppliedRouteStates | Where-Object { $selectedIds -contains [string]$_.State.proposal_id })

if ($Action -eq "apply") {
    if ($existingStates.Count -gt 0) {
        Fail "applied route state already exists for selected proposal; use verify, rollback, cleanup, or refresh. Apply stays strict and does not merge or replace existing state."
    }
}

if ($Action -eq "refresh") {
    $oldStateBackups = @()
    $script:RefreshStateBackups = @()
    if ($existingStates.Count -gt 0) {
        $oldSteps = @(Get-AppliedRouteSteps $existingStates)
        foreach ($step in $oldSteps) {
            Assert-StepValid $step "applied route state $($step.id) -> $($step.target_ip)"
        }
        foreach ($item in $existingStates) {
            $oldStateBackups += [pscustomobject]@{
                Path = [string]$item.Path
                State = $item.State
            }
        }
        $script:RefreshStateBackups = @($oldStateBackups)
        if ($oldSteps.Count -gt 0) {
            Write-Host "[INFO] refreshing selective fallback route state; rolling back persisted step(s) first"
            if ($Json) {
                $oldSteps | ForEach-Object { Get-StepDisplay $_ } | ConvertTo-Json -Depth 8
            } else {
                $oldSteps | ForEach-Object { Get-StepDisplay $_ } | Format-List
            }
            foreach ($step in $oldSteps) {
                Invoke-StepRollback $step
                Write-Host "[OK] rolled back stale selective fallback route $($step.id) -> $($step.target_ip)"
            }
            if (-not $SkipVerify) {
                Invoke-VerifyAbsent $oldSteps
            }
        }
    } else {
        Write-Host "[INFO] no existing applied route state found; refresh will apply current planned step(s)"
    }
}

foreach ($step in $steps) {
    if ($Action -in @("apply", "refresh")) {
        Assert-StepApplyPrerequisites $step
        try {
            if ($Action -eq "refresh") {
                $script:RefreshApplyContext = $step
            }
            Invoke-StepApply $step
            Write-Host "[OK] applied selective fallback route $($step.id) -> $($step.target_ip)"
        } catch {
            if ($Action -eq "refresh") {
                foreach ($backup in @($oldStateBackups)) {
                    if (-not (Test-Path -LiteralPath $backup.Path -PathType Leaf)) {
                        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup.Path) | Out-Null
                        $backup.State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $backup.Path -Encoding utf8
                        Write-Error "restored stale applied route state after refresh failure: $($backup.Path)"
                    }
                }
                Write-Error "refresh failed while applying current route $($step.id) -> $($step.target_ip). Existing state file was restored when possible, but runtime may be partially applied. Run cleanup for current target IPs, then retry refresh. Error: $_"
                exit 1
            }
            throw
        } finally {
            if ($Action -eq "refresh") {
                $script:RefreshApplyContext = $null
            }
        }
    }
}

if ($Action -in @("apply", "refresh")) {
    Write-AppliedRouteStates $steps
    if ($Action -eq "refresh") {
        foreach ($backup in @($oldStateBackups)) {
            if (Test-Path -LiteralPath $backup.Path -PathType Leaf) {
                $currentState = Read-JsonFile $backup.Path "applied route state"
                $currentIps = @($currentState.steps | ForEach-Object { [string]$_.target_ip } | Sort-Object -Unique)
                $newIps = @($steps | Where-Object { [string]$_.id -eq [string]$currentState.proposal_id } | ForEach-Object { [string]$_.target_ip } | Sort-Object -Unique)
                if (($currentIps -join ",") -ne ($newIps -join ",")) {
                    Remove-Item -LiteralPath $backup.Path -Force
                    Write-Host "[OK] removed stale applied route state after successful refresh: $($backup.Path)"
                }
            }
        }
        $script:RefreshStateBackups = @()
    }
    if (-not $SkipVerify) {
        Invoke-VerifyApplied $steps
    }
}
