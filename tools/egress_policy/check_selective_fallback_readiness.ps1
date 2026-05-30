param(
    [string]$PolicyFile = ".\operator\egress_policy\profiles.json",
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$NetworksFile = ".\operator\networks.csv",
    [string]$OperatorDir = ".\operator",
    [string]$CascadeSecretDir = ".\operator\softether\cascade\secrets",
    [string]$OutputDir = ".\operator\egress_policy\history",
    [string]$SshUser = "useradmin",
    [string]$SshPath = "ssh",
    [string[]]$ProfileName = @(),
    [string[]]$Alias = @(),
    [int]$TimeoutSeconds = 10,
    [switch]$DryRun,
    [switch]$Json,
    [switch]$AutoAcceptHostKey = $true
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,connection,root_password"
$ExpectedNetworksHeader = "alias,policy_subnet,edge_ip,cascade_ip,cascade_router_ip"

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
        "-o", "ConnectTimeout=10",
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

function Invoke-SshText($KeyFile, $Remote, $Command) {
    $sshArgs = @("-n", "-T") + @(Get-OpenSshCommonArgs $KeyFile) + @($Remote, $Command)
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

function Get-PolicyBehavior($Profile) {
    return [string]$Profile.behavior
}

function Get-PolicyIngressAliases($Profile) {
    return @($Profile.candidate_ingress_aliases | Where-Object { $_ })
}

function Get-PolicyFallbackLinks($Profile) {
    if ($null -eq $Profile.candidate_fallback_links) {
        return @()
    }
    return @($Profile.candidate_fallback_links | Where-Object { $_ })
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

function Test-TargetFromEgress($AliasName, $Target) {
    $node = $nodes[$AliasName]
    $keyFile = Join-Path (Join-Path $OperatorDir $AliasName) "admin_key"
    Require-File $keyFile "admin key for $AliasName"
    $remote = "${SshUser}@$($node.endpoint)"
    $path = if ($Target.path) { [string]$Target.path } else { "/" }
    $python = @"
import json, socket, ssl, sys, time, urllib.error, urllib.request
target = json.loads(sys.argv[1])
timeout = float(sys.argv[2])
host = target["value"]
port = int(target["port"])
protocol = target["protocol"]
path = target.get("path") or "/"
result = {"http_status": None, "tcp_connect_ms": None, "http_total_ms": None, "errors": []}
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
    $payloadArg = Quote-BashArg $targetPayload
    $command = "python3 -c $(Quote-BashArg "import base64,sys; exec(base64.b64decode('$scriptB64'))") $payloadArg $(Quote-BashArg ([string]$TimeoutSeconds))"
    $result = Invoke-SshText $keyFile $remote $command
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
    $result = Invoke-SshText $keyFile $remote $command
    $text = [string]$result.output
    $edgeExpected = [regex]::Escape([string]$network.edge_ip)
    $cascadeExpected = [regex]::Escape([string]$network.cascade_ip)
    return [pscustomobject]@{
        ok = $result.ok
        edge_attached = $result.ok -and $text -match "softether-edge" -and $text -match $edgeExpected
        cascade_attached = $result.ok -and $text -match "softether-cascade" -and $text -match $cascadeExpected
        expected_edge_ip = $network.edge_ip
        expected_cascade_ip = $network.cascade_ip
        error = if ($result.ok) { $null } else { $text }
    }
}

function Test-CascadeTcp($Link) {
    $node = $nodes[$Link.ingress_alias]
    $keyFile = Join-Path (Join-Path $OperatorDir $Link.ingress_alias) "admin_key"
    Require-File $keyFile "admin key for $($Link.ingress_alias)"
    $remote = "${SshUser}@$($node.endpoint)"
    $command = "python3 -c $(Quote-BashArg 'import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=float(sys.argv[3])).close()') $(Quote-BashArg $Link.egress_host) $(Quote-BashArg ([string]$Link.egress_port)) $(Quote-BashArg ([string]$TimeoutSeconds))"
    $result = Invoke-SshText $keyFile $remote $command
    return [pscustomobject]@{ reachable = $result.ok; error = if ($result.ok) { $null } else { $result.output } }
}

Require-File $PolicyFile "egress policy registry"
$script:SshExecutablePath = if ($DryRun) { $SshPath } else { Resolve-SshExecutable $SshPath }
$nodes = Load-Nodes $NodesFile
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
    $ingressAliases = @(Get-PolicyIngressAliases $profile | Where-Object { $aliasFilter.Count -eq 0 -or $aliasFilter -contains $_ })
    $fallbackLinkNames = @(Get-PolicyFallbackLinks $profile)
    foreach ($target in @($profile.targets)) {
        foreach ($link in @($links | Where-Object {
            $ingressAliases -contains $_.ingress_alias -and ($fallbackLinkNames.Count -eq 0 -or $fallbackLinkNames -contains $_.connection_name)
        })) {
            if ($DryRun) {
                Write-Host "[dry-run] readiness $($profile.name): $($link.ingress_alias) edge->cascade -> $($link.connection_name) -> $($target.value)"
                continue
            }
            $policyNetwork = Test-IngressPolicyNetwork $link.ingress_alias
            $tcp = Test-CascadeTcp $link
            $targetStatus = Test-TargetFromEgress $link.egress_alias $target
            $httpStatus = if ($targetStatus.ok -and $targetStatus.result) { $targetStatus.result.http_status } else { $null }
            $record = [ordered]@{
                schema_version = 1
                run_id = $runId
                observed_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
                path_mode = "dataplane_readiness"
                profile = $profile.name
                behavior = $behavior
                ingress_alias = $link.ingress_alias
                egress_alias = $link.egress_alias
                cascade_connection = $link.connection_name
                target = $target
                policy_network_status = $policyNetwork
                cascade_transport_status = $tcp
                target_status = if ($targetStatus.ok) { $targetStatus.result } else { $null }
                status = if ($policyNetwork.edge_attached -and $policyNetwork.cascade_attached -and $tcp.reachable -and $targetStatus.ok) { "observed" } else { "probe_error" }
                error = if ($targetStatus.ok) { $null } else { $targetStatus.error }
            }
            [void]$records.Add([pscustomobject]$record)
            Write-Host ("{0}: edge_policy={1}/{2} cascade_tcp={3} target_http={4}" -f $link.connection_name, $policyNetwork.edge_attached, $policyNetwork.cascade_attached, $tcp.reachable, $httpStatus)
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
