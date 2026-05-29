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
        if ([string]::IsNullOrWhiteSpace([string]$profile.desired_region_behavior)) {
            Fail "egress profile $($profile.name) must include desired_region_behavior"
        }
        if ($profile.desired_region_behavior -notin @("fallback_on_ingress_egress_failure", "avoid_ru_egress", "require_non_ru_egress")) {
            Fail "egress profile $($profile.name) desired_region_behavior must be one of: fallback_on_ingress_egress_failure, avoid_ru_egress, require_non_ru_egress"
        }
        if (-not $profile.targets -or $profile.targets.Count -eq 0) {
            Fail "egress profile $($profile.name) must include at least one target"
        }
        if (-not $profile.candidate_egress_aliases -or $profile.candidate_egress_aliases.Count -eq 0) {
            Fail "egress profile $($profile.name) must include candidate_egress_aliases"
        }

        $seenAliases = @{}
        foreach ($alias in @($profile.candidate_egress_aliases)) {
            if (-not $Nodes.ContainsKey($alias)) {
                Fail "egress profile $($profile.name) references unknown alias: $alias"
            }
            if ($seenAliases.ContainsKey($alias)) {
                Fail "egress profile $($profile.name) has duplicate candidate alias: $alias"
            }
            $seenAliases[$alias] = $true
        }

        foreach ($target in @($profile.targets)) {
            if ($target.type -notin @("domain", "ip")) {
                Fail "egress profile $($profile.name) target type must be domain or ip"
            }
            if ([string]::IsNullOrWhiteSpace([string]$target.value)) {
                Fail "egress profile $($profile.name) target value must not be empty"
            }
            if ($target.protocol -notin @("https", "http", "tcp")) {
                Fail "egress profile $($profile.name) target protocol must be https, http, or tcp"
            }
            $port = [int]$target.port
            if ($port -le 0 -or $port -gt 65535) {
                Fail "egress profile $($profile.name) target port must be in 1..65535"
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

$remotePython = @'
import base64
import datetime as dt
import json
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request

payload = json.loads(base64.b64decode(sys.argv[1]).decode("utf-8"))
target = payload["target"]
timeout = float(payload["timeout_seconds"])

host = target["value"]
port = int(target["port"])
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
    "external_ip": None,
    "external_country": None,
    "errors": [],
}

def record_error(stage, exc):
    result["errors"].append({"stage": stage, "message": str(exc)})

try:
    start = time.monotonic()
    infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
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

if infos:
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
    return $false
}

function New-RetryObservation($Attempt, $Probe, $Reason) {
    [pscustomobject]@{
        attempt = $Attempt
        reason = $Reason
        error = if ($Probe.ok) { $null } else { $Probe.error }
        http_status = if ($Probe.ok -and $Probe.result) { $Probe.result.http_status } else { $null }
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
    if (-not $Record.cascade_transport_status -or -not $Record.cascade_transport_status.reachable) {
        return $false
    }
    if (-not $Record.cascade_connection_status -or -not $Record.cascade_connection_status.online) {
        return $false
    }
    $httpStatus = if ($Record.target_status) { $Record.target_status.http_status } else { $null }
    if ($null -eq $httpStatus -or $httpStatus -lt 200 -or $httpStatus -ge 400) {
        return $false
    }
    if ($Record.desired_region_behavior -eq "require_non_ru_egress" -and $Record.effective_country -eq "RU") {
        return $false
    }
    return $true
}

function Invoke-DirectEgressProbe($PolicyProfile, $Target, $CandidateAlias, $ModeLabel) {
    $node = $nodes[$CandidateAlias]
    if ($node.connection -ne "ssh" -or $node.endpoint -eq "local") {
        Fail "probe alias $CandidateAlias must use connection=ssh and a real endpoint"
    }
    $keyFile = Join-Path (Join-Path $OperatorDir $CandidateAlias) "admin_key"
    Require-File $keyFile "admin key for $CandidateAlias"
    $remote = "${SshUser}@$($node.endpoint)"

    if ($DryRun) {
        Write-Host "    [dry-run] $ModeLabel $CandidateAlias via $remote"
        return $null
    }

    Write-Host "    probing $ModeLabel $CandidateAlias..."
    $probe = Invoke-TargetProbeWithRetries $keyFile $remote $Target "egress probe $($PolicyProfile.name)/$CandidateAlias/$($Target.value)"

    $record = [ordered]@{
        schema_version = 1
        run_id = $runId
        observed_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        path_mode = "direct"
        profile = $PolicyProfile.name
        desired_region_behavior = $PolicyProfile.desired_region_behavior
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
    } else {
        Write-Host "      probe failed after $($probe.attempts_used)/$($probe.attempts_total) attempts: $($probe.error)"
    }

    return [pscustomobject]$record
}

function Invoke-CascadeEgressProbe($PolicyProfile, $Target, $Link) {
    if ($aliasFilter.Count -gt 0 -and $aliasFilter -notcontains $Link.ingress_alias -and $aliasFilter -notcontains $Link.egress_alias) {
        return $null
    }

    $ingressNode = $nodes[$Link.ingress_alias]
    $egressNode = $nodes[$Link.egress_alias]
    foreach ($pair in @(@($Link.ingress_alias, $ingressNode), @($Link.egress_alias, $egressNode))) {
        if ($pair[1].connection -ne "ssh" -or $pair[1].endpoint -eq "local") {
            Fail "cascade probe alias $($pair[0]) must use connection=ssh and a real endpoint"
        }
        Require-File (Join-Path (Join-Path $OperatorDir $pair[0]) "admin_key") "admin key for $($pair[0])"
    }

    $ingressKey = Join-Path (Join-Path $OperatorDir $Link.ingress_alias) "admin_key"
    $egressKey = Join-Path (Join-Path $OperatorDir $Link.egress_alias) "admin_key"
    $ingressRemote = "${SshUser}@$($ingressNode.endpoint)"
    $egressRemote = "${SshUser}@$($egressNode.endpoint)"
    $cascadeLabel = "$($Link.ingress_alias)->$($Link.egress_alias):$($Link.egress_port)"

    if ($DryRun) {
        Write-Host "    [dry-run] cascade $cascadeLabel via $($Link.connection_name) state=$($Link.state)"
        return $null
    }

    Write-Host "    probing cascade $cascadeLabel state=$($Link.state)..."

    $tcpScriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($remoteTcpCheckPython))
    $tcpCommand = "python3 -c $(Quote-BashArg "import base64,sys; exec(base64.b64decode('$tcpScriptB64'))") $(Quote-BashArg $Link.egress_host) $(Quote-BashArg ([string]$Link.egress_port)) $(Quote-BashArg ([string]$TimeoutSeconds))"
    $transportProbe = Invoke-SshJsonProbe $ingressKey $ingressRemote $tcpCommand "cascade transport probe $cascadeLabel"

    $dockerStatusScript = 'in_file="/tmp/ai-sp-cascade-status.$$"; cat > "$in_file"; vpncmd localhost:5555 /SERVER /PASSWORD:"$SERVER_PASSWORD" /IN:"$in_file"; rc=$?; rm -f "$in_file"; exit "$rc"'
    $statusCommand = @(
        "tmp_file=`$(mktemp)",
        "trap 'rm -f ""`$tmp_file""' EXIT",
        "printf 'Hub %s\nCascadeStatusGet %s\n' $(Quote-BashArg $Link.hub_name) $(Quote-BashArg $Link.connection_name) > ""`$tmp_file""",
        "timeout $(Quote-BashArg ([string]$TimeoutSeconds))s sudo docker exec -i -e SERVER_PASSWORD=$(Quote-BashArg $Link.server_password) softether-cascade sh -c $(Quote-BashArg $dockerStatusScript) < ""`$tmp_file"""
    ) -join "; "
    $statusProbe = Invoke-SshTextCommand $ingressKey $ingressRemote $statusCommand "cascade status probe $($Link.connection_name)"
    $statusOutput = [string]$statusProbe.output
    $statusOnline = $statusProbe.ok -and ($statusOutput -match "Connection Completed|Session Established|Online|Connected")

    $targetProbe = Invoke-TargetProbeWithRetries $egressKey $egressRemote $Target "cascade target probe $($Link.egress_alias)/$($Target.value)"

    $transportStatus = if ($transportProbe.ok) { $transportProbe.result } else { [pscustomobject]@{ reachable = $false; error = $transportProbe.error; raw = $transportProbe.raw } }
    $connectionStatus = [pscustomobject]@{
        online = $statusOnline
        exit_code = $statusProbe.exit_code
        matched_online_text = $statusOnline
        output_excerpt = if ($statusOutput.Length -gt 1200) { $statusOutput.Substring(0, 1200) } else { $statusOutput }
    }

    $record = [ordered]@{
        schema_version = 1
        run_id = $runId
        observed_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        path_mode = "cascade"
        profile = $PolicyProfile.name
        desired_region_behavior = $PolicyProfile.desired_region_behavior
        candidate_alias = $Link.egress_alias
        ingress_alias = $Link.ingress_alias
        egress_alias = $Link.egress_alias
        cascade_connection = $Link.connection_name
        cascade_link_state = $Link.state
        cascade_transport_status = $transportStatus
        cascade_connection_status = $connectionStatus
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

    $transportOk = $transportProbe.ok -and $transportProbe.result.reachable
    $country = if ($targetProbe.ok) { $targetProbe.result.external_country } else { $null }
    $ip = if ($targetProbe.ok) { $targetProbe.result.external_ip } else { $null }
    $http = if ($targetProbe.ok) { $targetProbe.result.http_status } else { $null }
    Write-Host "      cascade tcp=$transportOk status_online=$statusOnline ip=$ip country=$country http=$http attempts=$($targetProbe.attempts_used)/$($targetProbe.attempts_total)"

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
    $profileCandidateAliases = @($policyProfile.candidate_egress_aliases)
    $candidateAliases = @($profileCandidateAliases | Where-Object {
        $aliasFilter.Count -eq 0 -or $aliasFilter -contains $_
    })
    if ($candidateAliases.Count -eq 0) {
        Write-Host "Profile $($policyProfile.name): no aliases selected after filter"
        continue
    }
    Write-Host "Profile $($policyProfile.name): $($candidateAliases -join ', ')"
    foreach ($target in @($policyProfile.targets)) {
        Write-Host "  Target $($target.protocol)://$($target.value):$($target.port)"
        $eligibleCascadeLinks = @($cascadeLinks | Where-Object {
            $profileCandidateAliases -contains $_.egress_alias -and (
                $aliasFilter.Count -eq 0 -or
                $aliasFilter -contains $_.ingress_alias -or
                $aliasFilter -contains $_.egress_alias
            )
        })

        $cascadeUsableCount = 0
        $shouldRunCascade = $IncludeCascade -or $CascadeOnly -or $PreferCascade
        $shouldRunDirectAudit = -not $CascadeOnly -and -not $PreferCascade

        if ($shouldRunCascade) {
            foreach ($link in $eligibleCascadeLinks) {
                $record = Invoke-CascadeEgressProbe $policyProfile $target $link
                if ($record) {
                    [void]$records.Add($record)
                    if (Test-CascadeRecordUsable $record) {
                        $cascadeUsableCount += 1
                    }
                }
            }

            if ($DryRun -and $PreferCascade) {
                Write-Host "    [dry-run] direct fallback would run only if no usable cascade path is found"
            }
        }

        if ($PreferCascade -and -not $DryRun -and $cascadeUsableCount -eq 0) {
            Write-Host "    No usable cascade path found; running direct fallback probes"
        }

        $shouldRunDirectFallback = $PreferCascade -and (-not $DryRun) -and $cascadeUsableCount -eq 0
        if ($shouldRunDirectAudit -or $shouldRunDirectFallback) {
            $directLabel = if ($shouldRunDirectFallback) { "direct fallback" } else { "direct" }
            foreach ($candidateAlias in $candidateAliases) {
                $record = Invoke-DirectEgressProbe $policyProfile $target $candidateAlias $directLabel
                if ($record) {
                    [void]$records.Add($record)
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
