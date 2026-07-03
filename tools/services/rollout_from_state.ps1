param(
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$StateFile = ".\operator\state.csv",
    [string]$OperatorDir = ".\operator",
    [string]$ControlRole = "orchestration",
    [string]$ControlAlias = "",
    [string]$SyncScript = "tools/bootstrap/sync_to_orchestration.ps1",
    [string]$StandbyPrepareScript = "tools/bootstrap/prepare_orchestration_standby.ps1",
    [string]$ServiceRemoteScript = "tools/services/service_remote.ps1",
    [string]$OperatorBackupScript = "tools/operator_backup/backup_operator.ps1",
    [string]$OperatorBackupEnvFile = "D:\Projects\Ai_SP\Secure\operator-backup.env",
    [string]$OperatorBackupDir = "D:\Backup\Projects\AI_SP\operator",
    [string]$OperatorBackupRemoteDir = "/opt/backups/ai-service-platform/operator",
    [int]$OperatorBackupKeepLatest = 30,
    [string]$SecureBackupScript = "tools/operator_backup/backup_secure_material.ps1",
    [string]$SecureDir = "D:\Projects\Ai_SP\Secure",
    [string]$SecureBackupDir = "D:\Backup\Projects\AI_SP\secure",
    [int]$SecureBackupKeepLatest = 10,
    [string]$VpnIngressDomain = "mine-craft.su",
    [string[]]$ReseedVpnEdge = @(),
    [ValidateSet("", "edge_haproxy", "vpn_edge", "vpn_cascade", "policy_gateway", "edge_candidate_collector", "edge_banlist", "postgres_runtime", "softether_l3")]
    [string]$OnlyService = "",
    [switch]$AutoAcceptHostKey = $true,
    [switch]$SkipSync,
    [switch]$SkipStandbySync,
    [switch]$SkipPostcheck,
    [switch]$SkipDryRun,
    [switch]$SkipOperatorBackup
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$SupportedServices = @("edge_haproxy", "vpn_edge", "vpn_cascade", "policy_gateway", "edge_candidate_collector", "edge_banlist", "postgres_runtime", "softether_l3")
$ReservedServices = @()
$script:OperatorBackupCompleted = $false
$script:BatchSteps = New-Object System.Collections.Generic.List[object]

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Require-File($Path, $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Label not found: $Path"
    }
}

function Resolve-ExistingFilePath($Path, $Label) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $repoRelativePath = Join-Path $repoRoot $Path
        if (Test-Path -LiteralPath $repoRelativePath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $repoRelativePath).Path
        }
    }

    Fail "$Label not found: $Path"
}

function Resolve-OperatorDirPath($Path, $NodesFilePath) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    $nodesDir = Split-Path -Parent $NodesFilePath
    if ((Split-Path -Leaf $nodesDir) -eq "operator") {
        return $nodesDir
    }

    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Split-AliasList($Value) {
    if (-not $Value) { return @() }
    return @($Value -split "\+" | Where-Object { $_ })
}

function Split-CascadeEdgeList($Value) {
    if (-not $Value) { return @() }
    return @($Value -split "\+" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Split-OperatorAliasList($Value) {
    if (-not $Value) { return @() }
    $aliases = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        foreach ($alias in @([string]$item -split "[,+]" | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            Add-UniqueAlias $aliases $alias
        }
    }
    return @($aliases)
}

function Join-AnsibleLimit($Aliases) {
    return (@($Aliases | Where-Object { $_ }) -join ":")
}

function Get-PresentServiceAliases($Rows, $Name) {
    $aliases = New-Object System.Collections.Generic.List[string]
    $rows = @($Rows | Where-Object { $_.kind -eq "service" -and $_.name -eq $Name -and $_.state -eq "present" })
    foreach ($row in $rows) {
        foreach ($alias in (Split-AliasList $row.active_aliases)) {
            Add-UniqueAlias $aliases $alias
        }
    }
    return @($aliases)
}

function Get-ServiceApplyAliases($Row) {
    $aliases = New-Object System.Collections.Generic.List[string]
    foreach ($alias in (Split-AliasList $Row.active_aliases)) {
        Add-UniqueAlias $aliases $alias
    }
    if ($Row.name -in @("postgres_runtime", "softether_l3") -and $Row.state -eq "present") {
        foreach ($alias in (Split-AliasList $Row.candidate_aliases)) {
            Add-UniqueAlias $aliases $alias
        }
    }
    return @($aliases)
}

function Get-RetiredServiceAliases($Row) {
    if ($Row.state -ne "present") {
        return @()
    }
    $activeAliases = @(Split-AliasList $Row.active_aliases)
    $retiredAliases = New-Object System.Collections.Generic.List[string]
    foreach ($alias in @(Split-AliasList $Row.old_aliases)) {
        if ($activeAliases -contains $alias) {
            Fail "$($Row.name) lists alias '$alias' in both active_aliases and old_aliases"
        }
        Add-UniqueAlias $retiredAliases $alias
    }
    return @($retiredAliases)
}

function Get-OrchestrationCandidateAliases($Rows, $Role) {
    $roleRows = @($Rows | Where-Object { ($_.kind -eq "platform_role" -or $_.kind -eq "role") -and $_.name -eq $Role -and $_.state -eq "present" })
    if ($roleRows.Count -eq 0) {
        Fail "state.csv has no present platform_role '$Role'"
    }
    if ($roleRows.Count -gt 1) {
        Fail "state.csv has multiple present platform_role '$Role' rows; keep exactly one"
    }
    return @(Split-AliasList $roleRows[0].candidate_aliases)
}

function Get-EdgeRouteAliasesByState($Rows, $Name, $States) {
    $aliases = New-Object System.Collections.Generic.List[string]
    $rows = @($Rows | Where-Object { $_.kind -eq "edge_route" -and $_.name -eq $Name -and $States -contains $_.state })
    foreach ($row in $rows) {
        foreach ($alias in (Split-AliasList $row.active_aliases)) {
            Add-UniqueAlias $aliases $alias
        }
    }
    return @($aliases)
}

function Get-AnyEdgeRouteAliasesByState($Rows, $States) {
    $aliases = New-Object System.Collections.Generic.List[string]
    $rows = @($Rows | Where-Object { $_.kind -eq "edge_route" -and $States -contains $_.state })
    foreach ($row in $rows) {
        foreach ($alias in (Split-AliasList $row.active_aliases)) {
            Add-UniqueAlias $aliases $alias
        }
    }
    return @($aliases)
}

function Add-UniqueAlias($List, $Alias) {
    if ($List -notcontains $Alias) {
        [void]$List.Add($Alias)
    }
}

function Invoke-OperatorBackupIfNeeded($Reason) {
    if ($script:OperatorBackupCompleted) {
        return
    }
    if ($SkipOperatorBackup) {
        Write-Warning "Operator backup and secure material backup skipped before local mutation: $Reason"
        $script:OperatorBackupCompleted = $true
        return
    }

    Require-File $SecureBackupScript "SecureBackupScript"
    Require-File $OperatorBackupScript "OperatorBackupScript"
    Write-Host "Secure material backup before local mutation: $Reason"
    $secureArgs = @(
        "-SecureDir", $SecureDir,
        "-LocalBackupDir", $SecureBackupDir,
        "-KeepLatest", $SecureBackupKeepLatest
    )
    & powershell -NoProfile -ExecutionPolicy Bypass -File $SecureBackupScript @secureArgs
    if ($LASTEXITCODE -ne 0) {
        Fail "secure material backup failed before local mutation: $Reason"
    }

    Write-Host "Operator backup before local mutation: $Reason"
    $args = @(
        "-NodesFile", $NodesFile,
        "-StateFile", $StateFile,
        "-OperatorDir", $OperatorDir,
        "-ControlRole", $ControlRole,
        "-OperatorBackupEnvFile", $OperatorBackupEnvFile,
        "-LocalBackupDir", $OperatorBackupDir,
        "-RemoteBackupDir", $OperatorBackupRemoteDir,
        "-KeepLatest", $OperatorBackupKeepLatest
    )
    if ($AutoAcceptHostKey) { $args += "-AutoAcceptHostKey" }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $OperatorBackupScript @args
    if ($LASTEXITCODE -ne 0) {
        Fail "operator backup failed before local mutation: $Reason"
    }
    $script:OperatorBackupCompleted = $true
}

function Write-StateCsv($Path, $Rows) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($ExpectedStateHeader)
    foreach ($row in $Rows) {
        $lines.Add(("{0},{1},{2},{3},{4},{5},{6}" -f
            $row.kind,
            $row.name,
            $row.ansible_group,
            $row.active_aliases,
            $row.candidate_aliases,
            $row.old_aliases,
            $row.state))
    }
    Set-Content -LiteralPath $Path -Value $lines -Encoding ascii
}

function Write-AsciiLinesLf($Path, $Lines) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $content = [string]::Join("`n", @($Lines))
    if (@($Lines).Count -gt 0) {
        $content += "`n"
    }
    [System.IO.File]::WriteAllText($fullPath, $content, [System.Text.Encoding]::ASCII)
}

function Normalize-StateRows($Rows, $NodeRows, $StatePath) {
    $nodeAliases = @($NodeRows | ForEach-Object { $_.current_alias } | Where-Object { $_ })
    $changed = $false

    foreach ($row in $Rows) {
        if ($row.kind -eq "role") {
            $row.kind = "platform_role"
            $changed = $true
        }

        if ($row.kind -eq "cascade_topology") {
            foreach ($field in @("active_aliases", "old_aliases")) {
                foreach ($edge in (Split-CascadeEdgeList $row.$field)) {
                    if ($edge -notmatch '^[A-Za-z0-9_.-]+>[A-Za-z0-9_.-]+$') {
                        Fail "cascade_topology $($row.name) has invalid edge '$edge' in ${field}; expected alias>alias"
                    }
                }
            }
            continue
        }

        foreach ($field in @("active_aliases", "candidate_aliases")) {
            foreach ($alias in (Split-AliasList $row.$field)) {
                if ($nodeAliases -notcontains $alias) {
                    Fail "state.csv references alias '$alias' in $($row.kind):$($row.name), but nodes.csv has no such alias."
                }
            }
        }
        foreach ($alias in (Split-AliasList $row.old_aliases)) {
            if ($nodeAliases -notcontains $alias) {
                Write-Host "state.csv old_aliases references retired alias '$alias' in $($row.kind):$($row.name); alias is not present in nodes.csv and will not be targeted directly."
            }
        }
    }

    if ($changed) {
        Invoke-OperatorBackupIfNeeded "normalize state.csv role rows"
        Write-StateCsv $StatePath $Rows
        Write-Host "Normalized state.csv: role -> platform_role"
    }

    return $Rows
}

function Get-PresentVpnIngressAliases($Rows) {
    $aliases = New-Object System.Collections.Generic.List[string]
    $rows = @($Rows | Where-Object { $_.kind -eq "edge_route" -and $_.name -eq "vpn_ingress" -and $_.state -eq "present" })
    foreach ($row in $rows) {
        foreach ($alias in (Split-AliasList $row.active_aliases)) {
            Add-UniqueAlias $aliases $alias
        }
    }
    return @($aliases)
}

function Get-PresentVpnCascadeRouteAliases($Rows) {
    $aliases = New-Object System.Collections.Generic.List[string]
    $rows = @($Rows | Where-Object { $_.kind -eq "edge_route" -and $_.name -eq "vpn_cascade" -and $_.state -eq "present" })
    foreach ($row in $rows) {
        foreach ($alias in (Split-AliasList $row.active_aliases)) {
            Add-UniqueAlias $aliases $alias
        }
    }
    return @($aliases)
}

function Assert-NoHaproxyCascadeSurface($RoutesPath) {
    if (-not (Test-Path -LiteralPath $RoutesPath -PathType Leaf)) {
        return
    }
    $content = Get-Content -LiteralPath $RoutesPath -Raw
    if ($content -match "(?m)^vpn_cascade:\s*$") {
        Fail "edge_route vpn_cascade has no present aliases, but $RoutesPath still contains a vpn_cascade section. Remove stale cascade routes before sync."
    }
}

function Get-VpnCascadeLinkSecretPath() {
    return (Join-Path (Join-Path (Join-Path (Join-Path $OperatorDir "softether") "cascade") "secrets") "lab-cascade.json")
}

function Assert-SoftetherL3SecretsPresent($Rows, $ServiceFilter) {
    if ($ServiceFilter -and $ServiceFilter -ne "softether_l3") {
        return
    }

    $serviceRows = @($Rows | Where-Object {
        $_.kind -eq "service" -and $_.name -eq "softether_l3" -and $_.state -eq "present"
    })
    if ($serviceRows.Count -eq 0) {
        return
    }

    $tunnelsPath = Join-Path (Join-Path (Join-Path $OperatorDir "softether") "l3") "tunnels.yml"
    if (-not (Test-Path -LiteralPath $tunnelsPath -PathType Leaf)) {
        Fail "softether_l3 requires tunnels.yml before rollout: $tunnelsPath"
    }

    $secretsDir = Join-Path (Join-Path (Join-Path (Join-Path $OperatorDir "softether") "l3") "secrets") ""
    $checkScript = @'
import json
import os
import sys

try:
    import yaml
except Exception as exc:
    print(f"PyYAML is required to validate softether_l3 secrets: {exc}", file=sys.stderr)
    sys.exit(1)

tunnels_path = os.environ["TUNNELS_FILE"]
secrets_dir = os.environ["SECRETS_DIR"]
required = {"server_password", "hub_password", "peer_user", "peer_password"}

with open(tunnels_path, encoding="utf-8") as handle:
    config = yaml.safe_load(handle) or {}

missing = []
invalid = []
for tunnel in config.get("tunnels", []):
    if str(tunnel.get("state", "present")).strip().lower() != "present":
        continue
    name = str(tunnel.get("name") or "").strip()
    if not name:
        invalid.append("softether_l3 tunnel without name")
        continue
    secret_path = os.path.join(secrets_dir, name + ".json")
    if not os.path.isfile(secret_path):
        missing.append(secret_path)
        continue
    try:
        with open(secret_path, encoding="utf-8") as secret_handle:
            secret = json.load(secret_handle)
    except Exception as exc:
        invalid.append(f"{secret_path}: invalid JSON: {exc}")
        continue
    absent_keys = sorted(key for key in required if not str(secret.get(key) or "").strip())
    if absent_keys:
        invalid.append(f"{secret_path}: missing required keys: {', '.join(absent_keys)}")

if missing or invalid:
    for path in missing:
        print(f"missing softether_l3 secret file: {path}", file=sys.stderr)
    for item in invalid:
        print(f"invalid softether_l3 secret: {item}", file=sys.stderr)
    sys.exit(1)

print("softether_l3 secret preflight passed")
'@

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-sp-softether-l3-secret-check-" + [guid]::NewGuid().ToString("N") + ".py")
    try {
        [System.IO.File]::WriteAllText($tempScript, $checkScript, [System.Text.Encoding]::ASCII)
        $env:TUNNELS_FILE = $tunnelsPath
        $env:SECRETS_DIR = $secretsDir
        & python $tempScript
        if ($LASTEXITCODE -ne 0) {
            Fail "softether_l3 secret preflight failed; create the required JSON secret files under $secretsDir"
        }
    } finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
        Remove-Item Env:TUNNELS_FILE -ErrorAction SilentlyContinue
        Remove-Item Env:SECRETS_DIR -ErrorAction SilentlyContinue
    }
}

function Assert-VpnCascadeLinksAreAcyclic($Links) {
    if ($Links.Count -le 1) {
        return
    }

    $nodes = @{}
    $outgoing = @{}
    $inDegree = @{}
    $seenConnections = @{}
    $seenEdges = @{}
    $edgeLabels = New-Object System.Collections.ArrayList

    foreach ($link in $Links) {
        $from = [string]$link.ingress_alias
        $to = [string]$link.egress_alias
        $connectionName = [string]$link.connection_name
        if ([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to)) {
            Fail "vpn_cascade active links must include ingress_alias and egress_alias"
        }
        if ($from -eq $to) {
            Fail "vpn_cascade active link cannot point to itself: $from -> $to"
        }
        if (-not [string]::IsNullOrWhiteSpace($connectionName)) {
            if ($seenConnections.ContainsKey($connectionName)) {
                Fail "vpn_cascade active links contain duplicate connection_name: $connectionName"
            }
            $seenConnections[$connectionName] = $true
        }

        $edgeKey = "$from->$to"
        if ($seenEdges.ContainsKey($edgeKey)) {
            Fail "vpn_cascade active links contain duplicate directed edge: $edgeKey"
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
        Fail "vpn_cascade active links contain a directed cycle. Active cascade fabric must be acyclic: $($edgeLabels -join ', ')"
    }
    Assert-VpnCascadeLinksHaveNoUndirectedCycle $Links
}

function Assert-CascadeEdgesHaveNoUndirectedCycle($Edges, $Label) {
    if ($Edges.Count -le 1) {
        return
    }

    $parent = @{}
    $rank = @{}

    function Ensure-DisjointNode($Node) {
        if (-not $parent.ContainsKey($Node)) {
            $parent[$Node] = $Node
            $rank[$Node] = 0
        }
    }

    function Find-DisjointRoot($Node) {
        Ensure-DisjointNode $Node
        $root = [string]$Node
        while ([string]$parent[$root] -ne $root) {
            $root = [string]$parent[$root]
        }
        $current = [string]$Node
        while ([string]$parent[$current] -ne $current) {
            $next = [string]$parent[$current]
            $parent[$current] = $root
            $current = $next
        }
        return $root
    }

    foreach ($edge in @($Edges)) {
        if ([string]$edge -notmatch '^([^>]+)>([^>]+)$') {
            Fail "$Label has invalid edge '$edge'; expected alias>alias"
        }
        $from = $Matches[1]
        $to = $Matches[2]
        if ($from -eq $to) {
            Fail "$Label active/probe L2 edge cannot point to itself: $edge"
        }

        $fromRoot = Find-DisjointRoot $from
        $toRoot = Find-DisjointRoot $to
        if ($fromRoot -eq $toRoot) {
            Fail "$Label contains an undirected L2 cycle after adding edge $edge. SoftEther CascadeLab is a shared L2 fabric; keep it tree-shaped or move HA to L3 policy routing."
        }

        if ([int]$rank[$fromRoot] -lt [int]$rank[$toRoot]) {
            $parent[$fromRoot] = $toRoot
        } elseif ([int]$rank[$fromRoot] -gt [int]$rank[$toRoot]) {
            $parent[$toRoot] = $fromRoot
        } else {
            $parent[$toRoot] = $fromRoot
            $rank[$fromRoot] = [int]$rank[$fromRoot] + 1
        }
    }
}

function Assert-VpnCascadeLinksHaveNoUndirectedCycle($Links) {
    $edges = @($Links | ForEach-Object { "$($_.ingress_alias)>$($_.egress_alias)" })
    Assert-CascadeEdgesHaveNoUndirectedCycle $edges "vpn_cascade active/probe links"
}

function Assert-CascadeEdgeSetIsAcyclic($Edges, $Label) {
    if ($Edges.Count -le 1) {
        return
    }
    $nodes = @{}
    $outgoing = @{}
    $inDegree = @{}
    foreach ($edge in @($Edges)) {
        $parts = @([string]$edge -split '>')
        $from = $parts[0]
        $to = $parts[1]
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
        Fail "$Label contains a directed cycle. Active cascade fabric must be acyclic: $($Edges -join ', ')"
    }
}

function Get-ActiveVpnCascadeServiceAliases($Rows) {
    $aliases = New-Object System.Collections.Generic.List[string]
    foreach ($row in @($Rows | Where-Object { $_.kind -eq "service" -and $_.name -eq "vpn_cascade" -and $_.state -eq "present" })) {
        foreach ($alias in (Split-AliasList $row.active_aliases)) {
            Add-UniqueAlias $aliases $alias
        }
    }
    return @($aliases)
}

function Get-ActiveVpnCascadeSecretEdges() {
    $secretPath = Get-VpnCascadeLinkSecretPath
    if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) {
        Fail "vpn_cascade requires link secret JSON before rollout: $secretPath"
    }
    try {
        $secret = Get-Content -Raw -LiteralPath $secretPath | ConvertFrom-Json
    } catch {
        Fail "vpn_cascade link secret JSON is not valid: $secretPath"
    }
    $links = if ($secret.links) {
        @($secret.links | Where-Object { (-not $_.state) -or $_.state -eq "active" })
    } else {
        @($secret)
    }
    $fabricLinks = if ($secret.links) {
        @($secret.links | Where-Object { (-not $_.state) -or $_.state -in @("active", "probe") })
    } else {
        @($secret)
    }
    Assert-VpnCascadeLinksHaveNoUndirectedCycle $fabricLinks
    Assert-VpnCascadeLinksAreAcyclic $links
    return @($links | ForEach-Object { "$($_.ingress_alias)>$($_.egress_alias)" } | Sort-Object -Unique)
}

function Assert-CascadeTopologyStateMatchesLinks($Rows, $NodeRows) {
    $topologyRows = @($Rows | Where-Object { $_.kind -eq "cascade_topology" -and $_.state -eq "present" })
    if ($topologyRows.Count -eq 0) {
        return
    }
    if ($topologyRows.Count -gt 1) {
        Fail "state.csv has multiple present cascade_topology rows; keep exactly one per cascade topology"
    }
    $topology = $topologyRows[0]
    if ($topology.name -ne "lab-cascade") {
        Fail "unsupported cascade_topology '$($topology.name)'; expected lab-cascade"
    }

    $nodeAliases = @($NodeRows | ForEach-Object { $_.current_alias } | Where-Object { $_ })
    $serviceAliases = @(Get-ActiveVpnCascadeServiceAliases $Rows)
    $activeEdges = @(Split-CascadeEdgeList $topology.active_aliases)
    $oldEdges = @(Split-CascadeEdgeList $topology.old_aliases)
    if ($activeEdges.Count -eq 0) {
        Fail "cascade_topology $($topology.name) has state=present but active_aliases is empty"
    }

    $seenActive = @{}
    foreach ($edge in $activeEdges) {
        if ($edge -notmatch '^([A-Za-z0-9_.-]+)>([A-Za-z0-9_.-]+)$') {
            Fail "cascade_topology $($topology.name) has invalid active edge '$edge'; expected alias>alias"
        }
        $from = $Matches[1]
        $to = $Matches[2]
        if ($from -eq $to) {
            Fail "cascade_topology $($topology.name) active edge cannot point to itself: $edge"
        }
        if ($seenActive.ContainsKey($edge)) {
            Fail "cascade_topology $($topology.name) has duplicate active edge: $edge"
        }
        $seenActive[$edge] = $true
        foreach ($alias in @($from, $to)) {
            if ($nodeAliases -notcontains $alias) {
                Fail "cascade_topology $($topology.name) active edge '$edge' references alias '$alias', but nodes.csv has no such alias"
            }
            if ($serviceAliases -notcontains $alias) {
                Fail "cascade_topology $($topology.name) active edge '$edge' references alias '$alias', but service vpn_cascade does not list it in active_aliases"
            }
        }
    }
    foreach ($edge in $oldEdges) {
        if ($edge -notmatch '^([A-Za-z0-9_.-]+)>([A-Za-z0-9_.-]+)$') {
            Fail "cascade_topology $($topology.name) has invalid old edge '$edge'; expected alias>alias"
        }
        if ($seenActive.ContainsKey($edge)) {
            Fail "cascade_topology $($topology.name) lists edge in both active_aliases and old_aliases: $edge"
        }
        if ($Matches[1] -eq $Matches[2]) {
            Fail "cascade_topology $($topology.name) old edge cannot point to itself: $edge"
        }
    }
    Assert-CascadeEdgeSetIsAcyclic $activeEdges "cascade_topology $($topology.name)"
    Assert-CascadeEdgesHaveNoUndirectedCycle $activeEdges "cascade_topology $($topology.name) active links"

    $secretEdges = @(Get-ActiveVpnCascadeSecretEdges)
    $missingInState = @($secretEdges | Where-Object { $activeEdges -notcontains $_ })
    $missingInSecret = @($activeEdges | Where-Object { $secretEdges -notcontains $_ })
    if ($missingInState.Count -gt 0 -or $missingInSecret.Count -gt 0) {
        Fail "cascade topology mismatch; update state.csv or lab-cascade.json. secret_only=[$($missingInState -join ', ')] state_only=[$($missingInSecret -join ', ')]"
    }
}

function Get-VpnCascadeOrderedAliases($Aliases) {
    $secretPath = Get-VpnCascadeLinkSecretPath
    if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) {
        Fail "vpn_cascade requires link secret JSON before rollout: $secretPath"
    }

    try {
        $secret = Get-Content -Raw -LiteralPath $secretPath | ConvertFrom-Json
    } catch {
        Fail "vpn_cascade link secret JSON is not valid: $secretPath"
    }

    $links = @()
    if ($secret.links) {
        $links = @($secret.links | Where-Object { (-not $_.state) -or $_.state -eq "active" })
    } else {
        $links = @($secret)
    }
    if ($links.Count -eq 0) {
        Fail "vpn_cascade secret must include at least one active link: $secretPath"
    }
    $fabricLinks = if ($secret.links) {
        @($secret.links | Where-Object { (-not $_.state) -or $_.state -in @("active", "probe") })
    } else {
        @($secret)
    }
    Assert-VpnCascadeLinksHaveNoUndirectedCycle $fabricLinks
    Assert-VpnCascadeLinksAreAcyclic $links

    $ordered = New-Object System.Collections.Generic.List[string]
    foreach ($link in $links) {
        if (-not $link.ingress_alias -or -not $link.egress_alias) {
            Fail "each active vpn_cascade link must include ingress_alias and egress_alias: $secretPath"
        }
        foreach ($alias in @($link.egress_alias, $link.ingress_alias)) {
            if ($Aliases -contains $alias) {
                Add-UniqueAlias $ordered $alias
            }
        }
    }
    foreach ($alias in $Aliases) {
        Add-UniqueAlias $ordered $alias
    }
    return @($ordered)
}

function Get-VpnCascadeActiveLinkAliases() {
    $secretPath = Get-VpnCascadeLinkSecretPath
    if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) {
        return @()
    }
    try {
        $secret = Get-Content -Raw -LiteralPath $secretPath | ConvertFrom-Json
    } catch {
        Fail "vpn_cascade link secret JSON is not valid: $secretPath"
    }

    $links = if ($secret.links) {
        @($secret.links | Where-Object { (-not $_.state) -or $_.state -eq "active" })
    } else {
        @($secret)
    }
    $fabricLinks = if ($secret.links) {
        @($secret.links | Where-Object { (-not $_.state) -or $_.state -in @("active", "probe") })
    } else {
        @($secret)
    }
    Assert-VpnCascadeLinksHaveNoUndirectedCycle $fabricLinks
    Assert-VpnCascadeLinksAreAcyclic $links

    $aliases = New-Object System.Collections.Generic.List[string]
    foreach ($link in $links) {
        foreach ($alias in @($link.ingress_alias, $link.egress_alias)) {
            if ($alias) {
                Add-UniqueAlias $aliases $alias
            }
        }
    }
    return @($aliases)
}

function Assert-VpnCascadeStateMatchesLinks($Rows) {
    $cascadeRows = @($Rows | Where-Object { $_.kind -eq "service" -and $_.name -eq "vpn_cascade" -and $_.state -eq "present" })
    if ($cascadeRows.Count -eq 0) {
        return
    }
    $linkAliases = @(Get-VpnCascadeActiveLinkAliases)
    if ($linkAliases.Count -eq 0) {
        return
    }
    $stateAliases = New-Object System.Collections.Generic.List[string]
    foreach ($row in $cascadeRows) {
        foreach ($alias in (Split-AliasList $row.active_aliases)) {
            Add-UniqueAlias $stateAliases $alias
        }
    }
    $missing = @($linkAliases | Where-Object { $stateAliases -notcontains $_ })
    if ($missing.Count -gt 0) {
        Fail "vpn_cascade active links reference aliases not present in service active_aliases: $($missing -join ', ')"
    }
}

function New-VpnIngressAliasBlock($Aliases, $Domain) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($alias in $Aliases) {
        $lines.Add("    ${alias}:")
        $lines.Add("      sni:")
        $lines.Add("        - vpn-${alias}.${Domain}")
    }
    return @($lines)
}

function New-VpnCascadeAliasBlock($Aliases, $Domain) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($alias in $Aliases) {
        $lines.Add("    ${alias}:")
        $lines.Add("      sni:")
        $lines.Add("        - cascade-${alias}.${Domain}")
    }
    return @($lines)
}

function New-VpnIngressRoutesBlock($Aliases, $Domain) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("vpn_ingress:")
    $lines.Add("  per_alias:")
    foreach ($line in (New-VpnIngressAliasBlock $Aliases $Domain)) {
        $lines.Add($line)
    }
    $lines.Add("  backend:")
    $lines.Add("    host: 172.20.0.2")
    $lines.Add("  ports:")
    $lines.Add("    sstp: 443")
    $lines.Add("    softether_alt: 992")
    $lines.Add("    management: 5555")
    return @($lines)
}

function New-VpnCascadeRoutesBlock($Aliases, $Domain) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("vpn_cascade:")
    $lines.Add("  per_alias:")
    foreach ($line in (New-VpnCascadeAliasBlock $Aliases $Domain)) {
        $lines.Add($line)
    }
    $lines.Add("  backend:")
    $lines.Add("    host: 172.21.0.2")
    $lines.Add("    management_host: 172.25.0.2")
    $lines.Add("  ports:")
    $lines.Add("    https: 443")
    $lines.Add("    softether_alt: 992")
    $lines.Add("    management: 5555")
    $lines.Add("    backend_https: 443")
    $lines.Add("    backend_alt: 992")
    $lines.Add("    backend_management: 5555")
    return @($lines)
}

function New-SoftetherL3AliasBlock($Aliases, $Domain) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($alias in $Aliases) {
        $lines.Add("    ${alias}:")
        $lines.Add("      sni:")
        $lines.Add("        - l3-${alias}.${Domain}")
        $lines.Add("      management_sni:")
        $lines.Add("        - cascade-${alias}.${Domain}")
    }
    return @($lines)
}

function New-SoftetherL3RoutesBlock($Aliases, $Domain) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("softether_l3:")
    $lines.Add("  per_alias:")
    foreach ($line in (New-SoftetherL3AliasBlock $Aliases $Domain)) {
        $lines.Add($line)
    }
    $lines.Add("  backend:")
    $lines.Add("    host: 172.26.0.2")
    $lines.Add("  ports:")
    $lines.Add("    https: 443")
    $lines.Add("    management: 5555")
    $lines.Add("    backend_https: 443")
    $lines.Add("    backend_management: 5555")
    return @($lines)
}

function Find-TopLevelSectionEnd($Lines, $StartIndex) {
    for ($i = $StartIndex + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^\S") {
            return $i
        }
    }
    return $Lines.Count
}

function Normalize-HaproxyRoutes($RoutesPath, $VpnAliases, $Domain) {
    if ($VpnAliases.Count -eq 0) {
        return
    }

    $routesDir = Split-Path -Parent $RoutesPath
    if ($routesDir -and -not (Test-Path -LiteralPath $routesDir -PathType Container)) {
        Invoke-OperatorBackupIfNeeded "create HAProxy routes directory"
        New-Item -ItemType Directory -Force -Path $routesDir | Out-Null
    }

    if (-not (Test-Path -LiteralPath $RoutesPath -PathType Leaf)) {
        Invoke-OperatorBackupIfNeeded "create HAProxy routes.yml"
        Set-Content -LiteralPath $RoutesPath -Value (New-VpnIngressRoutesBlock $VpnAliases $Domain) -Encoding ascii
        Write-Host "Created HAProxy routes.yml with vpn_ingress aliases: $($VpnAliases -join ', ')"
        return
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content -LiteralPath $RoutesPath)) {
        $lines.Add([string]$line)
    }

    $vpnIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^vpn_ingress:\s*$") {
            $vpnIndex = $i
            break
        }
    }

    if ($vpnIndex -lt 0) {
        $newLines = New-Object System.Collections.Generic.List[string]
        foreach ($line in (New-VpnIngressRoutesBlock $VpnAliases $Domain)) {
            $newLines.Add($line)
        }
        $newLines.Add("")
        foreach ($line in $lines) {
            $newLines.Add($line)
        }
        Invoke-OperatorBackupIfNeeded "add vpn_ingress route config"
        Set-Content -LiteralPath $RoutesPath -Value $newLines -Encoding ascii
        Write-Host "Added vpn_ingress route config for aliases: $($VpnAliases -join ', ')"
        return
    }

    $vpnEnd = Find-TopLevelSectionEnd $lines $vpnIndex
    $perAliasIndex = -1
    for ($i = $vpnIndex + 1; $i -lt $vpnEnd; $i++) {
        if ($lines[$i] -match "^  per_alias:\s*$") {
            $perAliasIndex = $i
            break
        }
    }

    if ($perAliasIndex -lt 0) {
        $insertAt = $vpnIndex + 1
        $insertLines = New-Object System.Collections.Generic.List[string]
        $insertLines.Add("  per_alias:")
        foreach ($line in (New-VpnIngressAliasBlock $VpnAliases $Domain)) {
            $insertLines.Add($line)
        }
        $lines.InsertRange($insertAt, [string[]]$insertLines)
        Invoke-OperatorBackupIfNeeded "add vpn_ingress.per_alias route config"
        Set-Content -LiteralPath $RoutesPath -Value $lines -Encoding ascii
        Write-Host "Added vpn_ingress.per_alias for aliases: $($VpnAliases -join ', ')"
        return
    }

    $perAliasEnd = $vpnEnd
    for ($i = $perAliasIndex + 1; $i -lt $vpnEnd; $i++) {
        if ($lines[$i] -match "^  \S") {
            $perAliasEnd = $i
            break
        }
    }

    $existing = @()
    for ($i = $perAliasIndex + 1; $i -lt $perAliasEnd; $i++) {
        $match = [regex]::Match($lines[$i], "^    ([A-Za-z0-9_.-]+):\s*$")
        if ($match.Success) {
            $existing += $match.Groups[1].Value
        }
    }

    $missing = @($VpnAliases | Where-Object { $existing -notcontains $_ })
    if ($missing.Count -eq 0) {
        return
    }

    $lines.InsertRange($perAliasEnd, [string[]](New-VpnIngressAliasBlock $missing $Domain))
    Invoke-OperatorBackupIfNeeded "add missing vpn_ingress aliases"
    Set-Content -LiteralPath $RoutesPath -Value $lines -Encoding ascii
    Write-Host "Added vpn_ingress routes for aliases: $($missing -join ', ')"
}

function Normalize-HaproxyCascadeRoutes($RoutesPath, $CascadeAliases, $Domain) {
    $changedAliases = New-Object System.Collections.Generic.List[string]

    if ($CascadeAliases.Count -eq 0) {
        if (-not (Test-Path -LiteralPath $RoutesPath -PathType Leaf)) {
            return @()
        }

        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($line in (Get-Content -LiteralPath $RoutesPath)) {
            $lines.Add([string]$line)
        }

        $cascadeIndex = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^vpn_cascade:\s*$") {
                $cascadeIndex = $i
                break
            }
        }

        if ($cascadeIndex -lt 0) {
            return @()
        }

        $cascadeEnd = Find-TopLevelSectionEnd $lines $cascadeIndex
        $perAliasIndex = -1
        for ($i = $cascadeIndex + 1; $i -lt $cascadeEnd; $i++) {
            if ($lines[$i] -match "^  per_alias:\s*$") {
                $perAliasIndex = $i
                break
            }
        }

        if ($perAliasIndex -ge 0) {
            $perAliasEnd = $cascadeEnd
            for ($i = $perAliasIndex + 1; $i -lt $cascadeEnd; $i++) {
                if ($lines[$i] -match "^  \S") {
                    $perAliasEnd = $i
                    break
                }
            }

            for ($i = $perAliasIndex + 1; $i -lt $perAliasEnd; $i++) {
                $match = [regex]::Match($lines[$i], "^    ([A-Za-z0-9_.-]+):\s*$")
                if ($match.Success) {
                    Add-UniqueAlias $changedAliases $match.Groups[1].Value
                }
            }
        }

        $lines.RemoveRange($cascadeIndex, ($cascadeEnd - $cascadeIndex))
        while ($cascadeIndex -lt $lines.Count -and $cascadeIndex -gt 0 -and $lines[$cascadeIndex] -eq "" -and $lines[$cascadeIndex - 1] -eq "") {
            $lines.RemoveAt($cascadeIndex)
        }

        Invoke-OperatorBackupIfNeeded "remove vpn_cascade route config"
        Set-Content -LiteralPath $RoutesPath -Value $lines -Encoding ascii
        if ($changedAliases.Count -gt 0) {
            Write-Host "Removed vpn_cascade route config for aliases: $($changedAliases.ToArray() -join ', ')"
        } else {
            Write-Host "Removed vpn_cascade route config"
        }
        return @($changedAliases.ToArray())
    }

    $routesDir = Split-Path -Parent $RoutesPath
    if ($routesDir -and -not (Test-Path -LiteralPath $routesDir -PathType Container)) {
        Invoke-OperatorBackupIfNeeded "create HAProxy routes directory"
        New-Item -ItemType Directory -Force -Path $routesDir | Out-Null
    }

    if (-not (Test-Path -LiteralPath $RoutesPath -PathType Leaf)) {
        Invoke-OperatorBackupIfNeeded "create HAProxy routes.yml"
        Set-Content -LiteralPath $RoutesPath -Value (New-VpnCascadeRoutesBlock $CascadeAliases $Domain) -Encoding ascii
        Write-Host "Created HAProxy routes.yml with vpn_cascade aliases: $($CascadeAliases -join ', ')"
        return @($CascadeAliases)
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content -LiteralPath $RoutesPath)) {
        $lines.Add([string]$line)
    }

    $cascadeIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^vpn_cascade:\s*$") {
            $cascadeIndex = $i
            break
        }
    }

    if ($cascadeIndex -lt 0) {
        $newLines = New-Object System.Collections.Generic.List[string]
        foreach ($line in $lines) {
            $newLines.Add($line)
        }
        if ($newLines.Count -gt 0 -and $newLines[$newLines.Count - 1] -ne "") {
            $newLines.Add("")
        }
        foreach ($line in (New-VpnCascadeRoutesBlock $CascadeAliases $Domain)) {
            $newLines.Add($line)
        }
        Invoke-OperatorBackupIfNeeded "add vpn_cascade route config"
        Set-Content -LiteralPath $RoutesPath -Value $newLines -Encoding ascii
        Write-Host "Added vpn_cascade route config for aliases: $($CascadeAliases -join ', ')"
        return @($CascadeAliases)
    }

    $cascadeEnd = Find-TopLevelSectionEnd $lines $cascadeIndex
    $perAliasIndex = -1
    for ($i = $cascadeIndex + 1; $i -lt $cascadeEnd; $i++) {
        if ($lines[$i] -match "^  per_alias:\s*$") {
            $perAliasIndex = $i
            break
        }
    }

    if ($perAliasIndex -lt 0) {
        $insertAt = $cascadeIndex + 1
        $insertLines = New-Object System.Collections.Generic.List[string]
        $insertLines.Add("  per_alias:")
        foreach ($line in (New-VpnCascadeAliasBlock $CascadeAliases $Domain)) {
            $insertLines.Add($line)
        }
        $lines.InsertRange($insertAt, [string[]]$insertLines)
        Invoke-OperatorBackupIfNeeded "add vpn_cascade.per_alias route config"
        Set-Content -LiteralPath $RoutesPath -Value $lines -Encoding ascii
        Write-Host "Added vpn_cascade.per_alias for aliases: $($CascadeAliases -join ', ')"
        return @($CascadeAliases)
    }

    $perAliasEnd = $cascadeEnd
    for ($i = $perAliasIndex + 1; $i -lt $cascadeEnd; $i++) {
        if ($lines[$i] -match "^  \S") {
            $perAliasEnd = $i
            break
        }
    }

    $existing = @()
    for ($i = $perAliasIndex + 1; $i -lt $perAliasEnd; $i++) {
        $match = [regex]::Match($lines[$i], "^    ([A-Za-z0-9_.-]+):\s*$")
        if ($match.Success) {
            $existing += $match.Groups[1].Value
        }
    }

    $stale = @($existing | Where-Object { $CascadeAliases -notcontains $_ })
    if ($stale.Count -gt 0) {
        $ranges = New-Object System.Collections.Generic.List[object]
        for ($i = $perAliasIndex + 1; $i -lt $perAliasEnd; $i++) {
            $match = [regex]::Match($lines[$i], "^    ([A-Za-z0-9_.-]+):\s*$")
            if (-not $match.Success) {
                continue
            }
            $alias = $match.Groups[1].Value
            $start = $i
            $end = $perAliasEnd
            for ($j = $i + 1; $j -lt $perAliasEnd; $j++) {
                if ($lines[$j] -match "^    [A-Za-z0-9_.-]+:\s*$") {
                    $end = $j
                    break
                }
            }
            if ($stale -contains $alias) {
                $ranges.Add([pscustomobject]@{ Start = $start; Count = ($end - $start) }) | Out-Null
            }
            $i = $end - 1
        }

        foreach ($range in @($ranges | Sort-Object Start -Descending)) {
            $lines.RemoveRange([int]$range.Start, [int]$range.Count)
        }
        Invoke-OperatorBackupIfNeeded "remove stale vpn_cascade route aliases"
        Set-Content -LiteralPath $RoutesPath -Value $lines -Encoding ascii
        Write-Host "Removed stale vpn_cascade routes for aliases: $($stale -join ', ')"
        foreach ($alias in $stale) {
            Add-UniqueAlias $changedAliases $alias
        }
        foreach ($alias in @(Normalize-HaproxyCascadeRoutes $RoutesPath $CascadeAliases $Domain)) {
            Add-UniqueAlias $changedAliases $alias
        }
        return @($changedAliases.ToArray())
    }

    $missing = @($CascadeAliases | Where-Object { $existing -notcontains $_ })
    if ($missing.Count -eq 0) {
        return @()
    }

    $lines.InsertRange($perAliasEnd, [string[]](New-VpnCascadeAliasBlock $missing $Domain))
    Invoke-OperatorBackupIfNeeded "add missing vpn_cascade aliases"
    Set-Content -LiteralPath $RoutesPath -Value $lines -Encoding ascii
    Write-Host "Added vpn_cascade routes for aliases: $($missing -join ', ')"
    return @($missing)
}

function Normalize-HaproxySoftetherL3Routes($RoutesPath, $L3Aliases, $Domain) {
    $changedAliases = New-Object System.Collections.Generic.List[string]
    $sectionName = "softether_l3"

    if ($L3Aliases.Count -eq 0) {
        if (-not (Test-Path -LiteralPath $RoutesPath -PathType Leaf)) {
            return @()
        }

        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($line in (Get-Content -LiteralPath $RoutesPath)) {
            $lines.Add([string]$line)
        }

        $sectionIndex = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^${sectionName}:\s*$") {
                $sectionIndex = $i
                break
            }
        }

        if ($sectionIndex -lt 0) {
            return @()
        }

        $sectionEnd = Find-TopLevelSectionEnd $lines $sectionIndex
        $perAliasIndex = -1
        for ($i = $sectionIndex + 1; $i -lt $sectionEnd; $i++) {
            if ($lines[$i] -match "^  per_alias:\s*$") {
                $perAliasIndex = $i
                break
            }
        }

        if ($perAliasIndex -ge 0) {
            $perAliasEnd = $sectionEnd
            for ($i = $perAliasIndex + 1; $i -lt $sectionEnd; $i++) {
                if ($lines[$i] -match "^  \S") {
                    $perAliasEnd = $i
                    break
                }
            }
            for ($i = $perAliasIndex + 1; $i -lt $perAliasEnd; $i++) {
                $match = [regex]::Match($lines[$i], "^    ([A-Za-z0-9_.-]+):\s*$")
                if ($match.Success) {
                    Add-UniqueAlias $changedAliases $match.Groups[1].Value
                }
            }
        }

        $lines.RemoveRange($sectionIndex, ($sectionEnd - $sectionIndex))
        while ($sectionIndex -lt $lines.Count -and $sectionIndex -gt 0 -and $lines[$sectionIndex] -eq "" -and $lines[$sectionIndex - 1] -eq "") {
            $lines.RemoveAt($sectionIndex)
        }

        Invoke-OperatorBackupIfNeeded "remove softether_l3 route config"
        Set-Content -LiteralPath $RoutesPath -Value $lines -Encoding ascii
        if ($changedAliases.Count -gt 0) {
            Write-Host "Removed softether_l3 route config for aliases: $($changedAliases.ToArray() -join ', ')"
        } else {
            Write-Host "Removed softether_l3 route config"
        }
        return @($changedAliases.ToArray())
    }

    $routesDir = Split-Path -Parent $RoutesPath
    if ($routesDir -and -not (Test-Path -LiteralPath $routesDir -PathType Container)) {
        Invoke-OperatorBackupIfNeeded "create HAProxy routes directory"
        New-Item -ItemType Directory -Force -Path $routesDir | Out-Null
    }

    if (-not (Test-Path -LiteralPath $RoutesPath -PathType Leaf)) {
        Invoke-OperatorBackupIfNeeded "create HAProxy routes.yml"
        Set-Content -LiteralPath $RoutesPath -Value (New-SoftetherL3RoutesBlock $L3Aliases $Domain) -Encoding ascii
        Write-Host "Created HAProxy routes.yml with softether_l3 aliases: $($L3Aliases -join ', ')"
        return @($L3Aliases)
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content -LiteralPath $RoutesPath)) {
        $lines.Add([string]$line)
    }

    $sectionIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^${sectionName}:\s*$") {
            $sectionIndex = $i
            break
        }
    }

    if ($sectionIndex -lt 0) {
        $newLines = New-Object System.Collections.Generic.List[string]
        foreach ($line in $lines) {
            $newLines.Add($line)
        }
        if ($newLines.Count -gt 0 -and $newLines[$newLines.Count - 1] -ne "") {
            $newLines.Add("")
        }
        foreach ($line in (New-SoftetherL3RoutesBlock $L3Aliases $Domain)) {
            $newLines.Add($line)
        }
        Invoke-OperatorBackupIfNeeded "add softether_l3 route config"
        Set-Content -LiteralPath $RoutesPath -Value $newLines -Encoding ascii
        Write-Host "Added softether_l3 route config for aliases: $($L3Aliases -join ', ')"
        return @($L3Aliases)
    }

    $sectionEnd = Find-TopLevelSectionEnd $lines $sectionIndex
    $perAliasIndex = -1
    for ($i = $sectionIndex + 1; $i -lt $sectionEnd; $i++) {
        if ($lines[$i] -match "^  per_alias:\s*$") {
            $perAliasIndex = $i
            break
        }
    }

    if ($perAliasIndex -lt 0) {
        $insertLines = New-Object System.Collections.Generic.List[string]
        $insertLines.Add("  per_alias:")
        foreach ($line in (New-SoftetherL3AliasBlock $L3Aliases $Domain)) {
            $insertLines.Add($line)
        }
        $lines.InsertRange(($sectionIndex + 1), [string[]]$insertLines)
        Invoke-OperatorBackupIfNeeded "add softether_l3.per_alias route config"
        Set-Content -LiteralPath $RoutesPath -Value $lines -Encoding ascii
        Write-Host "Added softether_l3.per_alias for aliases: $($L3Aliases -join ', ')"
        return @($L3Aliases)
    }

    $perAliasEnd = $sectionEnd
    for ($i = $perAliasIndex + 1; $i -lt $sectionEnd; $i++) {
        if ($lines[$i] -match "^  \S") {
            $perAliasEnd = $i
            break
        }
    }

    $existing = @()
    for ($i = $perAliasIndex + 1; $i -lt $perAliasEnd; $i++) {
        $match = [regex]::Match($lines[$i], "^    ([A-Za-z0-9_.-]+):\s*$")
        if ($match.Success) {
            $existing += $match.Groups[1].Value
        }
    }

    $stale = @($existing | Where-Object { $L3Aliases -notcontains $_ })
    if ($stale.Count -gt 0) {
        $ranges = New-Object System.Collections.Generic.List[object]
        for ($i = $perAliasIndex + 1; $i -lt $perAliasEnd; $i++) {
            $match = [regex]::Match($lines[$i], "^    ([A-Za-z0-9_.-]+):\s*$")
            if (-not $match.Success) {
                continue
            }
            $alias = $match.Groups[1].Value
            $start = $i
            $end = $perAliasEnd
            for ($j = $i + 1; $j -lt $perAliasEnd; $j++) {
                if ($lines[$j] -match "^    [A-Za-z0-9_.-]+:\s*$") {
                    $end = $j
                    break
                }
            }
            if ($stale -contains $alias) {
                $ranges.Add([pscustomobject]@{ Start = $start; Count = ($end - $start) }) | Out-Null
            }
            $i = $end - 1
        }

        foreach ($range in @($ranges | Sort-Object Start -Descending)) {
            $lines.RemoveRange([int]$range.Start, [int]$range.Count)
        }
        Invoke-OperatorBackupIfNeeded "remove stale softether_l3 route aliases"
        Set-Content -LiteralPath $RoutesPath -Value $lines -Encoding ascii
        Write-Host "Removed stale softether_l3 routes for aliases: $($stale -join ', ')"
        foreach ($alias in $stale) {
            Add-UniqueAlias $changedAliases $alias
        }
        foreach ($alias in @(Normalize-HaproxySoftetherL3Routes $RoutesPath $L3Aliases $Domain)) {
            Add-UniqueAlias $changedAliases $alias
        }
        return @($changedAliases.ToArray())
    }

    $missing = @($L3Aliases | Where-Object { $existing -notcontains $_ })
    if ($missing.Count -eq 0) {
        return @()
    }

    $lines.InsertRange($perAliasEnd, [string[]](New-SoftetherL3AliasBlock $missing $Domain))
    Invoke-OperatorBackupIfNeeded "add missing softether_l3 aliases"
    Set-Content -LiteralPath $RoutesPath -Value $lines -Encoding ascii
    Write-Host "Added softether_l3 routes for aliases: $($missing -join ', ')"
    return @($missing)
}

function Resolve-EndpointIpAddresses($Endpoint, $Alias) {
    if (-not $Endpoint) {
        return @()
    }

    $endpointValue = [string]$Endpoint
    $parsedIp = $null
    if ([System.Net.IPAddress]::TryParse($endpointValue, [ref]$parsedIp)) {
        if ($parsedIp.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            return @($parsedIp.IPAddressToString)
        }
        return @()
    }

    try {
        return @(
            [System.Net.Dns]::GetHostAddresses($endpointValue) |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                ForEach-Object { $_.IPAddressToString } |
                Sort-Object -Unique
        )
    } catch {
        Fail "Could not resolve endpoint '$endpointValue' for alias '$Alias' while refreshing VPN management allowlist: $($_.Exception.Message)"
    }
}

function Update-VpnManagementAllowlist($AllowlistPath, $NodeRows) {
    $beginMarker = "# BEGIN AI_SP_NODE_ENDPOINTS"
    $endMarker = "# END AI_SP_NODE_ENDPOINTS"

    $allowlistDir = Split-Path -Parent $AllowlistPath
    if ($allowlistDir -and -not (Test-Path -LiteralPath $allowlistDir -PathType Container)) {
        Invoke-OperatorBackupIfNeeded "create VPN management allowlist directory"
        New-Item -ItemType Directory -Force -Path $allowlistDir | Out-Null
    }

    $manualLines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $AllowlistPath -PathType Leaf) {
        $insideGeneratedBlock = $false
        foreach ($line in (Get-Content -LiteralPath $AllowlistPath)) {
            $lineText = [string]$line
            $trimmed = $lineText.Trim()
            if ($trimmed -eq $beginMarker) {
                $insideGeneratedBlock = $true
                continue
            }
            if ($trimmed -eq $endMarker) {
                $insideGeneratedBlock = $false
                continue
            }
            if ($insideGeneratedBlock) {
                continue
            }
            if ($manualLines -notcontains $lineText) {
                [void]$manualLines.Add($lineText)
            }
        }
    }

    $resolved = New-Object System.Collections.Generic.List[string]
    foreach ($node in $NodeRows) {
        foreach ($ip in (Resolve-EndpointIpAddresses $node.endpoint $node.current_alias)) {
            if ($resolved -notcontains $ip) {
                [void]$resolved.Add($ip)
            }
        }
    }

    $manualEntries = @(
        $manualLines |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ -and -not $_.StartsWith("#") } |
            Sort-Object -Unique
    )
    $generatedEntries = @($resolved | Where-Object { $manualEntries -notcontains $_ } | Sort-Object -Unique)

    while ($manualLines.Count -gt 0 -and -not ([string]$manualLines[$manualLines.Count - 1]).Trim()) {
        $manualLines.RemoveAt($manualLines.Count - 1)
    }

    $newLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in $manualLines) {
        [void]$newLines.Add($line)
    }
    if ($newLines.Count -gt 0) {
        [void]$newLines.Add("")
    }
    [void]$newLines.Add($beginMarker)
    foreach ($ip in $generatedEntries) {
        [void]$newLines.Add($ip)
    }
    [void]$newLines.Add($endMarker)

    $existingLines = @()
    if (Test-Path -LiteralPath $AllowlistPath -PathType Leaf) {
        $existingLines = @(Get-Content -LiteralPath $AllowlistPath)
    }
    $changed = ($newLines.Count -ne $existingLines.Count)
    if (-not $changed) {
        for ($i = 0; $i -lt $newLines.Count; $i++) {
            if ($newLines[$i] -ne $existingLines[$i]) {
                $changed = $true
                break
            }
        }
    }

    if (-not $changed) {
        return
    }

    Invoke-OperatorBackupIfNeeded "refresh VPN management allowlist from nodes.csv"
    Write-AsciiLinesLf $AllowlistPath $newLines
    Write-Host "Updated VPN management allowlist with node endpoint IPs: $($resolved -join ', ')"
}

function Invoke-ChildScript($ScriptPath, $Arguments, $Label) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label failed with exit code $LASTEXITCODE"
    }
}

function Add-ServiceBatchStep($Service, $Action, $Limit, [switch]$Check, [switch]$ConfirmPurge, [string]$Label = "") {
    if (-not $Label) {
        $Label = "$Service $Action"
        if ($Limit) { $Label += " for $Limit" }
        if ($Check) { $Label += " check" }
    }
    $script:BatchSteps.Add([pscustomobject]@{
        service = $Service
        action = $Action
        limit = $Limit
        check = [bool]$Check
        confirm_purge = [bool]$ConfirmPurge
        label = $Label
    }) | Out-Null
}

function Invoke-ServiceRemote($Service, $Action, $Limit, [switch]$Check, [switch]$ConfirmPurge) {
    Add-ServiceBatchStep $Service $Action $Limit -Check:$Check -ConfirmPurge:$ConfirmPurge
}

function Invoke-ServiceBatch() {
    if ($script:BatchSteps.Count -eq 0) {
        Write-Host "No remote service steps to run."
        return
    }

    $batchPlanPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.rollout-batch." + [guid]::NewGuid().ToString("N") + ".json")
    $serviceRemoteArgs = @(
        "-NodesFile", $NodesFile,
        "-StateFile", $StateFile,
        "-OperatorDir", $OperatorDir,
        "-ControlRole", $ControlRole,
        "-BatchPlanFile", $batchPlanPath
    )
    if ($ControlAlias) { $serviceRemoteArgs += @("-ControlAlias", $ControlAlias) }
    if ($AutoAcceptHostKey) { $serviceRemoteArgs += "-AutoAcceptHostKey" }
    try {
        $script:BatchSteps | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $batchPlanPath -Encoding ascii
        Write-Host ""
        Write-Host "Remote batch rollout plan: $($script:BatchSteps.Count) steps"
        $stepIndex = 0
        foreach ($step in $script:BatchSteps) {
            $stepIndex++
            Write-Host ("  {0}. {1}" -f $stepIndex, $step.label)
        }
        Invoke-ChildScript $ServiceRemoteScript $serviceRemoteArgs "remote batch rollout"
    } finally {
        Remove-Item -LiteralPath $batchPlanPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ServiceApplyDryRun($Service, $Limit, $Label) {
    if ($SkipDryRun) {
        Write-Host "${Label}: dry-run skipped"
        Write-Host "Dry-run: skipped by operator request"
        return
    }
    Write-Host "${Label}: dry-run queued"
    Invoke-ServiceRemote $Service "apply" $Limit -Check
}

function Invoke-ServiceActionDryRun($Service, $Action, $Limit, $Label) {
    if ($SkipDryRun) {
        Write-Host "${Label}: dry-run skipped"
        Write-Host "Dry-run: skipped by operator request"
        return
    }
    Write-Host "${Label}: dry-run queued"
    Invoke-ServiceRemote $Service $Action $Limit -Check
}

function Invoke-VpnEdgeReseed($Alias, $ReseededAliases, $Summary) {
    if ($ReseededAliases -contains $Alias) {
        return
    }
    Write-Host "vpn_edge on ${Alias}: reseed queued"
    Invoke-ServiceRemote "vpn_edge" "reseed" $Alias
    Add-UniqueAlias $ReseededAliases $Alias
    $Summary.Add("vpn_edge ${Alias}: reseeded") | Out-Null
}

function Invoke-Sync() {
    $args = @(
        "-NodesFile", $NodesFile,
        "-StateFile", $StateFile,
        "-OperatorDir", $OperatorDir,
        "-ControlRole", $ControlRole
    )
    if ($ControlAlias) { $args += @("-ControlAlias", $ControlAlias) }
    if ($AutoAcceptHostKey) { $args += "-AutoAcceptHostKey" }
    Invoke-ChildScript $SyncScript $args "sync to orchestration"
}

function Invoke-StandbySync($Aliases) {
    if ($Aliases.Count -eq 0) {
        return
    }

    Write-Host ""
    Write-Host "Step 1b/3: sync standby orchestration candidate nodes"
    foreach ($alias in $Aliases) {
        Write-Host "Preparing standby orchestration node ${alias}"
        $args = @(
            "-Alias", $alias,
            "-NodesFile", $NodesFile,
            "-StateFile", $StateFile,
            "-OperatorDir", $OperatorDir,
            "-ControlRole", $ControlRole,
            "-SyncScript", $SyncScript,
            "-SkipServicePlan"
        )
        if ($AutoAcceptHostKey) { $args += "-AutoAcceptHostKey" }
        Invoke-ChildScript $StandbyPrepareScript $args "standby orchestration preparation for $alias"
    }
}

function Invoke-Postcheck($Service, $State, $Alias) {
    if ($SkipPostcheck) {
        Write-Host "Postcheck skipped for $Service on $Alias"
        return
    }

    switch ($Service) {
        "edge_haproxy" {
            switch ($State) {
                "present" {
                    Invoke-ServiceRemote $Service "plan" $Alias
                    Write-Host "edge_haproxy postcheck queued for $Alias"
                }
                "absent" {
                    Write-Host "Postcheck note: edge_haproxy absent requested for $Alias; config/data should remain on target"
                }
                "purged" {
                    Write-Host "Postcheck note: edge_haproxy purge requested for $Alias; runtime directory removal is handled by the role"
                }
            }
        }
        default {
            return
        }
    }
}

$NodesFile = Resolve-ExistingFilePath $NodesFile "NodesFile"
$StateFile = Resolve-ExistingFilePath $StateFile "StateFile"
$OperatorDir = Resolve-OperatorDirPath $OperatorDir $NodesFile
$SyncScript = Resolve-ExistingFilePath $SyncScript "SyncScript"
if (-not $SkipStandbySync) {
    $StandbyPrepareScript = Resolve-ExistingFilePath $StandbyPrepareScript "StandbyPrepareScript"
}
$ServiceRemoteScript = Resolve-ExistingFilePath $ServiceRemoteScript "ServiceRemoteScript"
$OperatorBackupScript = Resolve-ExistingFilePath $OperatorBackupScript "OperatorBackupScript"
$SecureBackupScript = Resolve-ExistingFilePath $SecureBackupScript "SecureBackupScript"

$nodesHeader = Get-Content -LiteralPath $NodesFile -TotalCount 1
if ($nodesHeader -ne $ExpectedNodesHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedNodesHeader"
}
$stateHeader = Get-Content -LiteralPath $StateFile -TotalCount 1
if ($stateHeader -ne $ExpectedStateHeader) {
    Fail "state.csv header must be exactly: $ExpectedStateHeader"
}

$nodeRows = Import-Csv -LiteralPath $NodesFile
$stateRows = Import-Csv -LiteralPath $StateFile
$stateRows = @(Normalize-StateRows $stateRows $nodeRows $StateFile)
Update-VpnManagementAllowlist (Join-Path (Join-Path (Join-Path $OperatorDir "haproxy") "lists") "vpn_mgmt_ips.lst") $nodeRows
$haproxyRoutesPath = Join-Path (Join-Path $OperatorDir "haproxy") "routes.yml"
$presentVpnCascadeRouteAliases = @(Get-PresentVpnCascadeRouteAliases $stateRows)
$presentSoftetherL3RouteAliases = @(Get-EdgeRouteAliasesByState $stateRows "softether_l3" @("present"))
Normalize-HaproxyRoutes $haproxyRoutesPath (Get-PresentVpnIngressAliases $stateRows) $VpnIngressDomain
$haproxyCascadeRouteChangedAliases = @(Normalize-HaproxyCascadeRoutes $haproxyRoutesPath $presentVpnCascadeRouteAliases $VpnIngressDomain)
$haproxySoftetherL3RouteChangedAliases = @(Normalize-HaproxySoftetherL3Routes $haproxyRoutesPath $presentSoftetherL3RouteAliases $VpnIngressDomain)
if ($presentVpnCascadeRouteAliases.Count -eq 0) {
    Assert-NoHaproxyCascadeSurface $haproxyRoutesPath
}
$reseedVpnEdgeAliases = @(Split-OperatorAliasList $ReseedVpnEdge)
$standbyOrchestrationAliases = @(Get-OrchestrationCandidateAliases $stateRows $ControlRole)

$serviceRows = @($stateRows | Where-Object { $_.kind -eq "service" })
if ($serviceRows.Count -eq 0) {
    Fail "state.csv has no service rows"
}
Assert-CascadeTopologyStateMatchesLinks $stateRows $nodeRows
Assert-VpnCascadeStateMatchesLinks $stateRows
Assert-SoftetherL3SecretsPresent $stateRows $OnlyService
if ($OnlyService) {
    $onlyServiceRows = @($serviceRows | Where-Object { $_.name -eq $OnlyService })
    if ($onlyServiceRows.Count -eq 0) {
        Fail "OnlyService '$OnlyService' was requested, but state.csv has no service row with that name"
    }
    Write-Host "OnlyService: $OnlyService"
}
$edgeRouteRows = @($stateRows | Where-Object { $_.kind -eq "edge_route" })
$edgeHaproxyAliases = @(Get-PresentServiceAliases $stateRows "edge_haproxy")
$vpnEdgeAliases = @(Get-PresentServiceAliases $stateRows "vpn_edge")
$vpnCascadeAliases = @(Get-PresentServiceAliases $stateRows "vpn_cascade")
$softetherL3Aliases = @(
    $stateRows |
        Where-Object { $_.kind -eq "service" -and $_.name -eq "softether_l3" -and $_.state -eq "present" } |
        ForEach-Object { Get-ServiceApplyAliases $_ } |
        Select-Object -Unique
)
$vpnIngressAliases = @(Get-EdgeRouteAliasesByState $stateRows "vpn_ingress" @("present"))
$presentEdgeRouteAliases = @(Get-AnyEdgeRouteAliasesByState $stateRows @("present"))
$edgeRouteApplyAliases = New-Object System.Collections.Generic.List[string]
$edgeRouteRemovalAliases = New-Object System.Collections.Generic.List[string]
foreach ($alias in $haproxyCascadeRouteChangedAliases) {
    Add-UniqueAlias $edgeRouteApplyAliases $alias
}
foreach ($alias in $haproxySoftetherL3RouteChangedAliases) {
    Add-UniqueAlias $edgeRouteApplyAliases $alias
}

$nodeAliases = @($nodeRows | ForEach-Object { $_.current_alias } | Where-Object { $_ })
foreach ($alias in $reseedVpnEdgeAliases) {
    if ($nodeAliases -notcontains $alias) {
        Fail "ReseedVpnEdge alias '$alias' is not present in nodes.csv"
    }
    if ($vpnEdgeAliases -notcontains $alias) {
        Fail "ReseedVpnEdge alias '$alias' requires service vpn_edge present on the same alias in state.csv"
    }
}

foreach ($routeRow in $edgeRouteRows) {
    if ($routeRow.state -notin @("present", "absent", "purged")) {
        Fail "$($routeRow.name) edge_route state must be one of: present, absent, purged"
    }
    if ($routeRow.state -ne "present") {
        continue
    }
    $routeAliases = @(Split-AliasList $routeRow.active_aliases)
    if ($routeAliases.Count -eq 0) {
        Fail "edge_route $($routeRow.name) has state=present but active_aliases is empty"
    }
    foreach ($alias in $routeAliases) {
        if ($edgeHaproxyAliases -notcontains $alias) {
            Fail "edge_route $($routeRow.name) is present on $alias, but service edge_haproxy is not present on the same alias"
        }
        if ($routeRow.name -eq "vpn_ingress" -and ($vpnEdgeAliases -notcontains $alias)) {
            Fail "edge_route vpn_ingress is present on $alias, but service vpn_edge is not present on the same alias"
        }
        if ($routeRow.name -eq "vpn_cascade" -and ($vpnCascadeAliases -notcontains $alias)) {
            Fail "edge_route vpn_cascade is present on $alias, but service vpn_cascade is not present on the same alias"
        }
        if ($routeRow.name -eq "softether_l3" -and ($softetherL3Aliases -notcontains $alias)) {
            Fail "edge_route softether_l3 is present on $alias, but service softether_l3 is not present on the same alias"
        }
        Add-UniqueAlias $edgeRouteApplyAliases $alias
    }
}

foreach ($routeRow in @($edgeRouteRows | Where-Object { $_.state -in @("absent", "purged") })) {
    foreach ($alias in (Split-AliasList $routeRow.active_aliases)) {
        if ($edgeHaproxyAliases -contains $alias) {
            Add-UniqueAlias $edgeRouteRemovalAliases $alias
        }
    }
}

foreach ($serviceRow in $serviceRows) {
    if ($serviceRow.state -notin @("present", "absent", "purged")) {
        Fail "$($serviceRow.name) state must be one of: present, absent, purged"
    }
    [void](Get-RetiredServiceAliases $serviceRow)
    foreach ($alias in (Split-AliasList $serviceRow.active_aliases)) {
        if ($serviceRow.name -eq "vpn_edge" -and $serviceRow.state -eq "present" -and ($vpnIngressAliases -notcontains $alias)) {
            Fail "service vpn_edge is present on $alias, but edge_route vpn_ingress is not present on the same alias"
        }
        if ($serviceRow.name -eq "vpn_edge" -and $serviceRow.state -in @("absent", "purged") -and ($vpnIngressAliases -contains $alias)) {
            Fail "service vpn_edge is $($serviceRow.state) on $alias, but edge_route vpn_ingress is still present on the same alias"
        }
        if ($serviceRow.name -eq "edge_haproxy" -and $serviceRow.state -in @("absent", "purged") -and ($presentEdgeRouteAliases -contains $alias)) {
            Fail "service edge_haproxy is $($serviceRow.state) on $alias, but an edge_route is still present on the same alias"
        }
    }
}

if (-not $SkipSync) {
    Write-Host "Step 1/3: sync operator state to active orchestration node"
    Invoke-Sync
    if (-not $SkipStandbySync) {
        Invoke-StandbySync $standbyOrchestrationAliases
    } else {
        Write-Host "Step 1b/3: standby orchestration sync skipped by -SkipStandbySync"
    }
} else {
    Write-Host "Step 1/3: sync skipped by -SkipSync"
    Write-Host "Step 1b/3: standby orchestration sync skipped because sync is skipped"
}

$summary = New-Object System.Collections.Generic.List[string]
$plannedServices = New-Object System.Collections.Generic.List[string]
$processedServiceActions = New-Object System.Collections.Generic.List[string]
$reseededVpnEdgeAliases = New-Object System.Collections.Generic.List[string]
Write-Host ""
Write-Host "Step 2/3: rollout services from state.csv"

if ($edgeRouteRemovalAliases.Count -gt 0) {
    Write-Host ""
    Write-Host "Step 2a/3: remove absent edge routes through edge_haproxy before stopping backends"
    if ($OnlyService -and $OnlyService -ne "edge_haproxy") {
        Write-Host "Skipped edge route removal because -OnlyService $OnlyService was requested"
    } else {
        if ($plannedServices -notcontains "edge_haproxy") {
            Invoke-ServiceRemote "edge_haproxy" "plan" ""
            Add-UniqueAlias $plannedServices "edge_haproxy"
        }
        $limit = Join-AnsibleLimit $edgeRouteRemovalAliases
        Invoke-ServiceApplyDryRun "edge_haproxy" $limit "edge_haproxy route removal on ${limit}"
        Write-Host "edge_haproxy route removal on ${limit}: apply queued"
        Invoke-ServiceRemote "edge_haproxy" "apply" $limit
        foreach ($alias in $edgeRouteRemovalAliases) {
            Add-UniqueAlias $processedServiceActions "edge_haproxy|present|$alias"
        }
        $summary.Add("edge_haproxy routes ${limit}: removed absent routes") | Out-Null
    }
}

$orderedServiceRows = @(
    @($serviceRows | Where-Object { $_.state -eq "present" -and $_.name -ne "edge_haproxy" })
    @($serviceRows | Where-Object { $_.state -eq "present" -and $_.name -eq "edge_haproxy" })
    @($serviceRows | Where-Object { $_.state -in @("absent", "purged") -and $_.name -ne "edge_haproxy" })
    @($serviceRows | Where-Object { $_.state -in @("absent", "purged") -and $_.name -eq "edge_haproxy" })
)

foreach ($serviceRow in $orderedServiceRows) {
    $service = $serviceRow.name
    if ($OnlyService -and $service -ne $OnlyService) {
        continue
    }
    $state = $serviceRow.state
    $aliases = @(Get-ServiceApplyAliases $serviceRow)
    $retiredAliases = @(Get-RetiredServiceAliases $serviceRow | Where-Object { $nodeAliases -contains $_ })
    if ($service -eq "vpn_cascade" -and $state -eq "present") {
        $aliases = @(Get-VpnCascadeOrderedAliases $aliases)
    }

    if ($state -notin @("present", "absent", "purged")) {
        Fail "$service state must be one of: present, absent, purged"
    }

    if ($ReservedServices -contains $service) {
        Write-Host "${service}: reserved/not implemented; skipped"
        $summary.Add("${service}: skipped reserved") | Out-Null
        continue
    }
    if ($SupportedServices -notcontains $service) {
        Write-Host "${service}: not implemented yet; skipped"
        $summary.Add("${service}: skipped not implemented") | Out-Null
        continue
    }

    Write-Host ""
    Write-Host "Service: $service"
    Write-Host "State:   $state"
    if ($plannedServices -notcontains $service) {
        Invoke-ServiceRemote $service "plan" ""
        Add-UniqueAlias $plannedServices $service
    }

    if ($aliases.Count -eq 0) {
        if ($state -eq "present") {
            Fail "$service has state=present but active_aliases is empty"
        }
        Write-Host "${service}: no active_aliases for state=$state; no-op"
        $summary.Add("${service}: no-op") | Out-Null
        continue
    }

    if ($aliases.Count -gt 0) {
        $limit = Join-AnsibleLimit $aliases
        foreach ($alias in $aliases) {
            $actionKey = "$service|$state|$alias"
            if ($processedServiceActions -contains $actionKey) {
                Write-Host "$service on ${alias}: duplicate state row for state=$state; skipped"
                continue
            }
            Add-UniqueAlias $processedServiceActions $actionKey
        }

        if ($state -eq "present") {
            Invoke-ServiceApplyDryRun $service $limit "$service on $limit"
            Write-Host "$service on ${limit}: apply queued"
            Invoke-ServiceRemote $service "apply" $limit
            Invoke-Postcheck $service $state $limit
            $summary.Add("$service ${limit}: present") | Out-Null
            if ($service -eq "vpn_edge") {
                foreach ($alias in @($aliases | Where-Object { $reseedVpnEdgeAliases -contains $_ })) {
                    Invoke-VpnEdgeReseed $alias $reseededVpnEdgeAliases $summary
                }
            }
            if ($retiredAliases.Count -gt 0) {
                $retiredLimit = Join-AnsibleLimit $retiredAliases
                foreach ($alias in $retiredAliases) {
                    $retiredActionKey = "$service|absent|$alias"
                    if ($processedServiceActions -contains $retiredActionKey) {
                        Write-Host "$service on retired alias ${alias}: absent already queued; skipped"
                        continue
                    }
                    Add-UniqueAlias $processedServiceActions $retiredActionKey
                }
                Write-Host "$service on retired aliases ${retiredLimit}: absent queued from old_aliases"
                Invoke-ServiceActionDryRun $service "absent" $retiredLimit "$service retired aliases ${retiredLimit}"
                Invoke-ServiceRemote $service "absent" $retiredLimit
                Invoke-Postcheck $service "absent" $retiredLimit
                $summary.Add("$service retired ${retiredLimit}: absent") | Out-Null
            }
        } elseif ($state -eq "absent") {
            Write-Host "$service on ${limit}: absent queued"
            Invoke-ServiceRemote $service "absent" $limit
            Invoke-Postcheck $service $state $limit
            $summary.Add("$service ${limit}: absent") | Out-Null
        } elseif ($state -eq "purged") {
            Write-Host "$service on ${limit}: purge queued"
            Invoke-ServiceRemote $service "purge" $limit -ConfirmPurge
            Invoke-Postcheck $service $state $limit
            $summary.Add("$service ${limit}: purged") | Out-Null
        }
        continue
    }

    foreach ($alias in $aliases) {
        $actionKey = "$service|$state|$alias"
        if ($processedServiceActions -contains $actionKey) {
            Write-Host "$service on ${alias}: duplicate state row for state=$state; skipped"
            continue
        }
        Add-UniqueAlias $processedServiceActions $actionKey

        if ($state -eq "present") {
            Invoke-ServiceApplyDryRun $service $alias "$service on ${alias}"
            Write-Host "$service on ${alias}: apply queued"
            Invoke-ServiceRemote $service "apply" $alias
            Invoke-Postcheck $service $state $alias
            $summary.Add("$service ${alias}: present") | Out-Null
            if ($service -eq "vpn_edge" -and ($reseedVpnEdgeAliases -contains $alias)) {
                Invoke-VpnEdgeReseed $alias $reseededVpnEdgeAliases $summary
            }
        } elseif ($state -eq "absent") {
            Write-Host "$service on ${alias}: absent queued"
            Invoke-ServiceRemote $service "absent" $alias
            Invoke-Postcheck $service $state $alias
            $summary.Add("$service ${alias}: absent") | Out-Null
        } elseif ($state -eq "purged") {
            Write-Host "$service on ${alias}: purge queued"
            Invoke-ServiceRemote $service "purge" $alias -ConfirmPurge
            Invoke-Postcheck $service $state $alias
            $summary.Add("$service ${alias}: purged") | Out-Null
        }
    }
}

if ($edgeRouteApplyAliases.Count -gt 0) {
    Write-Host ""
    Write-Host "Step 2b/3: apply edge route rendering through edge_haproxy"
    if ($OnlyService -and $OnlyService -ne "edge_haproxy") {
        Write-Host "Skipped edge route apply because -OnlyService $OnlyService was requested"
    } else {
        $routeApplyAliases = @($edgeRouteApplyAliases | Where-Object { $processedServiceActions -notcontains "edge_haproxy|present|$_" })
        if ($routeApplyAliases.Count -eq 0) {
            Write-Host "edge_haproxy routes: already applied by edge_haproxy service apply"
        } else {
            $limit = Join-AnsibleLimit $routeApplyAliases
            Invoke-ServiceApplyDryRun "edge_haproxy" $limit "edge_haproxy routes on ${limit}"
            Write-Host "edge_haproxy routes on ${limit}: apply queued"
            Invoke-ServiceRemote "edge_haproxy" "apply" $limit
            $summary.Add("edge_haproxy routes ${limit}: applied") | Out-Null
        }
    }
}

if (-not $OnlyService -or $OnlyService -eq "vpn_edge") {
    foreach ($alias in $reseedVpnEdgeAliases) {
        Invoke-VpnEdgeReseed $alias $reseededVpnEdgeAliases $summary
    }
} elseif ($reseedVpnEdgeAliases.Count -gt 0) {
    Write-Host "Skipped vpn_edge reseed because -OnlyService $OnlyService was requested"
}

Invoke-ServiceBatch

Write-Host ""
Write-Host "Step 3/3: summary"
foreach ($item in $summary) {
    Write-Host "  $item"
}
Write-Host "Rollout from state completed."
