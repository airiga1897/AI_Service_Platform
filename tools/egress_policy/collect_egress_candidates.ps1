param(
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$StateFile = ".\operator\state.csv",
    [string]$CandidateDir = ".\operator\egress_policy\candidates",
    [string]$ProposalDir = ".\operator\egress_policy\proposals",
    [string]$RemoteCandidateDir = "/var/lib/ai-service-platform/edge_candidate_collector/candidates",
    [string]$AdminUser = "useradmin",
    [string]$IngressAlias = "",
    [switch]$AllAliases,
    [switch]$SkipRemoteFetch,
    [switch]$DryRun,
    [switch]$ReplaceSuggested,
    [switch]$ArchiveRemoteAfterFetch,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,connection,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$script:FetchedRemoteAliases = New-Object System.Collections.Generic.HashSet[string]

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
    if (-not $Value) {
        return @()
    }
    return @($Value -split "\+" | Where-Object { $_ })
}

function ConvertTo-SafeIdPart($Value) {
    $text = ([string]$Value).ToLowerInvariant()
    $text = $text -replace '[^a-z0-9]+', '-'
    $text = $text.Trim('-')
    if (-not $text) {
        return "unknown"
    }
    return $text
}

function Quote-BashArg($Value) {
    $text = [string]$Value
    return "'" + ($text -replace "'", "'\''") + "'"
}

function Read-JsonFile($Path, $Label) {
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        Fail "failed to parse ${Label}: $Path"
    }
}

function Get-HumanStatus($Status) {
    switch ([string]$Status) {
        "suggested" { return "Требует решения" }
        "accepted" { return "Принято" }
        "rejected" { return "Отклонено" }
        "ignored" { return "Отложено" }
        "stale" { return "Устарело" }
        default { return [string]$Status }
    }
}

function Get-HumanType($Type) {
    switch ([string]$Type) {
        "policy_profile_candidate" { return "Новый target вне policy" }
        "fallback_unavailable" { return "Fallback недоступен" }
        "probe_error" { return "Ошибка проверки" }
        "route_review" { return "Нужно проверить вручную" }
        "egress_path_degraded" { return "Маршрут деградировал" }
        default { return [string]$Type }
    }
}

function Get-ProposalType($CandidateType) {
    switch ([string]$CandidateType) {
        "missing_route" { return "policy_profile_candidate" }
        "egress_candidate" { return "route_review" }
        "fallback_probe_error" { return "probe_error" }
        "route_review" { return "route_review" }
        default { return "route_review" }
    }
}

function Get-ProposalReason($Candidate) {
    switch ([string]$Candidate.candidate_type) {
        "missing_route" { return "Edge collector observed rejected or failed traffic for this target. Operator should decide whether to add it to policy and/or route lifecycle." }
        "egress_candidate" { return "Edge collector observed cascade or transport symptoms that may need a selective fallback target review." }
        "fallback_probe_error" { return "Edge collector observed fallback probe errors. Operator should inspect readiness before approving route or NAT changes." }
        default { return "Edge collector observed route symptoms. This proposal is advisory only until operator approval." }
    }
}

function Get-HumanSummary($Candidate) {
    switch ([string]$Candidate.candidate_type) {
        "missing_route" { return "Collector увидел target, который может требовать policy/route решения. Runtime не менялся." }
        "egress_candidate" { return "Collector увидел cascade/egress симптом. Нужна ручная проверка маршрута." }
        "fallback_probe_error" { return "Collector увидел ошибку fallback probe. Сначала проверьте readiness." }
        default { return "Collector предлагает target к ручному review. Применения маршрута не было." }
    }
}

function New-ProposalFromCandidate($Candidate) {
    $target = $Candidate.target
    $type = Get-ProposalType $Candidate.candidate_type
    $id = "edge-candidate-{0}-{1}-{2}-{3}-{4}" -f `
        (ConvertTo-SafeIdPart $Candidate.source_alias),
        (ConvertTo-SafeIdPart $Candidate.source),
        (ConvertTo-SafeIdPart $Candidate.candidate_type),
        (ConvertTo-SafeIdPart $target.value),
        (ConvertTo-SafeIdPart $target.port)

    [ordered]@{
        schema_version = 1
        id = $id
        type = $type
        human_type = Get-HumanType $type
        status = "suggested"
        human_status = Get-HumanStatus "suggested"
        created_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        source = "edge_candidate_collector"
        generator = "collect_egress_candidates.ps1"
        profile = $null
        target = [ordered]@{
            type = [string]$target.type
            value = [string]$target.value
            protocol = [string]$target.protocol
            port = [int]$target.port
            path = if ($target.path) { [string]$target.path } else { "/" }
        }
        recommended_path = [ordered]@{
            mode = "review"
            ingress_alias = [string]$Candidate.source_alias
            egress_alias = $null
            cascade_connection = $null
            cascade_connections = @()
            cascade_path = @()
            effective_country = $null
            http_status = $null
            tcp_connect_ms = $null
            icmp_ms = $null
            response_ms = $null
        }
        reason = Get-ProposalReason $Candidate
        human_summary = Get-HumanSummary $Candidate
        rollback = "This is proposal-only state from edge_candidate_collector. No route, NAT, firewall, HAProxy, or SoftEther runtime change exists until a separate approved apply step is run."
        evidence = [ordered]@{
            source_history_file = if ($Candidate.source_file) { [string]$Candidate.source_file } else { $null }
            run_id = if ($Candidate.observed_at_utc) { [string]$Candidate.observed_at_utc } else { [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ") }
            summary = if ($Candidate.evidence -and $Candidate.evidence.summary) { [string]$Candidate.evidence.summary } else { "Edge collector observed candidate traffic symptoms." }
            observations = @(
                [ordered]@{
                    mode = "collector"
                    ingress_alias = [string]$Candidate.source_alias
                    egress_alias = $null
                    cascade_connection = $null
                    effective_country = $null
                    effective_ip = $null
                    http_status = $null
                    tcp_connect_ms = $null
                    icmp_ms = $null
                    response_ms = $null
                    recommendation = [string]$Candidate.candidate_type
                    source = [string]$Candidate.source
                    count = if ($Candidate.evidence -and $null -ne $Candidate.evidence.count) { [int]$Candidate.evidence.count } else { 1 }
                    sample_window = if ($Candidate.evidence -and $Candidate.evidence.sample_window) { [string]$Candidate.evidence.sample_window } else { "" }
                }
            )
        }
        ai_advisory = $null
    }
}

function Get-CollectorAliases($StateRows) {
    $rows = @($StateRows | Where-Object { $_.kind -eq "service" -and $_.name -eq "edge_candidate_collector" -and $_.state -eq "present" })
    $aliases = New-Object System.Collections.ArrayList
    foreach ($row in $rows) {
        foreach ($alias in Split-AliasList $row.active_aliases) {
            if ($aliases -notcontains $alias) {
                [void]$aliases.Add($alias)
            }
        }
    }
    return @($aliases.ToArray())
}

function Get-RemoteCollectorDirs() {
    $candidate = $RemoteCandidateDir.TrimEnd("/")
    $root = Split-Path -Parent $candidate
    if (-not $root) {
        $root = "/var/lib/ai-service-platform/edge_candidate_collector"
    }
    return [pscustomobject]@{
        Candidate = $candidate
        Processed = (($root.TrimEnd("/")) + "/processed")
    }
}

function Invoke-SshBestEffort($Alias, $Node, $Command, $Label) {
    $keyPath = Join-Path (Split-Path -Parent $StateFile) (Join-Path $Alias "admin_key")
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
        Write-Host "Skipping ${Label} for ${Alias}: admin key not found: $keyPath"
        return $false
    }
    $remote = "{0}@{1}" -f $AdminUser, $Node.endpoint
    $args = @("-i", $keyPath, "-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR", $remote, $Command)
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & ssh @args
        if ($LASTEXITCODE -ne 0) {
            Write-Host "${Label} for ${Alias} returned exit code $LASTEXITCODE."
            return $false
        }
    } catch {
        Write-Host "${Label} for ${Alias} failed: $($_.Exception.Message)"
        return $false
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    return $true
}

function Fetch-RemoteCandidates($Alias, $Node) {
    $keyPath = Join-Path (Split-Path -Parent $StateFile) (Join-Path $Alias "admin_key")
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
        Write-Host "Skipping remote candidate fetch for ${Alias}: admin key not found: $keyPath"
        return
    }
    $aliasDir = Join-Path $CandidateDir $Alias
    New-Item -ItemType Directory -Force -Path $aliasDir | Out-Null
    $dirs = Get-RemoteCollectorDirs
    $candidatePath = Quote-BashArg $dirs.Candidate
    $probeCommand = "sudo find $candidatePath -maxdepth 1 -type f -name '*.jsonl' -size +0c -print -quit | grep -q ."
    $remoteHasFiles = Invoke-SshBestEffort $Alias $Node $probeCommand "remote candidate probe"
    if (-not $remoteHasFiles) {
        Write-Host "No remote candidate files found for ${Alias}; continuing with local candidate cache."
        return
    }
    $remote = "{0}@{1}" -f $AdminUser, $Node.endpoint
    $localPath = Join-Path $aliasDir ("{0}-remote-candidates.jsonl" -f $Alias)
    $fetchInner = "find $candidatePath -maxdepth 1 -type f -name '*.jsonl' -size +0c -print0 | sort -z | xargs -0 -r cat"
    $fetchCommand = "sudo bash -lc $(Quote-BashArg $fetchInner)"
    $args = @("-i", $keyPath, "-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR", $remote, $fetchCommand)
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & ssh @args | Set-Content -LiteralPath $localPath -Encoding utf8
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $localPath -PathType Leaf) -or (Get-Item -LiteralPath $localPath).Length -eq 0) {
        Write-Host "Remote candidate fetch for ${Alias} returned exit code $LASTEXITCODE; continuing with local candidate cache."
        Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
        return
    }
    [void]$script:FetchedRemoteAliases.Add([string]$Alias)
}

function Archive-RemoteCandidates($Alias, $Node) {
    if (-not $script:FetchedRemoteAliases.Contains([string]$Alias)) {
        Write-Host "Skipping remote candidate archive for ${Alias}: no successful remote fetch in this run."
        return
    }
    $dirs = Get-RemoteCollectorDirs
    $candidatePath = Quote-BashArg $dirs.Candidate
    $processedPath = Quote-BashArg $dirs.Processed
    $archiveInner = "mkdir -p $processedPath; find $candidatePath -maxdepth 1 -type f -name '*.jsonl' -exec mv -t $processedPath -- {} +"
    $command = @(
        "set -e",
        "sudo bash -lc $(Quote-BashArg $archiveInner)"
    ) -join "; "
    [void](Invoke-SshBestEffort $Alias $Node $command "remote candidate archive")
}

if ($AllAliases -and $IngressAlias) {
    Fail "Use either -AllAliases or -IngressAlias, not both."
}
if (-not $AllAliases -and -not $IngressAlias) {
    Fail "Specify -AllAliases or -IngressAlias ALIAS."
}

Require-File $NodesFile "NodesFile"
Require-File $StateFile "StateFile"

if ((Get-Content -LiteralPath $NodesFile -TotalCount 1) -ne $ExpectedNodesHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedNodesHeader"
}
if ((Get-Content -LiteralPath $StateFile -TotalCount 1) -ne $ExpectedStateHeader) {
    Fail "state.csv header must be exactly: $ExpectedStateHeader"
}

$nodes = @(Import-Csv -LiteralPath $NodesFile)
$nodesByAlias = @{}
foreach ($node in $nodes) {
    $nodesByAlias[[string]$node.current_alias] = $node
}
$stateRows = @(Import-Csv -LiteralPath $StateFile)
$aliases = if ($AllAliases) { @(Get-CollectorAliases $stateRows) } else { @($IngressAlias) }
if ($aliases.Count -eq 0) {
    Fail "No present edge_candidate_collector aliases found in $StateFile"
}

if (-not $SkipRemoteFetch) {
    foreach ($alias in $aliases) {
        if (-not $nodesByAlias.ContainsKey($alias)) {
            Write-Host "Skipping remote candidate fetch for ${alias}: alias not found in nodes.csv"
            continue
        }
        Fetch-RemoteCandidates $alias $nodesByAlias[$alias]
    }
}

$candidateFiles = @()
foreach ($alias in $aliases) {
    $aliasDir = Join-Path $CandidateDir $alias
    if (Test-Path -LiteralPath $aliasDir -PathType Container) {
        $candidateFiles += @(Get-ChildItem -LiteralPath $aliasDir -File -Filter "*.jsonl")
    }
    if (Test-Path -LiteralPath $CandidateDir -PathType Container) {
        $candidateFiles += @(Get-ChildItem -LiteralPath $CandidateDir -File -Filter "${alias}*.jsonl")
    }
}

$candidatesByKey = @{}
foreach ($file in @($candidateFiles | Sort-Object FullName -Unique)) {
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        $lineNumber += 1
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $candidate = $line | ConvertFrom-Json
        } catch {
            Fail "failed to parse candidate JSONL record $($file.FullName):$lineNumber"
        }
        if ([int]$candidate.schema_version -ne 1 -or -not $candidate.target) {
            Fail "invalid candidate schema in $($file.FullName):$lineNumber"
        }
        if ($aliases -notcontains [string]$candidate.source_alias) {
            continue
        }
        $candidate | Add-Member -NotePropertyName source_file -NotePropertyValue $file.FullName -Force
        $key = "{0}|{1}|{2}|{3}|{4}|{5}|{6}" -f `
            $candidate.source_alias,
            $candidate.source,
            $candidate.candidate_type,
            $candidate.target.type,
            $candidate.target.value,
            $candidate.target.protocol,
            $candidate.target.port
        if (-not $candidatesByKey.ContainsKey($key)) {
            $candidatesByKey[$key] = $candidate
        } else {
            $current = $candidatesByKey[$key]
            if ($current.evidence -and $candidate.evidence) {
                $current.evidence.count = [int]$current.evidence.count + [int]$candidate.evidence.count
            }
        }
    }
}

$proposals = @($candidatesByKey.Values | ForEach-Object { New-ProposalFromCandidate $_ })
if ($Json) {
    $proposals | ConvertTo-Json -Depth 20
}

if ($proposals.Count -eq 0) {
    Write-Host "No edge candidate proposals generated."
    if ($ArchiveRemoteAfterFetch -and -not $DryRun -and -not $SkipRemoteFetch) {
        foreach ($alias in $aliases) {
            if ($nodesByAlias.ContainsKey($alias)) {
                Archive-RemoteCandidates $alias $nodesByAlias[$alias]
            }
        }
    }
    exit 0
}

if ($DryRun) {
    $proposals |
        ForEach-Object {
            [pscustomobject]@{
                id = $_.id
                status = $_.human_status
                issue = $_.human_type
                target = "$($_.target.value):$($_.target.port)"
                source = $_.source
                ingress_alias = $_.recommended_path.ingress_alias
                internal_type = $_.type
            }
        } |
        Format-Table -AutoSize
    Write-Host "Dry-run completed. No proposal files were written."
    exit 0
}

New-Item -ItemType Directory -Force -Path $ProposalDir | Out-Null
foreach ($proposal in $proposals) {
    $path = Join-Path $ProposalDir "$($proposal.id).json"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $existing = Read-JsonFile $path "existing proposal"
        if ($existing.operator_decision -or [string]$existing.status -ne "suggested") {
            Write-Host "Skipping existing manually decided proposal: $path"
            continue
        }
        if (-not $ReplaceSuggested) {
            Write-Host "Skipping existing suggested proposal: $path"
            continue
        }
    }
    $proposal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
    Write-Host "[OK] Proposal written: $path"
}

if ($ArchiveRemoteAfterFetch -and -not $SkipRemoteFetch) {
    foreach ($alias in $aliases) {
        if ($nodesByAlias.ContainsKey($alias)) {
            Archive-RemoteCandidates $alias $nodesByAlias[$alias]
        }
    }
}
