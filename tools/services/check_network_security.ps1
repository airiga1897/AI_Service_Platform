param(
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$StateFile = ".\operator\state.csv",
    [string]$OperatorDir = ".\operator",
    [string]$KnownHostsFile = "",
    [string]$SshUser = "useradmin",
    [string]$SshKeyFile = "",
    [string]$Limit = "",
    [switch]$AutoAcceptHostKey = $true
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,connection,root_password"
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
    if (-not $Value) { return @() }
    return @($Value -split "\+" | Where-Object { $_ })
}

function Split-FilterList($Value) {
    if (-not $Value) { return @() }
    return @($Value -split "[,:+]" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Quote-BashArg($Value) {
    $text = [string]$Value
    return "'" + ($text -replace "'", "'\''") + "'"
}

function Resolve-OpenSshExecutable($Name) {
    $candidates = @(
        (Join-Path $env:WINDIR "System32\OpenSSH\$Name.exe"),
        (Join-Path $env:WINDIR "Sysnative\OpenSSH\$Name.exe")
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }
    $commands = @(Get-Command "$Name.exe" -ErrorAction SilentlyContinue)
    if ($commands.Count -gt 0) {
        return $commands[0].Source
    }
    Fail "$Name.exe not found. Install Windows OpenSSH Client or fix PATH."
}

function Resolve-OpenSshClient() {
    $sshPath = Resolve-OpenSshExecutable "ssh"
    $version = (& $env:ComSpec /d /c "`"$sshPath`" -V 2>&1" | ForEach-Object { [string]$_ }) -join "`n"
    if ($LASTEXITCODE -ne 0 -and -not $version) {
        Fail "Failed to run ssh -V at $sshPath"
    }
    if ($version -notmatch "OpenSSH") {
        Fail "Resolved ssh is not OpenSSH: $sshPath. Output:`n$version"
    }
    return $sshPath
}

function Invoke-SshText($Alias, $Command) {
    $node = $script:NodesByAlias[$Alias]
    if (-not $node) {
        Fail "Unknown alias: $Alias"
    }
    $keyFile = $SshKeyFile
    if (-not $keyFile) {
        $keyFile = Join-Path (Join-Path $OperatorDir $Alias) "admin_key"
    }
    Require-File $keyFile "SshKeyFile for $Alias"
    $args = @(
        "-n",
        "-T",
        "-i", $keyFile,
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "IdentitiesOnly=yes",
        "-o", "RequestTTY=no",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "PasswordAuthentication=no",
        "-o", "PreferredAuthentications=publickey",
        "$SshUser@$($node.endpoint)",
        $Command
    )
    if ($AutoAcceptHostKey) {
        $args = @(
            "-n",
            "-T",
            "-i", $keyFile,
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "IdentitiesOnly=yes",
            "-o", "RequestTTY=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "PasswordAuthentication=no",
            "-o", "PreferredAuthentications=publickey",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=$KnownHostsFile",
            "-o", "LogLevel=ERROR",
            "$SshUser@$($node.endpoint)",
            $Command
        )
    }
    $output = @(& $script:SshPath @args 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
        Text = ($output -join "`n")
    }
}

function Add-Check($Alias, $Name, $Passed, $Detail) {
    $status = if ($Passed) { "OK" } else { "FAIL" }
    Write-Host ("[{0}] {1} {2} - {3}" -f $status, $Alias, $Name, $Detail)
    if (-not $Passed) {
        $script:FailedChecks++
    }
}

function Test-RemoteRegex($Text, $Pattern) {
    return ([regex]::IsMatch($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))
}

Require-File $NodesFile "NodesFile"
Require-File $StateFile "StateFile"

if (-not $KnownHostsFile) {
    $KnownHostsFile = Join-Path ([System.IO.Path]::GetTempPath()) "ai-service-platform.known_hosts"
}

$nodesHeader = Get-Content -LiteralPath $NodesFile -TotalCount 1
if ($nodesHeader -ne $ExpectedNodesHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedNodesHeader"
}
$stateHeader = Get-Content -LiteralPath $StateFile -TotalCount 1
if ($stateHeader -ne $ExpectedStateHeader) {
    Fail "state.csv header must be exactly: $ExpectedStateHeader"
}

$nodes = @(Import-Csv -LiteralPath $NodesFile)
$stateRows = @(Import-Csv -LiteralPath $StateFile)
$script:NodesByAlias = @{}
foreach ($node in $nodes) {
    $script:NodesByAlias[$node.current_alias] = $node
}

$edgeAliases = New-Object System.Collections.Generic.List[string]
foreach ($row in $stateRows) {
    if ($row.kind -eq "service" -and $row.name -eq "edge_haproxy" -and $row.state -eq "present") {
        foreach ($alias in (Split-AliasList $row.active_aliases)) {
            if ($edgeAliases -notcontains $alias) {
                [void]$edgeAliases.Add($alias)
            }
        }
    }
}

$limitAliases = @(Split-FilterList $Limit)
if ($limitAliases.Count -gt 0) {
    $edgeAliases = @($edgeAliases | Where-Object { $limitAliases -contains $_ })
}
if ($edgeAliases.Count -eq 0) {
    Fail "No edge_haproxy aliases selected."
}

$script:SshPath = Resolve-OpenSshClient
$script:FailedChecks = 0

$remoteScript = @'
set -u
failures=0
one_line() {
  tr '\r\n|' '   ' < /tmp/ai-sp-netcheck.out | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}
check() {
  name="$1"
  shift
  if "$@" >/tmp/ai-sp-netcheck.out 2>&1; then
    printf 'OK|%s|%s\n' "$name" "$(one_line)"
  else
    rc="$?"
    printf 'FAIL|%s|rc=%s %s\n' "$name" "$rc" "$(one_line)"
    failures=$((failures + 1))
  fi
  rm -f /tmp/ai-sp-netcheck.out
}
check_text() {
  name="$1"
  pattern="$2"
  file="$3"
  if grep -Eq "$pattern" "$file" >/tmp/ai-sp-netcheck.out 2>&1; then
    printf 'OK|%s|matched\n' "$name"
  else
    printf 'FAIL|%s|missing pattern: %s\n' "$name" "$pattern"
    failures=$((failures + 1))
  fi
}
cfg=/opt/ai-service-platform/edge_haproxy/haproxy/haproxy.cfg
check haproxy_config sudo -n docker exec edge-haproxy haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg
check_text has_http_stick_table 'backend[[:space:]]+st_http_rates' "$cfg"
check_text has_scanner_acl 'acl[[:space:]]+is_scanner_path[[:space:]]+path_beg' "$cfg"
check_text has_blocked_ips 'blocked_ips\.lst' "$cfg"
check_text has_vpn_mgmt_allowlist 'vpn_mgmt_ips\.lst' "$cfg"
check_text mgmt_allowlist_only 'tcp-request[[:space:]]+connection[[:space:]]+reject[[:space:]]+if[[:space:]]+!\{[[:space:]]+src[[:space:]]+-f[[:space:]]+/usr/local/etc/haproxy/lists/vpn_mgmt_ips\.lst[[:space:]]+\}' "$cfg"
check ufw_active sh -c 'sudo -n ufw status | grep -qi "^Status: active"'
for port in 22 80 443 992 5555 8443 8555 8992 25565 25575; do
  check "ufw_allow_tcp_$port" sh -c "sudo -n ufw status numbered | grep -Eq '(^|[^0-9])$port/tcp[[:space:]]+ALLOW'"
done
scanner_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/.env 2>/tmp/ai-sp-netcheck.out || true)"
if [ "$scanner_code" = "403" ]; then
  printf 'OK|http_scanner_probe|status=%s\n' "$scanner_code"
else
  printf 'FAIL|http_scanner_probe|status=%s %s\n' "$scanner_code" "$(cat /tmp/ai-sp-netcheck.out)"
  failures=$((failures + 1))
fi
rm -f /tmp/ai-sp-netcheck.out
acme_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/.well-known/acme-challenge/ai-sp-network-check 2>/tmp/ai-sp-netcheck.out || true)"
if [ "$acme_code" = "301" ] || [ "$acme_code" = "302" ] || [ "$acme_code" = "404" ]; then
  printf 'OK|http_acme_probe|status=%s\n' "$acme_code"
else
  printf 'FAIL|http_acme_probe|status=%s %s\n' "$acme_code" "$(cat /tmp/ai-sp-netcheck.out)"
  failures=$((failures + 1))
fi
rm -f /tmp/ai-sp-netcheck.out
exit "$failures"
'@

foreach ($alias in $edgeAliases) {
    Write-Host "Checking network security on $alias..."
    $result = Invoke-SshText $alias $remoteScript
    foreach ($line in $result.Output) {
        if ($line -match "^(OK|FAIL)\|([^|]+)\|(.*)$") {
            Add-Check $alias $Matches[2] ($Matches[1] -eq "OK") $Matches[3]
        } elseif ($line) {
            Write-Host "[$alias] $line"
        }
    }
    if ($result.ExitCode -ne 0) {
        Write-Warning "$alias reported $($result.ExitCode) failed network security checks"
    }
}

if ($script:FailedChecks -ne 0) {
    Fail "Network security check failed: $script:FailedChecks failed check(s)."
}

Write-Host "Network security check completed successfully."
