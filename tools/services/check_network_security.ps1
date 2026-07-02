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
$ExpectedNodesHeader = "current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
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
    return @($Value -split "[,:\+\s]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
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
    $isScriptInput = $Command -match "[`r`n]"
    $remoteCommand = $Command
    if ($isScriptInput) {
        $scriptText = ([string]$Command) -replace "`r`n", "`n" -replace "`r", "`n"
        $encodedScript = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($scriptText))
        $remoteCommand = "printf '%s' '$encodedScript' | base64 -d | bash"
    }
    $args = @(
        "-T",
        "-i", $keyFile,
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "IdentitiesOnly=yes",
        "-o", "RequestTTY=no",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "PasswordAuthentication=no",
        "-o", "PreferredAuthentications=publickey"
    )
    $args = @("-n") + $args
    $args += @("$SshUser@$($node.endpoint)")
    $args += $remoteCommand
    if ($AutoAcceptHostKey) {
        $args = @(
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
            "$SshUser@$($node.endpoint)"
        )
        $args = @("-n") + $args
        $args += $remoteCommand
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
$edgeBanlistAliases = New-Object System.Collections.Generic.List[string]
foreach ($row in $stateRows) {
    if ($row.kind -eq "service" -and $row.name -eq "edge_haproxy" -and $row.state -eq "present") {
        foreach ($alias in (Split-AliasList $row.active_aliases)) {
            if ($edgeAliases -notcontains $alias) {
                [void]$edgeAliases.Add($alias)
            }
        }
    }
    if ($row.kind -eq "service" -and $row.name -eq "edge_banlist" -and $row.state -eq "present") {
        foreach ($alias in (Split-AliasList $row.active_aliases)) {
            if ($edgeBanlistAliases -notcontains $alias) {
                [void]$edgeBanlistAliases.Add($alias)
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
prefix="__AI_SP_CHECK__"
out_file="/tmp/ai-sp-netcheck.out"
one_line_file() {
  tr '\r\n|' '   ' < "$out_file" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}
check_cmd() {
  name="$1"
  command_text="$2"
  if sh -c "$command_text" >"$out_file" 2>&1; then
    printf '%s|OK|%s|%s\n' "$prefix" "$name" "$(one_line_file)"
  else
    rc="$?"
    printf '%s|FAIL|%s|rc=%s %s\n' "$prefix" "$name" "$rc" "$(one_line_file)"
    failures=$((failures + 1))
  fi
  rm -f "$out_file"
}
check_text() {
  name="$1"
  pattern="$2"
  file="$3"
  if sudo -n grep -Eq "$pattern" "$file" >"$out_file" 2>&1; then
    printf '%s|OK|%s|matched\n' "$prefix" "$name"
  else
    printf '%s|FAIL|%s|missing pattern: %s\n' "$prefix" "$name" "$pattern"
    failures=$((failures + 1))
  fi
  rm -f "$out_file"
}
check_no_text() {
  name="$1"
  pattern="$2"
  file="$3"
  if sudo -n grep -Eq "$pattern" "$file" >"$out_file" 2>&1; then
    printf '%s|FAIL|%s|unexpected pattern: %s\n' "$prefix" "$name" "$pattern"
    failures=$((failures + 1))
  else
    printf '%s|OK|%s|absent\n' "$prefix" "$name"
  fi
  rm -f "$out_file"
}
cfg=/opt/ai-service-platform/edge_haproxy/haproxy/haproxy.cfg
check_cmd haproxy_config 'sudo -n docker exec edge-haproxy haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg'
check_text has_http_stick_table 'backend[[:space:]]+st_http_rates' "$cfg"
check_text has_scanner_acl 'acl[[:space:]]+is_scanner_path[[:space:]]+path_beg' "$cfg"
check_text has_blocked_ips 'blocked_ips\.lst' "$cfg"
check_text has_generated_blocked_ips 'generated_blocked_ips\.lst' "$cfg"
check_text has_vpn_mgmt_allowlist 'vpn_mgmt_ips\.lst' "$cfg"
check_text mgmt_allowlist_only 'tcp-request[[:space:]]+connection[[:space:]]+silent-drop[[:space:]]+if[[:space:]]+!\{[[:space:]]+src[[:space:]]+-f[[:space:]]+/usr/local/etc/haproxy/lists/vpn_mgmt_ips\.lst[[:space:]]+\}' "$cfg"
check_no_text no_cascade_surface 'cascade-vps|is_cascade|be_cascade' "$cfg"
check_cmd ufw_active 'sudo -n ufw status | grep -qi "^Status: active"'
for port in 22 80 443 992 5555 25565 25575; do
  check_cmd "ufw_allow_tcp_$port" "sudo -n ufw status numbered | grep -Eq '(^|[^0-9])$port/tcp[[:space:]]+ALLOW'"
done
for port in 8443 8555 8992; do
  check_cmd "ufw_no_retired_tcp_$port" "command -v ufw >/dev/null && ! sudo -n ufw status numbered | grep -Eq '(^|[^0-9])$port/tcp[[:space:]]+ALLOW'"
done
check_cmd fail2ban_active 'sudo -n systemctl is-active --quiet fail2ban'
check_cmd fail2ban_sshd_jail 'sudo -n fail2ban-client status sshd >/dev/null'
scanner_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/.env 2>"$out_file" || true)"
if [ "$scanner_code" = "403" ]; then
  printf '%s|OK|http_scanner_probe|status=%s\n' "$prefix" "$scanner_code"
else
  printf '%s|FAIL|http_scanner_probe|status=%s %s\n' "$prefix" "$scanner_code" "$(one_line_file)"
  failures=$((failures + 1))
fi
rm -f "$out_file"
acme_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/.well-known/acme-challenge/ai-sp-network-check 2>"$out_file" || true)"
if [ "$acme_code" = "301" ] || [ "$acme_code" = "302" ] || [ "$acme_code" = "404" ]; then
  printf '%s|OK|http_acme_probe|status=%s\n' "$prefix" "$acme_code"
else
  printf '%s|FAIL|http_acme_probe|status=%s %s\n' "$prefix" "$acme_code" "$(one_line_file)"
  failures=$((failures + 1))
fi
rm -f "$out_file"
exit "$failures"
'@

foreach ($alias in $edgeAliases) {
    Write-Host "Checking network security on $alias..."
    $result = Invoke-SshText $alias $remoteScript
    foreach ($line in $result.Output) {
        if ($line -match "^__AI_SP_CHECK__\|(OK|FAIL)\|([^|]+)\|(.*)$") {
            Add-Check $alias $Matches[2] ($Matches[1] -eq "OK") $Matches[3]
        } elseif ($line -and $line -notmatch "^\s*$") {
            Write-Host "[$alias] $line"
        }
    }
    if ($result.ExitCode -ne 0) {
        Write-Warning "$alias reported $($result.ExitCode) failed network security checks"
    }
    if ($edgeBanlistAliases -contains $alias) {
        $timerResult = Invoke-SshText $alias "sudo -n systemctl is-active --quiet edge-banlist.timer && sudo -n test -s /etc/systemd/system/edge-banlist.service"
        Add-Check $alias "edge_banlist_timer_active" ($timerResult.ExitCode -eq 0) (($timerResult.Output -join " ") -replace "\s+", " ")
    }
}

if ($script:FailedChecks -ne 0) {
    Fail "Network security check failed: $script:FailedChecks failed check(s)."
}

Write-Host "Network security check completed successfully."
