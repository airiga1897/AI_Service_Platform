param(
    [string]$ProposalDir = ".\operator\egress_policy\proposals",
    [string]$AppliedRoutesDir = ".\operator\egress_policy\applied_routes",
    [string]$DnsSetDir = ".\operator\egress_policy\dns_sets",
    [string]$HistoryDir = ".\operator\egress_policy\history",
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$StateFile = ".\operator\state.csv",
    [string]$NetworksFile = ".\operator\networks.csv",
    [string]$CascadeConfigFile = ".\operator\softether\cascade\secrets\lab-cascade.json",
    [string]$OperatorDir = ".\operator",
    [string]$ApplyScript = ".\tools\egress_policy\apply_selective_fallback_routes.ps1",
    [string]$SshUser = "useradmin",
    [string]$SshPath = "ssh",
    [string[]]$Domain = @(),
    [string[]]$Profile = @(),
    [string[]]$Id = @(),
    [int[]]$Port = @(),
    [int]$ResolveAttempts = 8,
    [int]$ResolveDelayMilliseconds = 250,
    [int]$GraceMinutes = 30,
    [int]$TimeoutSeconds = 10,
    [switch]$Apply,
    [switch]$Verify,
    [switch]$AutoAcceptHostKey = $true,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,connection,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$ExpectedNetworksHeader = "alias,policy_subnet,edge_ip,cascade_ip,cascade_router_ip,policy_gateway_ip"

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
        Fail "failed to parse ${Label}: $Path"
    }
}

function Quote-BashArg($Value) {
    $text = [string]$Value
    return "'" + ($text -replace "'", "'\''") + "'"
}

function ConvertTo-Base64Utf8($Text) {
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$Text))
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

function Read-CsvMap($Path, $ExpectedHeader, $KeyField, $Label) {
    Require-File $Path $Label
    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -eq 0 -or $lines[0].Trim() -ne $ExpectedHeader) {
        Fail "$Label header must be exactly: $ExpectedHeader"
    }
    $rows = @($lines | ConvertFrom-Csv)
    $map = @{}
    foreach ($row in $rows) {
        $key = [string]$row.$KeyField
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }
        if ($map.ContainsKey($key)) {
            Fail "$Label has duplicate ${KeyField}: $key"
        }
        $map[$key] = $row
    }
    return $map
}

function Split-AliasList($Value) {
    return @(([string]$Value) -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Load-StateRows {
    Require-File $StateFile "state.csv"
    $lines = @(Get-Content -LiteralPath $StateFile)
    if ($lines.Count -eq 0 -or $lines[0].Trim() -ne $ExpectedStateHeader) {
        Fail "state.csv header must be exactly: $ExpectedStateHeader"
    }
    return @($lines | ConvertFrom-Csv)
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
    $activeSet = @{}
    $oldSet = @{}
    foreach ($edge in @(Split-CascadeEdgeList $row.active_aliases)) {
        if ($edge -notmatch '^[A-Za-z0-9_.-]+>[A-Za-z0-9_.-]+$') {
            Fail "cascade_topology $($row.name) has invalid active edge '$edge'; expected alias>alias"
        }
        $activeSet[$edge] = $true
    }
    foreach ($edge in @(Split-CascadeEdgeList $row.old_aliases)) {
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

function Test-IPv4($Value) {
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse([string]$Value, [ref]$ip)) {
        return $false
    }
    return $ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Get-UniqueIPv4($Values) {
    return @($Values | ForEach-Object { ([string]$_).Trim() } | Where-Object { Test-IPv4 $_ } | Sort-Object -Unique)
}

function Resolve-LocalDns($Name) {
    $ips = New-Object System.Collections.ArrayList
    for ($attempt = 0; $attempt -lt $ResolveAttempts; $attempt++) {
        try {
            foreach ($address in [System.Net.Dns]::GetHostAddresses([string]$Name)) {
                if ($address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    [void]$ips.Add($address.IPAddressToString)
                }
            }
        } catch {
            Write-Host "[WARN] local DNS resolve failed for ${Name}: $($_.Exception.Message)"
        }
        if ($attempt -lt ($ResolveAttempts - 1)) {
            Start-Sleep -Milliseconds $ResolveDelayMilliseconds
        }
    }
    return Get-UniqueIPv4 $ips.ToArray()
}

function Resolve-RemoteDns($Name, $IngressAlias) {
    $python = @'
import socket
import sys
import time

host = sys.argv[1]
attempts = int(sys.argv[2])
delay = float(sys.argv[3])
ips = set()
for attempt in range(attempts):
    try:
        for info in socket.getaddrinfo(host, None, family=socket.AF_INET, type=socket.SOCK_STREAM):
            ips.add(info[4][0])
    except Exception:
        pass
    if attempt + 1 < attempts:
        time.sleep(delay)
print("\n".join(sorted(ips)))
'@
    $pythonB64 = ConvertTo-Base64Utf8 $python
    $delaySeconds = [Math]::Max(0, $ResolveDelayMilliseconds) / 1000.0
    $command = "python3 -c $(Quote-BashArg "import base64,sys; exec(base64.b64decode('$pythonB64'))") $(Quote-BashArg ([string]$Name)) $ResolveAttempts $delaySeconds"
    $output = Invoke-SshText $IngressAlias $command
    return Get-UniqueIPv4 ($output -split "`n")
}

function Get-Proposals {
    if (-not (Test-Path -LiteralPath $ProposalDir -PathType Container)) {
        return @()
    }
    $domainFilter = @($Domain | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $profileFilter = @($Profile | Where-Object { $_ })
    $idFilter = @($Id | Where-Object { $_ })
    $portFilter = @($Port | Sort-Object -Unique)
    $items = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $ProposalDir -Filter "*.json" -File | Sort-Object Name)) {
        $proposal = Read-JsonFile $file.FullName "proposal"
        if ($proposal.status -ne "accepted" -or $proposal.type -ne "fallback_available") {
            continue
        }
        if (-not $proposal.target -or $proposal.target.type -ne "domain") {
            continue
        }
        if (-not $proposal.recommended_path -or $proposal.recommended_path.mode -ne "cascade") {
            continue
        }
        if ($idFilter.Count -gt 0 -and $idFilter -notcontains [string]$proposal.id) {
            continue
        }
        if ($profileFilter.Count -gt 0 -and $profileFilter -notcontains [string]$proposal.profile) {
            continue
        }
        if ($domainFilter.Count -gt 0 -and $domainFilter -notcontains ([string]$proposal.target.value).ToLowerInvariant()) {
            continue
        }
        if ($portFilter.Count -gt 0 -and $portFilter -notcontains [int]$proposal.target.port) {
            continue
        }
        $items += [pscustomobject]@{ Proposal = $proposal; Path = $file.FullName }
    }
    return $items
}

function Get-AppliedIps($ProposalId) {
    $path = Join-Path $AppliedRoutesDir "$ProposalId.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }
    $state = Read-JsonFile $path "applied route state"
    return Get-UniqueIPv4 @($state.steps | ForEach-Object { $_.target_ip })
}

function Get-DnsSetStatePath($ProposalId) {
    return Join-Path $DnsSetDir "$ProposalId.json"
}

function Read-DnsSetState($ProposalId) {
    $path = Get-DnsSetStatePath $ProposalId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    $state = Read-JsonFile $path "DNS-set state"
    if ($state.schema_version -ne 1) {
        Fail "DNS-set state schema_version must be 1: $path"
    }
    return $state
}

function Write-DnsSetState($State) {
    New-Item -ItemType Directory -Force -Path $DnsSetDir | Out-Null
    $path = Get-DnsSetStatePath ([string]$State.proposal_id)
    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
}

function Update-DnsSetState($Existing, $Proposal, $ObservedIps, $AppliedIps, $NowUtc) {
    $records = @{}
    if ($Existing -and $Existing.ip_records) {
        foreach ($record in @($Existing.ip_records)) {
            $ip = [string]$record.ip
            if (Test-IPv4 $ip -and -not $records.ContainsKey($ip)) {
                $records[$ip] = [pscustomobject]@{
                    ip = $ip
                    first_seen_utc = if ($record.first_seen_utc) { [string]$record.first_seen_utc } else { $NowUtc }
                    last_seen_utc = if ($record.last_seen_utc) { [string]$record.last_seen_utc } else { $NowUtc }
                }
            }
        }
    }
    foreach ($ip in @($AppliedIps)) {
        if (-not $records.ContainsKey($ip)) {
            $records[$ip] = [pscustomobject]@{
                ip = $ip
                first_seen_utc = $NowUtc
                last_seen_utc = $NowUtc
            }
        }
    }
    foreach ($ip in @($ObservedIps)) {
        if ($records.ContainsKey($ip)) {
            $records[$ip].last_seen_utc = $NowUtc
        } else {
            $records[$ip] = [pscustomobject]@{
                ip = $ip
                first_seen_utc = $NowUtc
                last_seen_utc = $NowUtc
            }
        }
    }
    return [ordered]@{
        schema_version = 1
        proposal_id = [string]$Proposal.id
        domain = [string]$Proposal.target.value
        profile = [string]$Proposal.profile
        protocol = [string]$Proposal.target.protocol
        port = [int]$Proposal.target.port
        ingress_alias = [string]$Proposal.recommended_path.ingress_alias
        egress_alias = [string]$Proposal.recommended_path.egress_alias
        grace_minutes = [int]$GraceMinutes
        updated_at_utc = $NowUtc
        ip_records = @($records.Values | Sort-Object ip)
    }
}

function Get-LastSeenUtc($State, $Ip) {
    if (-not $State -or -not $State.ip_records) {
        return $null
    }
    $record = @($State.ip_records | Where-Object { [string]$_.ip -eq [string]$Ip } | Select-Object -First 1)
    if ($record.Count -eq 0 -or -not $record[0].last_seen_utc) {
        return $null
    }
    try {
        return [DateTime]::Parse([string]$record[0].last_seen_utc).ToUniversalTime()
    } catch {
        return $null
    }
}

function Get-DesiredIps($ObservedIps, $AppliedIps, $State, $Now) {
    $desired = New-Object System.Collections.ArrayList
    foreach ($ip in @($ObservedIps)) {
        [void]$desired.Add($ip)
    }
    $cutoff = $Now.AddMinutes(-1 * $GraceMinutes)
    foreach ($ip in @($AppliedIps)) {
        if ($ObservedIps -contains $ip) {
            continue
        }
        $lastSeen = Get-LastSeenUtc $State $ip
        if ($null -eq $lastSeen) {
            $lastSeen = $Now
        }
        if ($lastSeen -ge $cutoff) {
            [void]$desired.Add($ip)
        }
    }
    return Get-UniqueIPv4 $desired.ToArray()
}

function Compare-StringSets($Old, $New) {
    $oldSet = @($Old | Sort-Object -Unique)
    $newSet = @($New | Sort-Object -Unique)
    return [pscustomobject]@{
        added = @($newSet | Where-Object { $oldSet -notcontains $_ })
        removed = @($oldSet | Where-Object { $newSet -notcontains $_ })
        kept = @($newSet | Where-Object { $oldSet -contains $_ })
        changed = (($oldSet -join ",") -ne ($newSet -join ","))
    }
}

function Invoke-RouteRefresh($ProposalId, $TargetIps) {
    $scriptPath = (Resolve-Path -LiteralPath $ApplyScript).Path
    Write-Host "[INFO] refreshing $ProposalId with DNS-set: $($TargetIps -join ',')"
    & $scriptPath -Action refresh -Id $ProposalId -TargetIp $TargetIps -SkipVerify
    if ($LASTEXITCODE -ne 0) {
        Fail "route refresh failed for $ProposalId"
    }
}

function Invoke-RouteVerify($ProposalId) {
    $scriptPath = (Resolve-Path -LiteralPath $ApplyScript).Path
    Write-Host "[INFO] verifying $ProposalId"
    & $scriptPath -Action verify -Id $ProposalId
    if ($LASTEXITCODE -ne 0) {
        Fail "route verify failed for $ProposalId"
    }
}

function Write-HistoryRecord($Record) {
    New-Item -ItemType Directory -Force -Path $HistoryDir | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd")
    $path = Join-Path $HistoryDir "selective-fallback-dns-refresh-$stamp.jsonl"
    ($Record | ConvertTo-Json -Depth 10 -Compress) | Add-Content -LiteralPath $path -Encoding utf8
}

if ($ResolveAttempts -lt 1) {
    Fail "-ResolveAttempts must be at least 1"
}
if ($ResolveDelayMilliseconds -lt 0) {
    Fail "-ResolveDelayMilliseconds must be 0 or greater"
}
if ($GraceMinutes -lt 0) {
    Fail "-GraceMinutes must be 0 or greater"
}
foreach ($portValue in @($Port)) {
    if ($portValue -le 0 -or $portValue -gt 65535) {
        Fail "-Port values must be in 1..65535: $portValue"
    }
}
if (($Apply -or $Verify) -and -not (Test-Path -LiteralPath $ApplyScript -PathType Leaf)) {
    Fail "apply script not found: $ApplyScript"
}

$script:SshExecutablePath = Resolve-SshExecutable $SshPath
$script:Nodes = Read-CsvMap $NodesFile $ExpectedNodesHeader "current_alias" "nodes.csv"
$script:Networks = Read-CsvMap $NetworksFile $ExpectedNetworksHeader "alias" "networks.csv"
$script:StateRows = @(Load-StateRows)
$script:ActiveCascadeAliases = @(Get-ActiveCascadeAliases)
$script:ActiveCascadeLinks = @(Load-ActiveCascadeLinks)
$script:CascadeTopologyFabric = Load-CascadeTopologyFabric
$proposals = @(Get-Proposals)
if ($proposals.Count -eq 0) {
    Fail "no accepted domain fallback proposals matched the selected filters"
}

$now = (Get-Date).ToUniversalTime()
$nowText = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
$results = @()

foreach ($item in $proposals) {
    $proposal = $item.Proposal
    $proposalId = [string]$proposal.id
    if ($Apply) {
        Assert-CurrentCascadeEgress $proposal "proposal $proposalId"
    }
    $domainValue = ([string]$proposal.target.value).ToLowerInvariant()
    $ingressAlias = [string]$proposal.recommended_path.ingress_alias
    $existingState = Read-DnsSetState $proposalId
    $appliedIps = @(Get-AppliedIps $proposalId)
    $localIps = @(Resolve-LocalDns $domainValue)
    $remoteIps = @(Resolve-RemoteDns $domainValue $ingressAlias)
    $observedIps = @(Get-UniqueIPv4 (@($localIps) + @($remoteIps)))
    if ($observedIps.Count -eq 0) {
        Fail "DNS refresh resolved no IPv4 addresses for $domainValue ($proposalId)"
    }
    $updatedState = Update-DnsSetState $existingState $proposal $observedIps $appliedIps $nowText
    $desiredIps = @(Get-DesiredIps $observedIps $appliedIps $updatedState $now)
    $diff = Compare-StringSets $appliedIps $desiredIps
    $action = if ($diff.changed) { if ($Apply) { "refresh" } else { "would_refresh" } } else { "none" }
    $result = "planned"

    if ($Apply -and $diff.changed) {
        Invoke-RouteRefresh $proposalId $desiredIps
        Write-DnsSetState $updatedState
        $result = "refreshed"
    } elseif ($Apply) {
        Write-DnsSetState $updatedState
        $result = "unchanged"
    }

    if ($Verify -and ($Apply -or $appliedIps.Count -gt 0)) {
        Invoke-RouteVerify $proposalId
        if ($result -eq "planned") {
            $result = "verified"
        } else {
            $result = "$result+verified"
        }
    }

    $row = [pscustomobject]@{
        proposal_id = $proposalId
        domain = $domainValue
        profile = [string]$proposal.profile
        protocol = [string]$proposal.target.protocol
        port = [int]$proposal.target.port
        ingress_alias = $ingressAlias
        egress_alias = [string]$proposal.recommended_path.egress_alias
        old_ips = @($appliedIps)
        observed_ips = @($observedIps)
        desired_ips = @($desiredIps)
        added_ips = @($diff.added)
        removed_ips = @($diff.removed)
        kept_ips = @($diff.kept)
        action = $action
        result = $result
        grace_minutes = [int]$GraceMinutes
        resolved_at_utc = $nowText
        resolver_sources = @("operator", "ingress:$ingressAlias")
    }
    $results += $row

    if ($Apply) {
        Write-HistoryRecord $row
    }
}

if ($Json) {
    $results | ConvertTo-Json -Depth 10
} else {
    $results | Select-Object proposal_id,domain,protocol,port,action,result,@{n="old_ips";e={$_.old_ips -join ","}},@{n="desired_ips";e={$_.desired_ips -join ","}},@{n="added_ips";e={$_.added_ips -join ","}},@{n="removed_ips";e={$_.removed_ips -join ","}} | Format-Table -AutoSize
}
