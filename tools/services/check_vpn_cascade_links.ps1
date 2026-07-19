param(
    [string]$SecretFile = ".\operator\softether\cascade\secrets\lab-cascade.json",
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$StateFile = ".\operator\state.csv",
    [string]$OperatorDir = ".\operator",
    [string]$SshUser = "useradmin",
    [string]$SshPath = "ssh",
    [int]$TimeoutSeconds = 20,
    [switch]$OnlyActive,
    [switch]$Json,
    [switch]$SelfTest,
    [switch]$AutoAcceptHostKey = $true
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,expected_ip,connection,ssh_port,root_password"

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

function Test-PresentVpnCascadeState($Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    foreach ($row in @(Import-Csv -LiteralPath $Path)) {
        if ($row.kind -eq "service" -and $row.name -eq "vpn_cascade" -and $row.state -eq "present") {
            return $true
        }
        if ($row.kind -eq "cascade_topology" -and $row.state -eq "present") {
            return $true
        }
    }
    return $false
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

function Get-RawOutputPreview($Text) {
    $preview = (([string]$Text) -replace "`r", "\r" -replace "`n", "\n").Trim()
    if ($preview.Length -gt 240) {
        return $preview.Substring(0, 240) + "..."
    }
    return $preview
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

function Get-AdminKeyFile($Alias) {
    return (Join-Path (Join-Path $OperatorDir $Alias) "admin_key")
}

function Invoke-SshTextCommand($KeyFile, $Remote, $Command) {
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

function Get-CascadeStatusText($Output) {
    $text = [string]$Output
    if ($text -match "(?m)^\s*Session Status\s*\|\s*(.+?)\s*$") {
        return $Matches[1].Trim()
    }
    return ""
}

function Test-CascadeStatusOnline($StatusText) {
    return ([string]$StatusText -match "(Connection Completed|Session Established)")
}

function Test-CascadeGetOutput($Output, $ConnectionName) {
    $escapedName = [regex]::Escape([string]$ConnectionName)
    return ([string]$Output -match "(^|[^A-Za-z0-9_.-])${escapedName}([^A-Za-z0-9_.-]|$)")
}

function Get-TaggedInt($Output, $Tag) {
    $escapedTag = [regex]::Escape([string]$Tag)
    if ([string]$Output -match "${escapedTag}:(-?\d+)") {
        return [int]$Matches[1]
    }
    return $null
}

function Test-Link($Link, $Secret, $Nodes) {
    $ingressAlias = [string]$Link.ingress_alias
    $egressAlias = [string]$Link.egress_alias
    $connectionName = [string]$Link.connection_name
    $egressHost = [string]$Link.egress_host
    $egressPort = [int]$Link.egress_port
    $state = if ($Link.state) { [string]$Link.state } elseif ($Secret.state) { [string]$Secret.state } else { "active" }

    $result = [ordered]@{
        connection = $connectionName
        state = $state
        ingress = $ingressAlias
        egress = $egressAlias
        endpoint = "${egressHost}:${egressPort}"
        tcp = $false
        online = $false
        status = ""
        error = ""
    }

    if (-not $Nodes.ContainsKey($ingressAlias)) {
        $result.error = "unknown ingress alias: $ingressAlias"
        return [pscustomobject]$result
    }
    if (-not $Nodes.ContainsKey($egressAlias)) {
        $result.error = "unknown egress alias: $egressAlias"
        return [pscustomobject]$result
    }

    $keyFile = Get-AdminKeyFile $ingressAlias
    if (-not (Test-Path -LiteralPath $keyFile -PathType Leaf)) {
        $result.error = "admin key not found for ${ingressAlias}: $keyFile"
        return [pscustomobject]$result
    }

    $remote = "$SshUser@$($Nodes[$ingressAlias].endpoint)"
    $vpncmdScript = 'in_file="/tmp/ai-sp-cascade-status.$$"; cat > "$in_file"; vpncmd localhost:5555 /SERVER /PASSWORD:"$SERVER_PASSWORD" /IN:"$in_file"; rc=$?; rm -f "$in_file"; exit "$rc"'
    $commandLines = @(
        "set -uo pipefail",
        "timeout $(Quote-BashArg ([string]$TimeoutSeconds))s python3 -c $(Quote-BashArg 'import socket, sys; s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5); s.close()') $(Quote-BashArg $egressHost) $(Quote-BashArg ([string]$egressPort))",
        "tcp_rc=`$?",
        "if [ ""`$tcp_rc"" -ne 0 ]; then exit ""`$tcp_rc""; fi",
        "echo __AI_SP_TCP_OK__",
        "tmp_file=`$(mktemp)",
        "trap 'rm -f ""`$tmp_file""' EXIT",
        "printf 'Hub %s\nCascadeGet %s\n' $(Quote-BashArg $Secret.hub_name) $(Quote-BashArg $connectionName) > ""`$tmp_file""",
        "get_output=`$(timeout $(Quote-BashArg ([string]$TimeoutSeconds))s sudo docker exec -i -e SERVER_PASSWORD=$(Quote-BashArg $Secret.server_password) softether-cascade sh -c $(Quote-BashArg $vpncmdScript) < ""`$tmp_file"" 2>&1)",
        "get_rc=`$?",
        "echo __AI_SP_CASCADE_GET_RC__:`$get_rc",
        "printf '%s\n' ""`$get_output""",
        "if [ ""`$get_rc"" -ne 0 ]; then exit 29; fi",
        "if ! printf '%s\n' ""`$get_output"" | grep -Eq $(Quote-BashArg "(^|[^A-Za-z0-9_.-])${connectionName}([^A-Za-z0-9_.-]|$)"); then echo __AI_SP_CASCADE_MISSING__; exit 29; fi",
        "echo __AI_SP_CASCADE_GET_OK__",
        "printf 'Hub %s\nCascadeStatusGet %s\n' $(Quote-BashArg $Secret.hub_name) $(Quote-BashArg $connectionName) > ""`$tmp_file""",
        "timeout $(Quote-BashArg ([string]$TimeoutSeconds))s sudo docker exec -i -e SERVER_PASSWORD=$(Quote-BashArg $Secret.server_password) softether-cascade sh -c $(Quote-BashArg $vpncmdScript) < ""`$tmp_file"" 2>&1",
        "status_rc=`$?",
        "echo __AI_SP_CASCADE_STATUS_RC__:`$status_rc",
        "exit ""`$status_rc"""
    )
    $probe = Invoke-SshTextCommand $keyFile $remote ($commandLines -join "`n")

    if (-not $probe.ok) {
        $result.tcp = ([string]$probe.output -match "__AI_SP_TCP_OK__")
        $getRc = Get-TaggedInt $probe.output "__AI_SP_CASCADE_GET_RC__"
        if ($result.tcp -and $null -ne $getRc -and $getRc -ne 0) {
            $result.error = "cascade connection missing on ingress ${ingressAlias}: $connectionName; CascadeGet rc=$getRc; raw preview: $(Get-RawOutputPreview $probe.output)"
        } elseif ($result.tcp -and $null -ne $getRc -and $getRc -eq 0 -and -not (Test-CascadeGetOutput $probe.output $connectionName)) {
            $result.error = "cascade connection missing on ingress ${ingressAlias}: $connectionName; raw preview: $(Get-RawOutputPreview $probe.output)"
        } elseif ($result.tcp -and $probe.exit_code -eq 124) {
            $result.error = "cascade connection exists but status check timed out for ${connectionName}; raw preview: $(Get-RawOutputPreview $probe.output)"
        } else {
            $result.error = "cascade health check failed with exit code $($probe.exit_code); raw preview: $(Get-RawOutputPreview $probe.output)"
        }
        return [pscustomobject]$result
    }

    $result.tcp = $true
    $result.status = Get-CascadeStatusText $probe.output
    $result.online = Test-CascadeStatusOnline $result.status
    if (-not $result.online -and [string]::IsNullOrWhiteSpace($result.status)) {
        $result.status = "unknown"
    }
    return [pscustomobject]$result
}

if ($TimeoutSeconds -lt 1) {
    Fail "-TimeoutSeconds must be at least 1"
}

if ($SelfTest) {
    $fixture = @'
VPN Server/CascadeLab>CascadeStatusGet vps1-to-vps7
CascadeStatusGet command - Get Current Cascade Connection Status
Item                                      |Value
------------------------------------------+--------------------------------------------------------
VPN Connection Setting Name               |vps1-to-vps7
Session Status                            |Connection Completed (Session Established)
VLAN ID                                   |-
The command completed successfully.
'@
    $statusText = Get-CascadeStatusText $fixture
    if ($statusText -ne "Connection Completed (Session Established)") {
        Fail "SelfTest failed: unexpected status text: $statusText"
    }
    if (-not (Test-CascadeStatusOnline $statusText)) {
        Fail "SelfTest failed: online parser returned false"
    }
    Write-Host "check_vpn_cascade_links parser self-test passed"
    exit 0
}

$script:SshExecutablePath = Resolve-SshExecutable $SshPath
$nodes = Load-Nodes $NodesFile
if ($StateFile) {
    Require-File $StateFile "StateFile"
}
if (-not (Test-Path -LiteralPath $SecretFile -PathType Leaf)) {
    if (-not (Test-PresentVpnCascadeState $StateFile)) {
        Write-Host "No vpn_cascade links selected."
        exit 0
    }
    Fail "vpn_cascade secret not found: $SecretFile"
}
$secret = Read-JsonFile $SecretFile "vpn_cascade secret"
if (-not $secret.links -or $secret.links.Count -eq 0) {
    Fail "cascade secret must include links array: $SecretFile"
}

$links = @($secret.links | Where-Object {
    $state = if ($_.state) { [string]$_.state } elseif ($secret.state) { [string]$secret.state } else { "active" }
    if ($OnlyActive) {
        $state -eq "active"
    } else {
        $state -in @("active", "probe")
    }
})

if ($links.Count -eq 0) {
    Write-Host "No vpn_cascade links selected."
    exit 0
}

$rows = New-Object System.Collections.ArrayList
foreach ($link in $links) {
    foreach ($field in @("connection_name", "ingress_alias", "egress_alias", "egress_host", "egress_port")) {
        if ([string]::IsNullOrWhiteSpace([string]$link.$field)) {
            Fail "cascade link missing required field ${field}: $SecretFile"
        }
    }
    [void]$rows.Add((Test-Link $link $secret $nodes))
}

$result = @($rows.ToArray())

if ($Json) {
    $result | ConvertTo-Json -Depth 6
    exit 0
}

$result |
    Select-Object connection, state, ingress, egress, endpoint, tcp, online, status, error |
    Format-Table -AutoSize -Wrap
