param(
    [string]$PolicyFile = ".\operator\egress_policy\profiles.json",
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$StateFile = ".\operator\state.csv",
    [string]$NetworksFile = ".\operator\networks.csv",
    [string]$OperatorDir = ".\operator",
    [string]$CascadeSecretDir = ".\operator\softether\cascade\secrets",
    [string]$OutputDir = ".\operator\egress_policy\history",
    [string]$SshUser = "useradmin",
    [string]$SshPath = "ssh",
    [string[]]$ProfileName = @(),
    [string[]]$Alias = @(),
    [int]$TimeoutSeconds = 10,
    [int]$TargetTimeoutSeconds = 4,
    [switch]$DryRun,
    [switch]$Json,
    [switch]$AutoAcceptHostKey = $true
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$ExpectedNetworksHeader = "alias,policy_subnet,edge_ip,cascade_ip,cascade_router_ip,policy_gateway_ip"
$PolicyGatewayContainer = "policy-gateway"
$CascadeContainer = "softether-cascade"
$TapInterface = "tap_vpnpolicy"

function Fail($Message) {
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

function Get-NodeSshPort($Node) {
    $port = [string]$Node.ssh_port
    if (-not $port) { return "22" }
    $portNumber = 0
    if (-not [int]::TryParse($port, [ref]$portNumber) -or $portNumber -lt 1 -or $portNumber -gt 65535) {
        Fail "Invalid ssh_port for $($Node.current_alias): $port"
    }
    return [string]$portNumber
}

function Invoke-SshText($KeyFile, $Remote, $Command, $Port = "22") {
    $sshArgs = @("-n", "-T", "-p", $Port) + @(Get-OpenSshCommonArgs $KeyFile) + @($Remote, $Command)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $script:ErrorActionPreference = "Continue"
        $output = & $script:SshExecutablePath @sshArgs
        $exitCode = $LASTEXITCODE
    } finally {
        $script:ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{
        ok = ($exitCode -eq 0)
        exit_code = $exitCode
        output = @($output) -join "`n"
    }
}

function Load-Nodes($Path) {
    Require-File $Path "nodes.csv"
    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -eq 0 -or $lines[0] -ne $ExpectedNodesHeader) {
        Fail "nodes.csv header must be exactly: $ExpectedNodesHeader"
    }
    $map = @{}
    foreach ($row in @(Import-Csv -LiteralPath $Path)) {
        $map[$row.current_alias] = $row
    }
    return $map
}

function Load-NetworkPlan($Path, $Nodes) {
    Require-File $Path "networks.csv"
    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -eq 0 -or $lines[0] -ne $ExpectedNetworksHeader) {
        Fail "networks.csv header must be exactly: $ExpectedNetworksHeader"
    }
    $map = @{}
    foreach ($row in @(Import-Csv -LiteralPath $Path)) {
        if (-not $Nodes.ContainsKey($row.alias)) {
            Fail "networks.csv references unknown alias: $($row.alias)"
        }
        $map[$row.alias] = $row
    }
    return $map
}

function Read-StateRows($Path) {
    Require-File $Path "state.csv"
    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -eq 0 -or $lines[0] -ne $ExpectedStateHeader) {
        Fail "state.csv header must be exactly: $ExpectedStateHeader"
    }
    return @(Import-Csv -LiteralPath $Path)
}

function Split-AliasList($Value) {
    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return @()
    }
    return @(([string]$Value).Split("+", [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-ObjectArray($Object, $PropertyName) {
    if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -contains $PropertyName)) {
        return @()
    }
    return @($Object.$PropertyName | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-StateExpandedAliases($StateRows, $Kind, $Name, $AnchorAliases) {
    $aliases = New-Object System.Collections.ArrayList
    $anchorSet = @{}
    foreach ($aliasName in @($AnchorAliases | Where-Object { $_ })) {
        $anchorSet[[string]$aliasName] = $true
    }
    foreach ($row in @($StateRows | Where-Object { $_.kind -eq $Kind -and $_.name -eq $Name -and $_.state -eq "present" })) {
        $activeAliases = @(Split-AliasList $row.active_aliases)
        $candidateAliases = @(Split-AliasList $row.candidate_aliases)
        if ($anchorSet.Count -eq 0) {
            foreach ($aliasName in @($activeAliases + $candidateAliases)) {
                [void]$aliases.Add($aliasName)
            }
            continue
        }
        $matchesAnchor = $false
        foreach ($aliasName in $activeAliases) {
            if ($anchorSet.ContainsKey($aliasName)) {
                $matchesAnchor = $true
                [void]$aliases.Add($aliasName)
                break
            }
        }
        if ($matchesAnchor) {
            foreach ($aliasName in $candidateAliases) {
                [void]$aliases.Add($aliasName)
            }
            continue
        }
        foreach ($aliasName in $candidateAliases) {
            if ($anchorSet.ContainsKey($aliasName)) {
                [void]$aliases.Add($aliasName)
            }
        }
    }
    return @($aliases.ToArray() | Sort-Object -Unique)
}

function Get-StateCascadeFallbackEgressAliases($StateRows, $IngressAliases) {
    $ingressSet = @{}
    foreach ($aliasName in @($IngressAliases | Where-Object { $_ })) {
        $ingressSet[[string]$aliasName] = $true
    }
    $aliases = New-Object System.Collections.ArrayList
    foreach ($row in @($StateRows | Where-Object { $_.kind -eq "cascade_topology" -and $_.state -eq "present" })) {
        foreach ($edge in @(Split-AliasList $row.active_aliases)) {
            if ($edge -notmatch '^([^>]+)>([^>]+)$') {
                continue
            }
            $ingress = $Matches[1]
            $egress = $Matches[2]
            if ($ingressSet.Count -eq 0 -or $ingressSet.ContainsKey($ingress)) {
                [void]$aliases.Add($egress)
            }
        }
    }
    return @($aliases.ToArray() | Sort-Object -Unique)
}

function Get-PolicyBehavior($Profile) {
    return [string]$Profile.behavior
}

function Get-PolicyIngressAnchorAliases($Profile) {
    $anchorAliases = @(Get-ObjectArray $Profile "ingress_anchor_aliases")
    return @($anchorAliases | Sort-Object -Unique)
}

function Get-PolicyIngressAliases($Profile, $StateRows) {
    $anchorAliases = @(Get-PolicyIngressAnchorAliases $Profile)
    return @(Get-StateExpandedAliases $StateRows "edge_route" "vpn_ingress" $anchorAliases)
}

function Get-PolicyFallbackEgressAliases($Profile, $StateRows) {
    $ingressAliases = @(Get-PolicyIngressAliases $Profile $StateRows)
    return @(Get-StateCascadeFallbackEgressAliases $StateRows $ingressAliases)
}

function Get-TextPreview($Text, [int]$MaxLength = 160) {
    $preview = (([string]$Text) -replace "`r", "\r" -replace "`n", "\n").Trim()
    if ($preview.Length -gt $MaxLength) {
        return $preview.Substring(0, $MaxLength) + "..."
    }
    return $preview
}

function Get-TargetDisplay($Target) {
    $protocol = [string]$Target.protocol
    $value = [string]$Target.value
    $port = [string]$Target.port
    $path = if ([string]::IsNullOrWhiteSpace([string]$Target.path)) { "/" } else { [string]$Target.path }
    if ($protocol -in @("http", "https")) {
        return "${protocol}://${value}:${port}${path}"
    }
    return "${protocol}:${value}:${port}"
}

function Get-TargetResultDisplay($Target, $TargetStatus, $HttpStatus) {
    if ($Target.protocol -in @("http", "https")) {
        if ($null -ne $HttpStatus) {
            return [string]$HttpStatus
        }
        return "FAIL"
    }
    if ($TargetStatus.ok -and $TargetStatus.result) {
        if ($Target.protocol -eq "tcp" -and $null -ne $TargetStatus.result.tcp_connect_ms) {
            return "OK"
        }
        if ($Target.protocol -eq "icmp" -and $null -ne $TargetStatus.result.icmp_ms) {
            return "OK"
        }
    }
    return "FAIL"
}

function Get-ReadinessRecordStatus($InfraOk, $Target, $TargetStatus) {
    if (-not $InfraOk) {
        return "probe_error"
    }
    if (-not $TargetStatus.ok -or -not $TargetStatus.result) {
        return "target_timeout"
    }
    $result = $TargetStatus.result
    if ($Target.protocol -in @("http", "https")) {
        if ($null -ne $result.http_status) {
            if ($result.http_status -ge 200 -and $result.http_status -lt 400) {
                return "observed"
            }
            if ($result.http_status -ge 400 -and $result.http_status -lt 500) {
                return "target_rejected"
            }
            return "probe_error"
        }
        return "target_timeout"
    }
    if ($Target.protocol -eq "tcp") {
        if ($null -ne $result.tcp_connect_ms) {
            return "observed"
        }
        return "target_timeout"
    }
    if ($Target.protocol -eq "icmp") {
        if ($null -ne $result.icmp_ms) {
            return "observed"
        }
        return "target_timeout"
    }
    return "route_review"
}

function Load-CascadeLinks($Path, $Nodes) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Fail "cascade secret directory not found: $Path"
    }
    $unifiedPath = Join-Path $Path "lab-cascade.json"
    $secretFiles = if (Test-Path -LiteralPath $unifiedPath -PathType Leaf) {
        @(Get-Item -LiteralPath $unifiedPath)
    } else {
        @(Get-ChildItem -LiteralPath $Path -File -Filter "*.json" | Sort-Object Name)
    }
    $links = New-Object System.Collections.ArrayList
    foreach ($file in $secretFiles) {
        $secret = Read-JsonFile $file.FullName "cascade secret"
        $linkItems = if ($secret.links) { @($secret.links) } else { @($secret) }
        foreach ($link in $linkItems) {
            $state = if ($link.state) { [string]$link.state } elseif ($secret.state) { [string]$secret.state } else { "active" }
            if ($state -eq "disabled") {
                continue
            }
            foreach ($field in @("connection_name", "ingress_alias", "egress_alias", "egress_host", "egress_port")) {
                if ([string]::IsNullOrWhiteSpace([string]$link.$field)) {
                    Fail "cascade secret $($file.FullName) missing field: $field"
                }
            }
            foreach ($aliasField in @("ingress_alias", "egress_alias")) {
                $aliasValue = [string]$link.$aliasField
                if (-not $Nodes.ContainsKey($aliasValue)) {
                    Fail "cascade secret $($file.FullName) references unknown ${aliasField}: $aliasValue"
                }
            }
            [void]$links.Add([pscustomobject]@{
                connection_name = [string]$link.connection_name
                ingress_alias = [string]$link.ingress_alias
                egress_alias = [string]$link.egress_alias
                egress_host = [string]$link.egress_host
                egress_port = [int]$link.egress_port
                state = $state
            })
        }
    }
    return @($links.ToArray())
}

function Find-CascadePath($Links, $IngressAlias, $EgressAlias) {
    if ($IngressAlias -eq $EgressAlias) {
        return @()
    }
    $queue = New-Object System.Collections.ArrayList
    [void]$queue.Add([pscustomobject]@{ alias = [string]$IngressAlias; path = @() })
    $visited = @{ $IngressAlias = $true }
    for ($i = 0; $i -lt $queue.Count; $i++) {
        $item = $queue[$i]
        foreach ($link in @($Links | Where-Object { $_.ingress_alias -eq $item.alias })) {
            $nextAlias = [string]$link.egress_alias
            if ($visited.ContainsKey($nextAlias)) {
                continue
            }
            $nextPath = @($item.path) + @($link)
            if ($nextAlias -eq $EgressAlias) {
                return $nextPath
            }
            $visited[$nextAlias] = $true
            [void]$queue.Add([pscustomobject]@{ alias = $nextAlias; path = $nextPath })
        }
    }
    return @()
}

function Test-TargetFromEgress($AliasName, $Target) {
    $node = $nodes[$AliasName]
    $keyFile = Join-Path (Join-Path $OperatorDir $AliasName) "admin_key"
    Require-File $keyFile "admin key for $AliasName"
    $remote = "${SshUser}@$($node.endpoint)"
    $path = if ($Target.path) { [string]$Target.path } else { "/" }
    $python = @"
import base64, json, re, socket, ssl, subprocess, sys, time, urllib.error, urllib.request
target = json.loads(base64.b64decode(sys.argv[1]).decode("utf-8"))
timeout = float(sys.argv[2])
host = target["value"]
port = int(target.get("port") or 0)
protocol = target["protocol"]
path = target.get("path") or "/"
result = {"http_status": None, "tcp_connect_ms": None, "http_total_ms": None, "icmp_ms": None, "errors": []}
if protocol == "udp":
    result["errors"].append({"stage": "udp", "message": "generic UDP readiness requires protocol-specific probe"})
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    raise SystemExit(0)
if protocol == "icmp":
    try:
        start = time.monotonic()
        proc = subprocess.run(["ping", "-c", "1", "-W", str(max(1, int(timeout))), host], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout + 1)
        output = (proc.stdout or "") + "\n" + (proc.stderr or "")
        match = re.search(r"time[=<]([0-9.]+)\s*ms", output)
        if proc.returncode == 0:
            result["icmp_ms"] = round(float(match.group(1)), 2) if match else round((time.monotonic() - start) * 1000, 2)
        else:
            result["errors"].append({"stage": "icmp", "message": output.strip() or f"ping exited {proc.returncode}"})
    except Exception as exc:
        result["errors"].append({"stage": "icmp", "message": str(exc)})
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    raise SystemExit(0)
try:
    start = time.monotonic()
    sock = socket.create_connection((host, port), timeout=timeout)
    result["tcp_connect_ms"] = round((time.monotonic() - start) * 1000, 2)
    if protocol == "https":
        ssl.create_default_context().wrap_socket(sock, server_hostname=host).close()
    else:
        sock.close()
except Exception as exc:
    result["errors"].append({"stage": "tcp_tls", "message": str(exc)})
if protocol in ("http", "https"):
    url = f"{protocol}://{host}:{port}{path}" if (protocol, port) not in (("https", 443), ("http", 80)) else f"{protocol}://{host}{path}"
    try:
        start = time.monotonic()
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent":"ai-service-platform-fallback-readiness/1"}), timeout=timeout) as response:
            result["http_status"] = response.status
            response.read(1024)
            result["http_total_ms"] = round((time.monotonic() - start) * 1000, 2)
    except urllib.error.HTTPError as exc:
        result["http_status"] = exc.code
    except Exception as exc:
        result["errors"].append({"stage": "http", "message": str(exc)})
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
"@
    $targetPayload = @{
        type = $Target.type
        value = $Target.value
        protocol = $Target.protocol
        port = [int]$Target.port
        path = $path
    } | ConvertTo-Json -Compress
    $scriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($python))
    $payloadB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($targetPayload))
    $command = "python3 -c $(Quote-BashArg "import base64,sys; exec(base64.b64decode('$scriptB64'))") $(Quote-BashArg $payloadB64) $(Quote-BashArg ([string]$TargetTimeoutSeconds))"
    $result = Invoke-SshText $keyFile $remote $command (Get-NodeSshPort $node)
    if (-not $result.ok) {
        return [pscustomobject]@{ ok = $false; error = $result.output }
    }
    try {
        return [pscustomobject]@{ ok = $true; result = ($result.output | ConvertFrom-Json) }
    } catch {
        return [pscustomobject]@{ ok = $false; error = $result.output }
    }
}

function Test-IngressPolicyNetwork($AliasName) {
    $node = $nodes[$AliasName]
    $keyFile = Join-Path (Join-Path $OperatorDir $AliasName) "admin_key"
    Require-File $keyFile "admin key for $AliasName"
    $remote = "${SshUser}@$($node.endpoint)"
    $network = $networkPlan[$AliasName]
    if (-not $network) {
        Fail "networks.csv has no row for alias: $AliasName"
    }
    $command = "sudo docker network inspect ai_service_vpn_policy --format '{{json .Containers}}'"
    $result = Invoke-SshText $keyFile $remote $command (Get-NodeSshPort $node)
    $text = [string]$result.output
    $edgeExpected = [regex]::Escape([string]$network.edge_ip)
    $gatewayExpected = [regex]::Escape([string]$network.policy_gateway_ip)
    $cascadeExpected = [regex]::Escape([string]$network.cascade_ip)
    return [pscustomobject]@{
        ok = $result.ok
        edge_attached = $result.ok -and $text -match "softether-edge" -and $text -match $edgeExpected
        gateway_attached = $result.ok -and $text -match "policy-gateway" -and $text -match $gatewayExpected
        cascade_attached = $result.ok -and $text -match "softether-cascade" -and $text -match $cascadeExpected
        expected_edge_ip = $network.edge_ip
        expected_gateway_ip = $network.policy_gateway_ip
        expected_cascade_ip = $network.cascade_ip
        error = if ($result.ok) { $null } else { $text }
    }
}

function Test-PolicyGateway($AliasName) {
    $node = $nodes[$AliasName]
    $keyFile = Join-Path (Join-Path $OperatorDir $AliasName) "admin_key"
    Require-File $keyFile "admin key for $AliasName"
    $remote = "${SshUser}@$($node.endpoint)"
    $network = $networkPlan[$AliasName]
    if (-not $network) {
        Fail "networks.csv has no row for alias: $AliasName"
    }
    $expectedGatewayIp = [string]$network.policy_gateway_ip
    $gatewayContainerArg = Quote-BashArg $PolicyGatewayContainer
    $gatewayIpCheckArg = Quote-BashArg "ip addr 2>/dev/null | grep -q '$expectedGatewayIp/'"
    $ipForwardCheckArg = Quote-BashArg 'test "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = 1'
    $routeCheckArg = Quote-BashArg 'ip route >/dev/null 2>&1'
    $natCheckArg = Quote-BashArg 'iptables -t nat -S POSTROUTING >/dev/null 2>&1 && iptables -t nat -L POSTROUTING -v -n -x >/dev/null 2>&1'
    $probe = @"
set +e
gateway_pid=`$(sudo docker inspect -f '{{.State.Pid}}' $gatewayContainerArg 2>/dev/null)
container_present=false
gateway_ip_present=false
ip_forward=false
route_table_available=false
nat_available=false
if [ -n "`$gateway_pid" ]; then
  container_present=true
fi
sudo docker exec -u 0 $gatewayContainerArg sh -c $gatewayIpCheckArg && gateway_ip_present=true
sudo docker exec -u 0 $gatewayContainerArg sh -c $ipForwardCheckArg && ip_forward=true
sudo docker exec -u 0 $gatewayContainerArg sh -c $routeCheckArg && route_table_available=true
sudo docker exec -u 0 $gatewayContainerArg sh -c $natCheckArg && nat_available=true
printf 'container_present=%s\ngateway_ip_present=%s\nip_forward=%s\nroute_table_available=%s\nnat_available=%s\n' "`$container_present" "`$gateway_ip_present" "`$ip_forward" "`$route_table_available" "`$nat_available"
[ "`$container_present" = true ] && [ "`$gateway_ip_present" = true ] && [ "`$route_table_available" = true ] && [ "`$nat_available" = true ]
"@
    $command = "sh -c $(Quote-BashArg $probe)"
    $result = Invoke-SshText $keyFile $remote $command (Get-NodeSshPort $node)
    $flags = @{}
    foreach ($line in @([string]$result.output -split "`n")) {
        if ($line -match '^([^=]+)=(true|false)$') {
            $flags[$Matches[1]] = [bool]::Parse($Matches[2])
        }
    }
    return [pscustomobject]@{
        ok = $result.ok
        container_present = [bool]($flags.container_present)
        gateway_ip_present = [bool]($flags.gateway_ip_present)
        ip_forward = [bool]($flags.ip_forward)
        route_table_available = [bool]($flags.route_table_available)
        nat_available = [bool]($flags.nat_available)
        container = $PolicyGatewayContainer
        expected_gateway_ip = $expectedGatewayIp
        error = if ($result.ok) { $null } else { $result.output }
    }
}

function Test-PolicyGatewayNatCapability($AliasName) {
    $node = $nodes[$AliasName]
    $keyFile = Join-Path (Join-Path $OperatorDir $AliasName) "admin_key"
    Require-File $keyFile "admin key for $AliasName"
    $remote = "${SshUser}@$($node.endpoint)"
    $command = "sudo docker exec -u 0 $(Quote-BashArg $PolicyGatewayContainer) sh -c $(Quote-BashArg "iptables -t nat -S POSTROUTING >/dev/null && iptables -t nat -L POSTROUTING -v -n -x >/dev/null")"
    $result = Invoke-SshText $keyFile $remote $command (Get-NodeSshPort $node)
    return [pscustomobject]@{
        ok = $result.ok
        postrouting_available = $result.ok
        counters_available = $result.ok
        error = if ($result.ok) { $null } else { $result.output }
    }
}

function Test-CascadeDataplane($AliasName) {
    $node = $nodes[$AliasName]
    $keyFile = Join-Path (Join-Path $OperatorDir $AliasName) "admin_key"
    Require-File $keyFile "admin key for $AliasName"
    $remote = "${SshUser}@$($node.endpoint)"
    $network = $networkPlan[$AliasName]
    if (-not $network) {
        Fail "networks.csv has no row for alias: $AliasName"
    }
    $expectedRouterIp = [string]$network.cascade_router_ip
    $cascadeContainerArg = Quote-BashArg $CascadeContainer
    $tapCheckArg = Quote-BashArg "ip link show '$TapInterface' >/dev/null 2>&1"
    $routerIpCheckArg = Quote-BashArg "ip addr 2>/dev/null | grep -q '$expectedRouterIp/'"
    $routeCheckArg = Quote-BashArg 'ip route >/dev/null 2>&1'
    $natCheckArg = Quote-BashArg 'iptables -t nat -S POSTROUTING >/dev/null 2>&1 && iptables -t nat -L POSTROUTING -v -n -x >/dev/null 2>&1'
    $probe = @"
set +e
container_present=false
tap_present=false
router_ip_present=false
route_table_available=false
nat_available=false
pid=`$(sudo docker inspect -f '{{.State.Pid}}' $cascadeContainerArg 2>/dev/null)
if [ -n "`$pid" ]; then
  container_present=true
fi
sudo docker exec -u 0 $cascadeContainerArg sh -c $tapCheckArg && tap_present=true
sudo docker exec -u 0 $cascadeContainerArg sh -c $routerIpCheckArg && router_ip_present=true
sudo docker exec -u 0 $cascadeContainerArg sh -c $routeCheckArg && route_table_available=true
sudo docker exec -u 0 $cascadeContainerArg sh -c $natCheckArg && nat_available=true
printf 'container_present=%s\ntap_present=%s\nrouter_ip_present=%s\nroute_table_available=%s\nnat_available=%s\n' "`$container_present" "`$tap_present" "`$router_ip_present" "`$route_table_available" "`$nat_available"
[ "`$container_present" = true ] && [ "`$tap_present" = true ] && [ "`$router_ip_present" = true ] && [ "`$route_table_available" = true ] && [ "`$nat_available" = true ]
"@
    $command = "sh -c $(Quote-BashArg $probe)"
    $result = Invoke-SshText $keyFile $remote $command (Get-NodeSshPort $node)
    $flags = @{}
    foreach ($line in @([string]$result.output -split "`n")) {
        if ($line -match '^([^=]+)=(true|false)$') {
            $flags[$Matches[1]] = [bool]::Parse($Matches[2])
        }
    }
    return [pscustomobject]@{
        ok = $result.ok
        container_present = [bool]($flags.container_present)
        tap_present = [bool]($flags.tap_present)
        router_ip_present = [bool]($flags.router_ip_present)
        route_table_available = [bool]($flags.route_table_available)
        nat_available = [bool]($flags.nat_available)
        container = $CascadeContainer
        interface = $TapInterface
        expected_router_ip = $expectedRouterIp
        error = if ($result.ok) { $null } else { $result.output }
    }
}

function Test-CascadeTcp($Link) {
    $node = $nodes[$Link.ingress_alias]
    $keyFile = Join-Path (Join-Path $OperatorDir $Link.ingress_alias) "admin_key"
    Require-File $keyFile "admin key for $($Link.ingress_alias)"
    $remote = "${SshUser}@$($node.endpoint)"
    $command = "python3 -c $(Quote-BashArg 'import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=float(sys.argv[3])).close()') $(Quote-BashArg $Link.egress_host) $(Quote-BashArg ([string]$Link.egress_port)) $(Quote-BashArg ([string]$TimeoutSeconds))"
    $result = Invoke-SshText $keyFile $remote $command (Get-NodeSshPort $node)
    return [pscustomobject]@{ reachable = $result.ok; error = if ($result.ok) { $null } else { $result.output } }
}

Require-File $PolicyFile "egress policy registry"
$script:SshExecutablePath = if ($DryRun) { $SshPath } else { Resolve-SshExecutable $SshPath }
$nodes = Load-Nodes $NodesFile
$stateRows = Read-StateRows $StateFile
$networkPlan = Load-NetworkPlan $NetworksFile $nodes
$policy = Read-JsonFile $PolicyFile "egress policy registry"
$links = Load-CascadeLinks $CascadeSecretDir $nodes
$profileFilter = @($ProfileName | Where-Object { $_ })
$aliasFilter = @($Alias | Where-Object { $_ })
$profiles = @($policy.profiles | Where-Object {
    ($profileFilter.Count -eq 0 -or $profileFilter -contains $_.name) -and $_.state -eq "probe"
})

if ($profiles.Count -eq 0) {
    Write-Host "No enabled egress policy profiles selected."
    exit 0
}

$runId = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$records = New-Object System.Collections.ArrayList
foreach ($profile in $profiles) {
    $behavior = Get-PolicyBehavior $profile
    if ($behavior -ne "fallback_on_ingress_egress_failure") {
        Fail "profile $($profile.name) behavior is not supported by readiness check: $behavior"
    }
    $ingressAliases = @(Get-PolicyIngressAliases $profile $stateRows | Where-Object { $aliasFilter.Count -eq 0 -or $aliasFilter -contains $_ })
    $fallbackEgressAliases = @(Get-PolicyFallbackEgressAliases $profile $stateRows)
    if ($fallbackEgressAliases.Count -eq 0) {
        Fail "profile $($profile.name) must derive fallback egress aliases from state.csv cascade_topology"
    }
    foreach ($target in @($profile.targets)) {
        foreach ($ingressAlias in $ingressAliases) {
            foreach ($egressAlias in $fallbackEgressAliases) {
            $path = @(Find-CascadePath $links $ingressAlias $egressAlias)
            if ($path.Count -eq 0) {
                Write-Host "No cascade path for readiness $($profile.name): $ingressAlias -> $egressAlias"
                continue
            }
            if ($DryRun) {
                Write-Host "[dry-run] readiness $($profile.name): $ingressAlias edge->policy-gateway -> $($path.connection_name -join '->') -> $(Get-TargetDisplay $target)"
                continue
            }
            $policyNetwork = Test-IngressPolicyNetwork $ingressAlias
            $ingressGateway = Test-PolicyGateway $ingressAlias
            $ingressCascade = Test-CascadeDataplane $ingressAlias
            $egressCascade = Test-CascadeDataplane $egressAlias
            $ingressNat = Test-PolicyGatewayNatCapability $ingressAlias
            $egressNat = [pscustomobject]@{
                ok = $egressCascade.nat_available
                postrouting_available = $egressCascade.nat_available
                counters_available = $egressCascade.nat_available
                error = $egressCascade.error
            }
            $tcpResults = @($path | ForEach-Object { Test-CascadeTcp $_ })
            $tcp = [pscustomobject]@{
                reachable = @($tcpResults | Where-Object { -not $_.reachable }).Count -eq 0
                hops = $tcpResults
            }
            $targetStatus = Test-TargetFromEgress $egressAlias $target
            $httpStatus = if ($targetStatus.ok -and $targetStatus.result) { $targetStatus.result.http_status } else { $null }
            $infraOk = $policyNetwork.edge_attached -and $policyNetwork.gateway_attached -and $policyNetwork.cascade_attached -and $ingressGateway.ok -and $ingressCascade.ok -and $egressCascade.ok -and $ingressNat.ok -and $egressNat.ok -and $tcp.reachable
            $recordStatus = Get-ReadinessRecordStatus $infraOk $target $targetStatus
            $record = [ordered]@{
                schema_version = 1
                run_id = $runId
                observed_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
                path_mode = "dataplane_readiness"
                profile = $profile.name
                behavior = $behavior
                ingress_alias = $ingressAlias
                egress_alias = $egressAlias
                cascade_connection = ($path.connection_name -join "->")
                cascade_connections = @($path.connection_name)
                cascade_path = @($path | ForEach-Object { [pscustomobject]@{ connection = $_.connection_name; ingress_alias = $_.ingress_alias; egress_alias = $_.egress_alias } })
                target = $target
                policy_network_status = $policyNetwork
                ingress_gateway_status = $ingressGateway
                ingress_cascade_status = $ingressCascade
                egress_cascade_status = $egressCascade
                ingress_nat_status = $ingressNat
                egress_nat_status = $egressNat
                cascade_transport_status = $tcp
                target_status = if ($targetStatus.ok) { $targetStatus.result } else { $null }
                status = $recordStatus
                error = if ($targetStatus.ok) { $null } else { $targetStatus.error }
            }
            [void]$records.Add([pscustomobject]$record)
            $targetDisplay = Get-TargetDisplay $target
            $targetResult = Get-TargetResultDisplay $target $targetStatus $httpStatus
            $connectionPath = $path.connection_name -join "->"
            $errorSuffix = ""
            if ($targetResult -eq "FAIL") {
                $errorText = if ($targetStatus.ok -and $targetStatus.result -and $targetStatus.result.errors) {
                    (($targetStatus.result.errors | ForEach-Object { "$($_.stage): $($_.message)" }) -join "; ")
                } elseif (-not $targetStatus.ok) {
                    $targetStatus.error
                } else {
                    ""
                }
                if (-not [string]::IsNullOrWhiteSpace($errorText)) {
                    $errorSuffix = " error=`"$(Get-TextPreview $errorText)`""
                }
            }
            Write-Host ("[{0}] {1} -> {2} via {3} | target {4} | infra={5} target={6} status={7}{8}" -f $profile.name, $ingressAlias, $egressAlias, $connectionPath, $targetDisplay, ($(if ($infraOk) { "OK" } else { "FAIL" })), $targetResult, $record.status, $errorSuffix)
            }
        }
    }
}

if ($DryRun) {
    Write-Host "Dry-run completed. No readiness records were written."
    exit 0
}

if ($records.Count -eq 0) {
    Write-Host "No readiness records produced."
    exit 0
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$outputPath = Join-Path $OutputDir "selective-fallback-readiness-$runId.jsonl"
foreach ($record in $records) {
    $record | ConvertTo-Json -Depth 20 -Compress | Add-Content -LiteralPath $outputPath -Encoding utf8
}

if ($Json) {
    $records | ConvertTo-Json -Depth 20
} else {
    Write-Host "[OK] Selective fallback readiness history written: $outputPath"
}
