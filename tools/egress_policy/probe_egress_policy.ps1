param(
    [string]$PolicyFile = ".\operator\egress_policy\profiles.json",
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$OperatorDir = ".\operator",
    [string]$OutputDir = ".\operator\egress_policy\history",
    [string]$CascadeSecretDir = ".\operator\softether\cascade\secrets",
    [string]$SshUser = "useradmin",
    [string]$SshPath = "ssh",
    [Alias("Profile")]
    [string[]]$ProfileName = @(),
    [string[]]$Alias = @(),
    [int]$TimeoutSeconds = 10,
    [int]$ProbeAttempts = 3,
    [int]$ProbeRetryDelaySeconds = 2,
    [switch]$DryRun,
    [switch]$IncludeCascade,
    [switch]$CascadeOnly,
    [switch]$PreferCascade,
    [switch]$AutoAcceptHostKey = $true
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,connection,root_password"

function Fail($Message) {
    Write-Error $Message
    exit 1
}

if ($ProbeAttempts -lt 1) {
    Fail "-ProbeAttempts must be at least 1"
}
if ($ProbeRetryDelaySeconds -lt 0) {
    Fail "-ProbeRetryDelaySeconds must be 0 or greater"
}
if ($TimeoutSeconds -lt 1) {
    Fail "-TimeoutSeconds must be at least 1"
}
if ($CascadeOnly -and ($IncludeCascade -or $PreferCascade)) {
    Fail "-CascadeOnly cannot be combined with -IncludeCascade or -PreferCascade"
}
if ($IncludeCascade -and $PreferCascade) {
    Fail "-IncludeCascade cannot be combined with -PreferCascade"
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

function Resolve-ProbePath($Path, $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Label not found: $Path"
    }
    try {
        return [string](Resolve-Path -LiteralPath $Path).Path
    } catch {
        Fail "failed to resolve ${Label}: $Path"
    }
}

function Resolve-SshExecutable($Path) {
    try {
        $command = Get-Command $Path -ErrorAction Stop
    } catch {
        Fail "SSH executable not found: $Path. Install OpenSSH or pass -SshPath with the path to a real ssh executable."
    }

    $resolvedPath = [string]$command.Path
    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        Fail "SSH executable path could not be resolved for: $Path"
    }

    $lowerPath = $resolvedPath.ToLowerInvariant()
    if ($lowerPath -like "*.sbx-denybin*" -or $lowerPath.EndsWith(".bat") -or $lowerPath.EndsWith(".cmd")) {
        Fail "Resolved SSH path is not a real OpenSSH executable: $resolvedPath. Pass -SshPath with the path to a real ssh executable."
    }

    return $resolvedPath
}

function Get-RawOutputPreview($Text) {
    $preview = (([string]$Text) -replace "`r", "\r" -replace "`n", "\n").Trim()
    if ($preview.Length -gt 240) {
        return $preview.Substring(0, 240) + "..."
    }
    return $preview
}

function Get-OpenSshCommonArgs($KeyFile) {
    $connectTimeout = [Math]::Max(1, [Math]::Min(10, $TimeoutSeconds))
    $args = @(
        "-i", $KeyFile,
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=$connectTimeout",
        "-o", "IdentitiesOnly=yes",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "PasswordAuthentication=no",
        "-o", "PreferredAuthentications=publickey",
        "-o", "RequestTTY=no",
        "-o", "ServerAliveInterval=10",
        "-o", "ServerAliveCountMax=2"
    )
    if ($AutoAcceptHostKey) {
        $args += @("-o", "StrictHostKeyChecking=accept-new")
    }
    return $args
}

function Invoke-SshJsonProbe($KeyFile, $Remote, $Command, $Label) {
    $sshArgs = @("-n", "-T") + @(Get-OpenSshCommonArgs $KeyFile) + @($Remote, $Command)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $script:ErrorActionPreference = "Continue"
        $output = & $script:SshExecutablePath @sshArgs
        $exitCode = $LASTEXITCODE
    } finally {
        $script:ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        $raw = @($output) -join "`n"
        return [pscustomobject]@{
            ok = $false
            error = "$Label failed with exit code $exitCode; raw preview: $(Get-RawOutputPreview $raw)"
            raw = $raw
        }
    }
    $text = (@($output) -join "`n").Trim()
    if (-not $text) {
        return [pscustomobject]@{
            ok = $false
            error = "$Label returned empty output"
            raw = ""
        }
    }
    try {
        $parsed = $text | ConvertFrom-Json
        return [pscustomobject]@{
            ok = $true
            result = $parsed
            raw = $text
        }
    } catch {
        return [pscustomobject]@{
            ok = $false
            error = "$Label returned non-JSON output; raw preview: $(Get-RawOutputPreview $text)"
            raw = $text
        }
    }
}

function Invoke-SshTextCommand($KeyFile, $Remote, $Command, $Label) {
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
        label = $Label
        output = @($output) -join "`n"
    }
}

function Load-Nodes($Path) {
    Require-File $Path "nodes.csv"
    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -eq 0 -or $lines[0] -ne $ExpectedNodesHeader) {
        Fail "nodes.csv header must be exactly: $ExpectedNodesHeader"
    }
    $rows = @(Import-Csv -LiteralPath $Path)
    $map = @{}
    foreach ($row in $rows) {
        if (-not $row.current_alias -or -not $row.endpoint -or -not $row.connection) {
            Fail "nodes.csv has an incomplete row"
        }
        if ($map.ContainsKey($row.current_alias)) {
            Fail "nodes.csv has duplicate alias: $($row.current_alias)"
        }
        $map[$row.current_alias] = $row
    }
    return $map
}

function Get-PolicyBehavior($Profile) {
    return [string]$Profile.behavior
}

function Get-PolicyIngressAliases($Profile) {
    return @($Profile.candidate_ingress_aliases | Where-Object { $_ })
}

function Get-PolicyFallbackEgressAliases($Profile) {
    if ($null -eq $Profile.candidate_fallback_egress_aliases) {
        return @()
    }
    return @($Profile.candidate_fallback_egress_aliases | Where-Object { $_ })
}

function Validate-Policy($Policy, $Nodes) {
    if ($Policy.version -ne 1) {
        Fail "egress policy registry version must be 1"
    }
    if ($null -eq $Policy.profiles) {
        Fail "egress policy registry must include profiles array"
    }

    $seenProfiles = @{}
    foreach ($profile in @($Policy.profiles)) {
        if (-not $profile.name -or $profile.name -notmatch '^[a-z][a-z0-9_]*$') {
            Fail "egress profile name must match ^[a-z][a-z0-9_]*$ : $($profile.name)"
        }
        if ($seenProfiles.ContainsKey($profile.name)) {
            Fail "duplicate egress profile name: $($profile.name)"
        }
        $seenProfiles[$profile.name] = $true

        if ($profile.state -notin @("probe", "disabled")) {
            Fail "egress profile $($profile.name) state must be one of: probe, disabled"
        }
        if ([string]::IsNullOrWhiteSpace([string]$profile.reason)) {
            Fail "egress profile $($profile.name) must include reason"
        }
        if ([string]::IsNullOrWhiteSpace([string]$profile.rollback)) {
            Fail "egress profile $($profile.name) must include rollback"
        }
        $behavior = Get-PolicyBehavior $profile
        if ([string]::IsNullOrWhiteSpace($behavior)) {
            Fail "egress profile $($profile.name) must include behavior"
        }
        if ($behavior -notin @("fallback_on_ingress_egress_failure", "require_non_ru_egress")) {
            Fail "egress profile $($profile.name) behavior must be one of: fallback_on_ingress_egress_failure, require_non_ru_egress"
        }
        if (-not $profile.targets -or $profile.targets.Count -eq 0) {
            Fail "egress profile $($profile.name) must include at least one target"
        }
        $ingressAliases = @(Get-PolicyIngressAliases $profile)
        if ($ingressAliases.Count -eq 0) {
            Fail "egress profile $($profile.name) must include candidate_ingress_aliases"
        }

        $seenAliases = @{}
        foreach ($alias in $ingressAliases) {
            if (-not $Nodes.ContainsKey($alias)) {
                Fail "egress profile $($profile.name) references unknown alias: $alias"
            }
            if ($seenAliases.ContainsKey($alias)) {
                Fail "egress profile $($profile.name) has duplicate candidate ingress alias: $alias"
            }
            $seenAliases[$alias] = $true
        }

        $seenFallbackEgressAliases = @{}
        $fallbackEgressAliases = @(Get-PolicyFallbackEgressAliases $profile)
        if ($behavior -eq "fallback_on_ingress_egress_failure" -and $fallbackEgressAliases.Count -eq 0) {
            Fail "egress profile $($profile.name) must include candidate_fallback_egress_aliases"
        }
        foreach ($egressAlias in $fallbackEgressAliases) {
            if ([string]::IsNullOrWhiteSpace([string]$egressAlias)) {
                Fail "egress profile $($profile.name) has empty candidate fallback egress alias"
            }
            if (-not $Nodes.ContainsKey($egressAlias)) {
                Fail "egress profile $($profile.name) references unknown fallback egress alias: $egressAlias"
            }
            if ($seenFallbackEgressAliases.ContainsKey($egressAlias)) {
                Fail "egress profile $($profile.name) has duplicate candidate fallback egress alias: $egressAlias"
            }
            $seenFallbackEgressAliases[$egressAlias] = $true
        }

        foreach ($target in @($profile.targets)) {
            if ($target.type -notin @("domain", "ip")) {
                Fail "egress profile $($profile.name) target type must be domain or ip"
            }
            if ([string]::IsNullOrWhiteSpace([string]$target.value)) {
                Fail "egress profile $($profile.name) target value must not be empty"
            }
            if ($target.protocol -notin @("https", "http", "tcp", "udp", "icmp")) {
                Fail "egress profile $($profile.name) target protocol must be https, http, tcp, udp, or icmp"
            }
            $port = [int]$target.port
            if (($target.protocol -eq "icmp" -and $port -ne 0) -or ($target.protocol -ne "icmp" -and ($port -le 0 -or $port -gt 65535))) {
                Fail "egress profile $($profile.name) target port must be 0 for icmp or in 1..65535 for other protocols"
            }
        }
    }
}

function Load-CascadeLinks($Path, $Nodes) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Fail "cascade secret directory not found: $Path"
    }

    $links = New-Object System.Collections.ArrayList
    $unifiedPath = Join-Path $Path "lab-cascade.json"
    $secretFiles = if (Test-Path -LiteralPath $unifiedPath -PathType Leaf) {
        @(Get-Item -LiteralPath $unifiedPath)
    } else {
        @(Get-ChildItem -LiteralPath $Path -File -Filter "*.json" | Sort-Object Name)
    }
    foreach ($file in $secretFiles) {
        $secret = Read-JsonFile $file.FullName "cascade link secret"
        foreach ($field in @("hub_name", "server_password")) {
            if ([string]::IsNullOrWhiteSpace([string]$secret.$field)) {
                Fail "cascade link secret $($file.FullName) missing required shared field: $field"
            }
        }

        $linkItems = if ($secret.links) { @($secret.links) } else { @($secret) }
        foreach ($link in $linkItems) {
            $state = if ($link.state) { [string]$link.state } elseif ($secret.state) { [string]$secret.state } else { "active" }
            if ($state -notin @("active", "probe", "disabled")) {
                Fail "cascade link secret $($file.FullName) state must be one of: active, probe, disabled"
            }
            if ($state -eq "disabled") {
                continue
            }
            foreach ($field in @("connection_name", "ingress_alias", "egress_alias", "egress_host", "egress_port")) {
                if ([string]::IsNullOrWhiteSpace([string]$link.$field)) {
                    Fail "cascade link secret $($file.FullName) missing required link field: $field"
                }
            }
            foreach ($aliasField in @("ingress_alias", "egress_alias")) {
                $aliasValue = [string]$link.$aliasField
                if (-not $Nodes.ContainsKey($aliasValue)) {
                    Fail "cascade link secret $($file.FullName) references unknown ${aliasField}: $aliasValue"
                }
            }
            $port = [int]$link.egress_port
            if ($port -le 0 -or $port -gt 65535) {
                Fail "cascade link secret $($file.FullName) has invalid egress_port: $($link.egress_port)"
            }
            [void]$links.Add([pscustomobject]@{
                source_file = $file.FullName
                hub_name = [string]$secret.hub_name
                connection_name = [string]$link.connection_name
                ingress_alias = [string]$link.ingress_alias
                ingress_host = [string]$link.ingress_host
                egress_alias = [string]$link.egress_alias
                egress_host = [string]$link.egress_host
                egress_port = $port
                server_password = [string]$secret.server_password
                state = $state
            })
        }
    }
    $loadedLinks = @($links.ToArray())
    Assert-CascadeLinksAreAcyclic $loadedLinks
    return $loadedLinks
}

function Assert-CascadeLinksAreAcyclic($Links) {
    if ($Links.Count -le 1) {
        return
    }

    $nodes = @{}
    $outgoing = @{}
    $inDegree = @{}
    $seenEdges = @{}
    $edgeLabels = New-Object System.Collections.ArrayList

    foreach ($link in $Links) {
        if ($link.state -eq "disabled") {
            continue
        }
        $from = [string]$link.ingress_alias
        $to = [string]$link.egress_alias
        if ($from -eq $to) {
            Fail "cascade link cannot point to itself: $from -> $to"
        }
        $edgeKey = "$from->$to"
        if ($seenEdges.ContainsKey($edgeKey)) {
            Fail "cascade links contain duplicate directed edge: $edgeKey"
        }
        $seenEdges[$edgeKey] = $true
        [void]$edgeLabels.Add($edgeKey)

        foreach ($node in @($from, $to)) {
            if (-not $nodes.ContainsKey($node)) {
                $nodes[$node] = $true
                $outgoing[$node] = New-Object System.Collections.ArrayList
                $inDegree[$node] = 0
            }
        }
        [void]$outgoing[$from].Add($to)
        $inDegree[$to] = [int]$inDegree[$to] + 1
    }

    $queue = New-Object System.Collections.ArrayList
    foreach ($node in $nodes.Keys) {
        if ([int]$inDegree[$node] -eq 0) {
            [void]$queue.Add($node)
        }
    }

    $visited = 0
    for ($i = 0; $i -lt $queue.Count; $i++) {
        $node = [string]$queue[$i]
        $visited++
        foreach ($next in @($outgoing[$node])) {
            $inDegree[$next] = [int]$inDegree[$next] - 1
            if ([int]$inDegree[$next] -eq 0) {
                [void]$queue.Add($next)
            }
        }
    }

    if ($visited -lt $nodes.Count) {
        Fail "cascade links contain a directed cycle; active/probe cascade graph must be acyclic: $($edgeLabels -join ', ')"
    }
}

function Find-CascadePath($Links, $IngressAlias, $EgressAlias) {
    if ($IngressAlias -eq $EgressAlias) {
        return @()
    }

    $queue = New-Object System.Collections.ArrayList
    [void]$queue.Add([pscustomobject]@{
        alias = [string]$IngressAlias
        path = @()
    })
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
            [void]$queue.Add([pscustomobject]@{
                alias = $nextAlias
                path = $nextPath
            })
        }
    }
    return @()
}

function Get-CascadePathLabel($PathLinks) {
    $links = @($PathLinks)
    if ($links.Count -eq 0) {
        return ""
    }
    $aliases = New-Object System.Collections.ArrayList
    [void]$aliases.Add([string]$links[0].ingress_alias)
    foreach ($link in $links) {
        [void]$aliases.Add([string]$link.egress_alias)
    }
    return ($aliases -join "->")
}

$remotePython = @'
import base64
import datetime as dt
import json
import re
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

payload = json.loads(base64.b64decode(sys.argv[1]).decode("utf-8"))
target = payload["target"]
timeout = float(payload["timeout_seconds"])

host = target["value"]
port = int(target.get("port") or 0)
protocol = target["protocol"]
path = target.get("path") or "/"

result = {
    "started_at_utc": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "target": target,
    "dns_addresses": [],
    "dns_ms": None,
    "tcp_connect_ms": None,
    "tls_handshake_ms": None,
    "http_status": None,
    "http_final_url": None,
    "http_first_byte_ms": None,
    "http_total_ms": None,
    "icmp_ms": None,
    "external_ip": None,
    "external_country": None,
    "errors": [],
}

def record_error(stage, exc):
    result["errors"].append({"stage": stage, "message": str(exc)})

if protocol == "icmp":
    try:
        timeout_int = max(1, int(timeout))
        start = time.monotonic()
        proc = subprocess.run(["ping", "-c", "1", "-W", str(timeout_int), host], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout + 1)
        output = (proc.stdout or "") + "\n" + (proc.stderr or "")
        match = re.search(r"time[=<]([0-9.]+)\s*ms", output)
        if proc.returncode == 0:
            result["icmp_ms"] = round(float(match.group(1)), 2) if match else round((time.monotonic() - start) * 1000, 2)
        else:
            record_error("icmp", output.strip() or f"ping exited {proc.returncode}")
    except Exception as exc:
        record_error("icmp", exc)

try:
    start = time.monotonic()
    lookup_port = port if port > 0 else None
    infos = socket.getaddrinfo(host, lookup_port, type=socket.SOCK_STREAM)
    result["dns_ms"] = round((time.monotonic() - start) * 1000, 2)
    addresses = []
    for info in infos:
        address = info[4][0]
        if address not in addresses:
            addresses.append(address)
    result["dns_addresses"] = addresses
except Exception as exc:
    infos = []
    record_error("dns", exc)

if infos and protocol not in ("icmp", "udp"):
    family, socktype, proto, _, sockaddr = infos[0]
    sock = None
    try:
        sock = socket.socket(family, socktype, proto)
        sock.settimeout(timeout)
        start = time.monotonic()
        sock.connect(sockaddr)
        result["tcp_connect_ms"] = round((time.monotonic() - start) * 1000, 2)
        if protocol == "https":
            start = time.monotonic()
            context = ssl.create_default_context()
            tls_sock = context.wrap_socket(sock, server_hostname=host)
            result["tls_handshake_ms"] = round((time.monotonic() - start) * 1000, 2)
            tls_sock.close()
            sock = None
    except Exception as exc:
        record_error("tcp_tls", exc)
    finally:
        if sock is not None:
            try:
                sock.close()
            except Exception:
                pass

if protocol in ("https", "http"):
    url = f"{protocol}://{host}:{port}{path}" if (protocol, port) not in (("https", 443), ("http", 80)) else f"{protocol}://{host}{path}"
    req = urllib.request.Request(url, headers={"User-Agent": "ai-service-platform-egress-probe/1"})
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            result["http_first_byte_ms"] = round((time.monotonic() - start) * 1000, 2)
            result["http_status"] = response.status
            result["http_final_url"] = response.geturl()
            response.read(1024)
            result["http_total_ms"] = round((time.monotonic() - start) * 1000, 2)
    except urllib.error.HTTPError as exc:
        result["http_first_byte_ms"] = round((time.monotonic() - start) * 1000, 2)
        result["http_total_ms"] = result["http_first_byte_ms"]
        result["http_status"] = exc.code
        result["http_final_url"] = exc.geturl()
    except Exception as exc:
        record_error("http", exc)

try:
    req = urllib.request.Request("https://ipinfo.io/json", headers={"User-Agent": "ai-service-platform-egress-probe/1"})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        body = json.loads(response.read(16384).decode("utf-8"))
    result["external_ip"] = body.get("ip")
    result["external_country"] = body.get("country")
except Exception as exc:
    record_error("external_ip_country", exc)

print(json.dumps(result, sort_keys=True, separators=(",", ":")))
'@

$remoteTcpCheckPython = @'
import json
import socket
import sys
import time

host = sys.argv[1]
port = int(sys.argv[2])
timeout = float(sys.argv[3])
result = {
    "host": host,
    "port": port,
    "reachable": False,
    "tcp_connect_ms": None,
    "error": None,
}
try:
    start = time.monotonic()
    sock = socket.create_connection((host, port), timeout=timeout)
    result["tcp_connect_ms"] = round((time.monotonic() - start) * 1000, 2)
    result["reachable"] = True
    sock.close()
except Exception as exc:
    result["error"] = str(exc)

print(json.dumps(result, sort_keys=True, separators=(",", ":")))
'@

function New-TargetPayload($Target) {
    return @{
        timeout_seconds = $TimeoutSeconds
        target = @{
            type = $Target.type
            value = $Target.value
            protocol = $Target.protocol
            port = [int]$Target.port
            path = if ($Target.path) { $Target.path } else { "/" }
        }
    } | ConvertTo-Json -Depth 8 -Compress
}

function New-TargetProbeCommand($Target) {
    $payload = New-TargetPayload $Target
    $scriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($remotePython))
    $payloadB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload))
    return "python3 -c $(Quote-BashArg "import base64,sys; exec(base64.b64decode('$scriptB64'))") $(Quote-BashArg $payloadB64)"
}

function Test-TargetProbeSuccess($Probe, $Target) {
    if (-not $Probe.ok) {
        return $false
    }
    if ($Target.protocol -eq "tcp") {
        return ($null -ne $Probe.result.tcp_connect_ms)
    }
    if ($Target.protocol -eq "icmp") {
        return ($null -ne $Probe.result.icmp_ms)
    }
    if ($Target.protocol -eq "udp") {
        return $false
    }
    $status = $Probe.result.http_status
    return ($null -ne $status -and $status -ge 200 -and $status -lt 400)
}

function Test-TargetProbeShouldRetry($Probe, $Target) {
    if (-not $Probe.ok) {
        return $true
    }
    if ($Target.protocol -in @("https", "http") -and $null -eq $Probe.result.http_status) {
        return $true
    }
    if ($Target.protocol -eq "tcp" -and $null -eq $Probe.result.tcp_connect_ms) {
        return $true
    }
    if ($Target.protocol -eq "icmp" -and $null -eq $Probe.result.icmp_ms) {
        return $true
    }
    return $false
}

function Test-TargetHasRunnableProbe($Target) {
    if ($Target.protocol -eq "udp") {
        return $false
    }
    return $true
}

function Get-TargetKey($Target) {
    "$($Target.protocol)|$($Target.value)|$($Target.port)|$(if ($Target.path) { $Target.path } else { '/' })"
}

function Get-ProfileTargetKeyMap($PolicyProfile) {
    $map = @{}
    foreach ($target in @($PolicyProfile.targets)) {
        $map[(Get-TargetKey $target)] = $true
    }
    return $map
}

function Get-RedirectTargetWarning($PolicyProfile, $Target, $Observation) {
    if (-not $Observation -or [string]$Target.protocol -notin @("http", "https") -or [string]::IsNullOrWhiteSpace([string]$Observation.http_final_url)) {
        return $null
    }
    try {
        $uri = [System.Uri]::new([string]$Observation.http_final_url)
    } catch {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($uri.Host) -or $uri.Host -eq [string]$Target.value) {
        return $null
    }
    $protocol = $uri.Scheme.ToLowerInvariant()
    if ($protocol -notin @("http", "https")) {
        return $null
    }
    $port = if ($uri.IsDefaultPort) {
        if ($protocol -eq "https") { 443 } else { 80 }
    } else {
        [int]$uri.Port
    }
    $key = "$protocol|$($uri.Host)|$port|/"
    $profileTargets = Get-ProfileTargetKeyMap $PolicyProfile
    if ($profileTargets.ContainsKey($key)) {
        return $null
    }
    return "redirect target is not covered: $($uri.Host):$port"
}

function New-RetryObservation($Attempt, $Probe, $Reason) {
    [pscustomobject]@{
        attempt = $Attempt
        reason = $Reason
        error = if ($Probe.ok) { $null } else { $Probe.error }
        http_status = if ($Probe.ok -and $Probe.result) { $Probe.result.http_status } else { $null }
        icmp_ms = if ($Probe.ok -and $Probe.result) { $Probe.result.icmp_ms } else { $null }
        errors = if ($Probe.ok -and $Probe.result) { $Probe.result.errors } else { $null }
    }
}

function Invoke-TargetProbeWithRetries($KeyFile, $Remote, $Target, $Label) {
    $command = New-TargetProbeCommand $Target
    $retryErrors = New-Object System.Collections.ArrayList
    $lastProbe = $null

    for ($attempt = 1; $attempt -le $ProbeAttempts; $attempt += 1) {
        $lastProbe = Invoke-SshJsonProbe $KeyFile $Remote $command "$Label attempt $attempt/$ProbeAttempts"
        $shouldRetry = Test-TargetProbeShouldRetry $lastProbe $Target
        if (-not $shouldRetry -or $attempt -eq $ProbeAttempts) {
            if ($shouldRetry) {
                [void]$retryErrors.Add((New-RetryObservation $attempt $lastProbe "retry_exhausted"))
            }
            break
        }

        $reason = if (-not $lastProbe.ok) {
            "probe_error"
        } elseif ($Target.protocol -in @("https", "http") -and $null -eq $lastProbe.result.http_status) {
            "empty_http_status"
        } else {
            "incomplete_probe"
        }
        [void]$retryErrors.Add((New-RetryObservation $attempt $lastProbe $reason))
        if ($ProbeRetryDelaySeconds -gt 0) {
            Start-Sleep -Seconds $ProbeRetryDelaySeconds
        }
    }

    $lastProbe | Add-Member -NotePropertyName attempts_used -NotePropertyValue $attempt -Force
    $lastProbe | Add-Member -NotePropertyName attempts_total -NotePropertyValue $ProbeAttempts -Force
    $lastProbe | Add-Member -NotePropertyName retry_errors -NotePropertyValue @($retryErrors.ToArray()) -Force
    return $lastProbe
}

function Test-CascadeRecordUsable($Record) {
    if (-not $Record -or $Record.status -eq "probe_error") {
        return $false
    }
    $transportOk = $Record.cascade_transport_status -and $Record.cascade_transport_status.reachable
    $connectionOk = $Record.cascade_connection_status -and $Record.cascade_connection_status.online
    if (-not $transportOk -and -not $connectionOk) {
        return $false
    }
    if ($Record.target.protocol -eq "tcp") {
        if (-not $Record.target_status -or $null -eq $Record.target_status.tcp_connect_ms) {
            return $false
        }
    } elseif ($Record.target.protocol -eq "icmp") {
        if (-not $Record.target_status -or $null -eq $Record.target_status.icmp_ms) {
            return $false
        }
    } elseif ($Record.target.protocol -eq "udp") {
        return $false
    } else {
        $httpStatus = if ($Record.target_status) { $Record.target_status.http_status } else { $null }
        if ($null -eq $httpStatus -or $httpStatus -lt 200 -or $httpStatus -ge 400) {
            return $false
        }
    }
    if ($Record.behavior -eq "require_non_ru_egress" -and $Record.effective_country -eq "RU") {
        return $false
    }
    return $true
}

function Test-DirectRecordUsable($Record) {
    if (-not $Record -or $Record.status -eq "probe_error") {
        return $false
    }
    if ($Record.target.protocol -eq "tcp") {
        if (-not $Record.target_status -or $null -eq $Record.target_status.tcp_connect_ms) {
            return $false
        }
    } elseif ($Record.target.protocol -eq "icmp") {
        if (-not $Record.target_status -or $null -eq $Record.target_status.icmp_ms) {
            return $false
        }
    } elseif ($Record.target.protocol -eq "udp") {
        return $false
    } else {
        $httpStatus = if ($Record.target_status) { $Record.target_status.http_status } else { $null }
        if ($null -eq $httpStatus -or $httpStatus -lt 200 -or $httpStatus -ge 400) {
            return $false
        }
    }
    if ($Record.behavior -eq "require_non_ru_egress" -and $Record.effective_country -eq "RU") {
        return $false
    }
    return $true
}

function Invoke-DirectEgressProbe($PolicyProfile, $Target, $CandidateAlias, $ModeLabel) {
    $node = $nodes[$CandidateAlias]
    if ($node.connection -ne "ssh" -or $node.endpoint -eq "local") {
        Fail "probe alias $CandidateAlias must use connection=ssh and a real endpoint"
    }
    $keyFile = Resolve-ProbePath (Join-Path (Join-Path $OperatorDir $CandidateAlias) "admin_key") "admin key for $CandidateAlias"
    $remote = "${SshUser}@$($node.endpoint)"

    if ($DryRun) {
        Write-Host "    [dry-run] $ModeLabel $CandidateAlias via $remote"
        return $null
    }

    if (-not (Test-TargetHasRunnableProbe $Target)) {
        Write-Host "    route-review $ModeLabel $CandidateAlias for $($Target.protocol)/$($Target.port): no generic UDP probe"
        return [pscustomobject]([ordered]@{
            schema_version = 1
            run_id = $runId
            observed_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            path_mode = "direct"
            profile = $PolicyProfile.name
            behavior = Get-PolicyBehavior $PolicyProfile
            candidate_alias = $CandidateAlias
            ingress_alias = $CandidateAlias
            egress_alias = $CandidateAlias
            cascade_connection = $null
            cascade_path = @()
            cascade_transport_status = $null
            cascade_connection_status = $null
            endpoint = $node.endpoint
            target = $Target
            status = "route_review"
            observation = $null
            target_status = $null
            effective_country = $null
            effective_ip = $null
            attempts_used = 0
            attempts_total = 0
            retry_errors = @()
            error = "Generic UDP probe is not deterministic; add a protocol-specific probe block before auto-accept."
            raw = $null
        })
    }

    Write-Host "    probing $ModeLabel $CandidateAlias..."
    $probe = Invoke-TargetProbeWithRetries $keyFile $remote $Target "egress probe $($PolicyProfile.name)/$CandidateAlias/$($Target.value)"

    $record = [ordered]@{
        schema_version = 1
        run_id = $runId
        observed_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        path_mode = "direct"
        profile = $PolicyProfile.name
        behavior = Get-PolicyBehavior $PolicyProfile
        candidate_alias = $CandidateAlias
        ingress_alias = $CandidateAlias
        egress_alias = $CandidateAlias
        cascade_connection = $null
        cascade_transport_status = $null
        cascade_connection_status = $null
        endpoint = $node.endpoint
        target = $Target
        status = if ($probe.ok) { "observed" } else { "probe_error" }
        observation = if ($probe.ok) { $probe.result } else { $null }
        target_status = if ($probe.ok) { $probe.result } else { $null }
        effective_country = if ($probe.ok) { $probe.result.external_country } else { $null }
        effective_ip = if ($probe.ok) { $probe.result.external_ip } else { $null }
        attempts_used = $probe.attempts_used
        attempts_total = $probe.attempts_total
        retry_errors = $probe.retry_errors
        error = if ($probe.ok) { $null } else { $probe.error }
        raw = if ($probe.ok) { $null } else { $probe.raw }
    }

    if ($probe.ok) {
        $country = $probe.result.external_country
        $ip = $probe.result.external_ip
        $http = $probe.result.http_status
        Write-Host "      observed ip=$ip country=$country http=$http attempts=$($probe.attempts_used)/$($probe.attempts_total)"
        $redirectWarning = Get-RedirectTargetWarning $PolicyProfile $Target $probe.result
        if ($redirectWarning) {
            Write-Host "      [WARN] $redirectWarning"
        }
    } else {
        Write-Host "      probe failed after $($probe.attempts_used)/$($probe.attempts_total) attempts: $($probe.error)"
    }

    return [pscustomobject]$record
}

function Invoke-CascadeEgressProbe($PolicyProfile, $Target, $PathLinks) {
    $links = @($PathLinks)
    if ($links.Count -eq 0) {
        return $null
    }

    $ingressAlias = [string]$links[0].ingress_alias
    $egressAlias = [string]$links[$links.Count - 1].egress_alias
    if ($aliasFilter.Count -gt 0 -and $aliasFilter -notcontains $ingressAlias -and $aliasFilter -notcontains $egressAlias) {
        return $null
    }

    $ingressNode = $nodes[$ingressAlias]
    $egressNode = $nodes[$egressAlias]
    $pathAliases = @($links | ForEach-Object { $_.ingress_alias; $_.egress_alias } | Select-Object -Unique)
    foreach ($aliasName in $pathAliases) {
        $node = $nodes[$aliasName]
        if (-not $node) {
            Fail "cascade probe path references unknown alias: $aliasName"
        }
        if ($node.connection -ne "ssh" -or $node.endpoint -eq "local") {
            Fail "cascade probe alias $aliasName must use connection=ssh and a real endpoint"
        }
        [void](Resolve-ProbePath (Join-Path (Join-Path $OperatorDir $aliasName) "admin_key") "admin key for $aliasName")
    }

    $ingressKey = Resolve-ProbePath (Join-Path (Join-Path $OperatorDir $ingressAlias) "admin_key") "admin key for $ingressAlias"
    $egressKey = Resolve-ProbePath (Join-Path (Join-Path $OperatorDir $egressAlias) "admin_key") "admin key for $egressAlias"
    $ingressRemote = "${SshUser}@$($ingressNode.endpoint)"
    $egressRemote = "${SshUser}@$($egressNode.endpoint)"
    $cascadeLabel = Get-CascadePathLabel $links
    $connectionNames = @($links | ForEach-Object { [string]$_.connection_name })

    if ($DryRun) {
        Write-Host "    [dry-run] cascade $cascadeLabel via $($connectionNames -join ',')"
        return $null
    }

    Write-Host "    probing cascade $cascadeLabel via $($connectionNames -join ',')..."

    $transportHops = New-Object System.Collections.ArrayList
    $connectionHops = New-Object System.Collections.ArrayList
    foreach ($link in $links) {
        $linkIngressNode = $nodes[$link.ingress_alias]
        $linkIngressKey = Resolve-ProbePath (Join-Path (Join-Path $OperatorDir $link.ingress_alias) "admin_key") "admin key for $($link.ingress_alias)"
        $linkIngressRemote = "${SshUser}@$($linkIngressNode.endpoint)"
        $linkLabel = "$($link.ingress_alias)->$($link.egress_alias):$($link.egress_port)"

        $tcpScriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($remoteTcpCheckPython))
        $tcpCommand = "python3 -c $(Quote-BashArg "import base64,sys; exec(base64.b64decode('$tcpScriptB64'))") $(Quote-BashArg $link.egress_host) $(Quote-BashArg ([string]$link.egress_port)) $(Quote-BashArg ([string]$TimeoutSeconds))"
        Write-Host "      checking cascade transport $linkLabel..."
        $transportProbe = Invoke-SshJsonProbe $linkIngressKey $linkIngressRemote $tcpCommand "cascade transport probe $linkLabel"
        $transportStatus = if ($transportProbe.ok) { $transportProbe.result } else { [pscustomobject]@{ reachable = $false; error = $transportProbe.error; raw = $transportProbe.raw } }
        if ($transportStatus.reachable) {
            Write-Host "        [OK] transport reachable"
        } else {
            $transportPreview = Get-RawOutputPreview ($transportStatus.error)
            Write-Host "        [WARN] transport unreachable: $transportPreview"
        }
        [void]$transportHops.Add([pscustomobject]@{
            connection = [string]$link.connection_name
            ingress_alias = [string]$link.ingress_alias
            egress_alias = [string]$link.egress_alias
            endpoint = "$($link.egress_host):$($link.egress_port)"
            reachable = [bool]$transportStatus.reachable
            tcp_connect_ms = $transportStatus.tcp_connect_ms
            error = $transportStatus.error
        })

        $dockerStatusScript = 'in_file="/tmp/ai-sp-cascade-status.$$"; cat > "$in_file"; vpncmd localhost:5555 /SERVER /PASSWORD:"$SERVER_PASSWORD" /IN:"$in_file"; rc=$?; rm -f "$in_file"; exit "$rc"'
        $remoteStatusTimeout = [Math]::Max(1, $TimeoutSeconds + 5)
        $statusCommand = @(
            "set -euo pipefail",
            "tmp_file=`$(mktemp)",
            "trap 'rm -f ""`$tmp_file""' EXIT",
            "printf 'Hub %s\nCascadeStatusGet %s\n' $(Quote-BashArg $link.hub_name) $(Quote-BashArg $link.connection_name) > ""`$tmp_file""",
            "timeout $(Quote-BashArg ([string]$remoteStatusTimeout))s sudo docker exec -i -e SERVER_PASSWORD=$(Quote-BashArg $link.server_password) softether-cascade sh -c $(Quote-BashArg $dockerStatusScript) < ""`$tmp_file"""
        ) -join "`n"
        Write-Host "      checking cascade status $($link.connection_name)..."
        $statusProbe = Invoke-SshTextCommand $linkIngressKey $linkIngressRemote $statusCommand "cascade status probe $($link.connection_name)"
        $statusOutput = [string]$statusProbe.output
        $statusOnline = $statusProbe.ok -and ($statusOutput -match "Connection Completed|Session Established|Online|Connected")
        if ($statusOnline) {
            Write-Host "        [OK] cascade status online"
        } else {
            Write-Host "        [FAIL] cascade status is not online: $(Get-RawOutputPreview $statusOutput)"
        }
        [void]$connectionHops.Add([pscustomobject]@{
            connection = [string]$link.connection_name
            ingress_alias = [string]$link.ingress_alias
            egress_alias = [string]$link.egress_alias
            online = [bool]$statusOnline
            exit_code = $statusProbe.exit_code
            output_excerpt = if ($statusOutput.Length -gt 1200) { $statusOutput.Substring(0, 1200) } else { $statusOutput }
        })
    }

    $transportOk = @($transportHops.ToArray() | Where-Object { -not $_.reachable }).Count -eq 0
    $statusOnline = @($connectionHops.ToArray() | Where-Object { -not $_.online }).Count -eq 0

    if (-not (Test-TargetHasRunnableProbe $Target)) {
        Write-Host "      cascade tcp=$transportOk status_online=$statusOnline target=$($Target.protocol)/$($Target.port) route_review"
        return [pscustomobject]([ordered]@{
            schema_version = 1
            run_id = $runId
            observed_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            path_mode = "cascade"
            profile = $PolicyProfile.name
            behavior = Get-PolicyBehavior $PolicyProfile
            candidate_alias = $egressAlias
            ingress_alias = $ingressAlias
            egress_alias = $egressAlias
            cascade_connection = ($connectionNames -join "->")
            cascade_connections = $connectionNames
            cascade_path = @($links | ForEach-Object { [pscustomobject]@{ connection = $_.connection_name; ingress_alias = $_.ingress_alias; egress_alias = $_.egress_alias } })
            cascade_link_state = ($links | ForEach-Object { $_.state } | Select-Object -Unique) -join ","
            cascade_transport_status = [pscustomobject]@{ reachable = $transportOk; hops = @($transportHops.ToArray()) }
            cascade_connection_status = [pscustomobject]@{ online = $statusOnline; hops = @($connectionHops.ToArray()) }
            endpoint = $egressNode.endpoint
            target = $Target
            status = "route_review"
            observation = $null
            target_status = $null
            effective_country = $null
            effective_ip = $null
            attempts_used = 0
            attempts_total = 0
            retry_errors = @()
            error = "Generic UDP probe is not deterministic; add a protocol-specific probe block before auto-accept."
            raw = $null
        })
    }

    $targetProbe = Invoke-TargetProbeWithRetries $egressKey $egressRemote $Target "cascade target probe $egressAlias/$($Target.value)"

    $record = [ordered]@{
        schema_version = 1
        run_id = $runId
        observed_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        path_mode = "cascade"
        profile = $PolicyProfile.name
        behavior = Get-PolicyBehavior $PolicyProfile
        candidate_alias = $egressAlias
        ingress_alias = $ingressAlias
        egress_alias = $egressAlias
        cascade_connection = ($connectionNames -join "->")
        cascade_connections = $connectionNames
        cascade_path = @($links | ForEach-Object { [pscustomobject]@{ connection = $_.connection_name; ingress_alias = $_.ingress_alias; egress_alias = $_.egress_alias } })
        cascade_link_state = ($links | ForEach-Object { $_.state } | Select-Object -Unique) -join ","
        cascade_transport_status = [pscustomobject]@{ reachable = $transportOk; hops = @($transportHops.ToArray()) }
        cascade_connection_status = [pscustomobject]@{ online = $statusOnline; hops = @($connectionHops.ToArray()) }
        endpoint = $egressNode.endpoint
        target = $Target
        status = if ($targetProbe.ok) { "observed" } else { "probe_error" }
        observation = if ($targetProbe.ok) { $targetProbe.result } else { $null }
        target_status = if ($targetProbe.ok) { $targetProbe.result } else { $null }
        effective_country = if ($targetProbe.ok) { $targetProbe.result.external_country } else { $null }
        effective_ip = if ($targetProbe.ok) { $targetProbe.result.external_ip } else { $null }
        attempts_used = $targetProbe.attempts_used
        attempts_total = $targetProbe.attempts_total
        retry_errors = $targetProbe.retry_errors
        error = if ($targetProbe.ok) { $null } else { $targetProbe.error }
        raw = if ($targetProbe.ok) { $null } else { $targetProbe.raw }
    }

    $country = if ($targetProbe.ok) { $targetProbe.result.external_country } else { $null }
    $ip = if ($targetProbe.ok) { $targetProbe.result.external_ip } else { $null }
    $http = if ($targetProbe.ok) { $targetProbe.result.http_status } else { $null }
    $icmp = if ($targetProbe.ok) { $targetProbe.result.icmp_ms } else { $null }
    Write-Host "      cascade tcp=$transportOk status_online=$statusOnline ip=$ip country=$country http=$http icmp_ms=$icmp attempts=$($targetProbe.attempts_used)/$($targetProbe.attempts_total)"
    if ($targetProbe.ok) {
        $redirectWarning = Get-RedirectTargetWarning $PolicyProfile $Target $targetProbe.result
        if ($redirectWarning) {
            Write-Host "      [WARN] $redirectWarning"
        }
    }

    return [pscustomobject]$record
}

if ($DryRun) {
    $script:SshExecutablePath = $SshPath
} else {
    $script:SshExecutablePath = Resolve-SshExecutable $SshPath
    Write-Host "SSH executable: $script:SshExecutablePath"
}

Require-File $PolicyFile "egress policy registry"
$nodes = Load-Nodes $NodesFile
$policy = Read-JsonFile $PolicyFile "egress policy registry"
Validate-Policy $policy $nodes
$cascadeLinks = @()
if ($IncludeCascade -or $CascadeOnly -or $PreferCascade) {
    $cascadeLinks = @(Load-CascadeLinks $CascadeSecretDir $nodes)
    foreach ($profile in @($policy.profiles)) {
        foreach ($egressAlias in @(Get-PolicyFallbackEgressAliases $profile)) {
            if (-not $nodes.ContainsKey($egressAlias)) {
                Fail "egress profile $($profile.name) references unknown candidate fallback egress alias: $egressAlias"
            }
        }
    }
}

$profileFilter = @($ProfileName | Where-Object { $_ })
$aliasFilter = @($Alias | Where-Object { $_ })
$profiles = @($policy.profiles | Where-Object {
    ($profileFilter.Count -eq 0 -or $profileFilter -contains $_.name) -and $_.state -eq "probe"
})

if ($profileFilter.Count -gt 0) {
    foreach ($name in $profileFilter) {
        if (-not (@($policy.profiles | ForEach-Object { $_.name }) -contains $name)) {
            Fail "unknown egress profile requested: $name"
        }
    }
}

if ($profiles.Count -eq 0) {
    Write-Host "No enabled egress policy profiles selected."
    exit 0
}

foreach ($aliasName in $aliasFilter) {
    if (-not $nodes.ContainsKey($aliasName)) {
        Fail "unknown alias requested: $aliasName"
    }
}

$runId = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$records = New-Object System.Collections.ArrayList

Write-Host "Egress policy probe registry: $PolicyFile"
Write-Host "Run id: $runId"
Write-Host "Probe attempts: $ProbeAttempts; retry delay: ${ProbeRetryDelaySeconds}s"
if ($IncludeCascade -or $CascadeOnly -or $PreferCascade) {
    Write-Host "Cascade probe links: $($cascadeLinks.Count)"
}
foreach ($policyProfile in $profiles) {
    $profileIngressAliases = @(Get-PolicyIngressAliases $policyProfile)
    $profileFallbackEgressAliases = @(Get-PolicyFallbackEgressAliases $policyProfile)
    $candidateAliases = @($profileIngressAliases | Where-Object {
        $aliasFilter.Count -eq 0 -or $aliasFilter -contains $_
    })
    if ($candidateAliases.Count -eq 0) {
        Write-Host "Profile $($policyProfile.name): no aliases selected after filter"
        continue
    }
    Write-Host "Profile $($policyProfile.name): $($candidateAliases -join ', ')"
    foreach ($target in @($policyProfile.targets)) {
        Write-Host "  Target $($target.protocol)://$($target.value):$($target.port)"
        $eligibleCascadePaths = New-Object System.Collections.ArrayList
        foreach ($ingressAlias in $profileIngressAliases) {
            foreach ($egressAlias in $profileFallbackEgressAliases) {
                $path = @(Find-CascadePath $cascadeLinks $ingressAlias $egressAlias)
                if ($path.Count -eq 0) {
                    continue
                }
                if ($aliasFilter.Count -gt 0 -and $aliasFilter -notcontains $ingressAlias -and $aliasFilter -notcontains $egressAlias) {
                    continue
                }
                [void]$eligibleCascadePaths.Add($path)
            }
        }

        $directGoodCount = 0
        $cascadeUsableCount = 0
        $shouldRunDirectFirst = -not $CascadeOnly

        if ($shouldRunDirectFirst) {
            $directLabel = if ($PreferCascade) { "ingress-local" } else { "direct" }
            foreach ($candidateAlias in $candidateAliases) {
                $record = Invoke-DirectEgressProbe $policyProfile $target $candidateAlias $directLabel
                if ($record) {
                    [void]$records.Add($record)
                    if (Test-DirectRecordUsable $record) {
                        $directGoodCount += 1
                    }
                }
            }
        }

        $shouldRunCascade = $IncludeCascade -or $CascadeOnly -or ($PreferCascade -and $directGoodCount -eq 0)
        if ($DryRun -and $PreferCascade -and -not $CascadeOnly) {
            Write-Host "    [dry-run] cascade fallback would run only if ingress-local probes fail or degrade"
        }
        if ($PreferCascade -and -not $DryRun -and $directGoodCount -eq 0 -and -not $CascadeOnly) {
            Write-Host "    No good ingress-local path found; running cascade fallback probes"
        }
        if ($PreferCascade -and -not $DryRun -and $directGoodCount -gt 0 -and -not $IncludeCascade) {
            Write-Host "    Ingress-local path is good; cascade fallback probe skipped"
        }

        if ($shouldRunCascade) {
            foreach ($path in @($eligibleCascadePaths.ToArray())) {
                $record = Invoke-CascadeEgressProbe $policyProfile $target $path
                if ($record) {
                    [void]$records.Add($record)
                    if (Test-CascadeRecordUsable $record) {
                        $cascadeUsableCount += 1
                    }
                }
            }
        }
    }
}

if ($DryRun) {
    Write-Host "Dry-run completed. No probes were executed and no history file was written."
    exit 0
}

if ($records.Count -eq 0) {
    Write-Host "No probe records produced."
    exit 0
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$outputPath = Join-Path $OutputDir "egress-probes-$runId.jsonl"
foreach ($record in $records) {
    $record | ConvertTo-Json -Depth 20 -Compress | Add-Content -LiteralPath $outputPath -Encoding utf8
}

Write-Host "[OK] Egress probe history written: $outputPath"
