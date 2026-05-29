param(
    [string]$PolicyFile = ".\operator\egress_policy\profiles.json",
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$OperatorDir = ".\operator",
    [string]$OutputDir = ".\operator\egress_policy\history",
    [string]$SshUser = "useradmin",
    [Alias("Profile")]
    [string[]]$ProfileName = @(),
    [string[]]$Alias = @(),
    [int]$TimeoutSeconds = 10,
    [switch]$DryRun,
    [switch]$AutoAcceptHostKey = $true
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,connection,root_password"

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
        $output = & ssh @sshArgs
        $exitCode = $LASTEXITCODE
    } finally {
        $script:ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        return [pscustomobject]@{
            ok = $false
            error = "$Label failed with exit code $exitCode"
            raw = @($output) -join "`n"
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
            error = "$Label returned non-JSON output"
            raw = $text
        }
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
    if (-not $Policy.profiles -or $Policy.profiles.Count -eq 0) {
        Fail "egress policy registry must contain at least one profile"
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
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            result["http_status"] = response.status
            result["http_final_url"] = response.geturl()
            response.read(1024)
    except urllib.error.HTTPError as exc:
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

Require-File $PolicyFile "egress policy registry"
$nodes = Load-Nodes $NodesFile
$policy = Read-JsonFile $PolicyFile "egress policy registry"
Validate-Policy $policy $nodes

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
foreach ($policyProfile in $profiles) {
    $candidateAliases = @($policyProfile.candidate_egress_aliases | Where-Object {
        $aliasFilter.Count -eq 0 -or $aliasFilter -contains $_
    })
    if ($candidateAliases.Count -eq 0) {
        Write-Host "Profile $($policyProfile.name): no aliases selected after filter"
        continue
    }
    Write-Host "Profile $($policyProfile.name): $($candidateAliases -join ', ')"
    foreach ($target in @($policyProfile.targets)) {
        Write-Host "  Target $($target.protocol)://$($target.value):$($target.port)"
        foreach ($candidateAlias in $candidateAliases) {
            $node = $nodes[$candidateAlias]
            if ($node.connection -ne "ssh" -or $node.endpoint -eq "local") {
                Fail "probe alias $candidateAlias must use connection=ssh and a real endpoint"
            }
            $keyFile = Join-Path (Join-Path $OperatorDir $candidateAlias) "admin_key"
            Require-File $keyFile "admin key for $candidateAlias"
            $remote = "${SshUser}@$($node.endpoint)"

            if ($DryRun) {
                Write-Host "    [dry-run] $candidateAlias via $remote"
                continue
            }

            $payload = @{
                timeout_seconds = $TimeoutSeconds
                target = @{
                    type = $target.type
                    value = $target.value
                    protocol = $target.protocol
                    port = [int]$target.port
                    path = if ($target.path) { $target.path } else { "/" }
                }
            } | ConvertTo-Json -Depth 8 -Compress
            $scriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($remotePython))
            $payloadB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload))
            $command = "python3 -c $(Quote-BashArg "import base64,sys; exec(base64.b64decode('$scriptB64'))") $(Quote-BashArg $payloadB64)"
            Write-Host "    probing $candidateAlias..."
            $probe = Invoke-SshJsonProbe $keyFile $remote $command "egress probe $($policyProfile.name)/$candidateAlias/$($target.value)"

            $record = [ordered]@{
                schema_version = 1
                run_id = $runId
                observed_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
                profile = $policyProfile.name
                desired_region_behavior = $policyProfile.desired_region_behavior
                candidate_alias = $candidateAlias
                endpoint = $node.endpoint
                target = $target
                status = if ($probe.ok) { "observed" } else { "probe_error" }
                observation = if ($probe.ok) { $probe.result } else { $null }
                error = if ($probe.ok) { $null } else { $probe.error }
                raw = if ($probe.ok) { $null } else { $probe.raw }
            }
            [void]$records.Add([pscustomobject]$record)

            if ($probe.ok) {
                $country = $probe.result.external_country
                $ip = $probe.result.external_ip
                $http = $probe.result.http_status
                Write-Host "      observed ip=$ip country=$country http=$http"
            } else {
                Write-Host "      probe failed: $($probe.error)"
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
