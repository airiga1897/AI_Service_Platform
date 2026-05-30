param(
    [string]$PolicyFile = ".\operator\egress_policy\profiles.json",
    [string]$HistoryDir = ".\operator\egress_policy\history",
    [string]$HistoryFile = "",
    [string]$ProposalDir = ".\operator\egress_policy\proposals",
    [switch]$Latest = $true,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Read-JsonFile($Path, $Label) {
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        Fail "failed to parse ${Label}: $Path"
    }
}

function Get-HistoryFiles() {
    if ($HistoryFile) {
        if (-not (Test-Path -LiteralPath $HistoryFile -PathType Leaf)) {
            Fail "egress probe history file not found: $HistoryFile"
        }
        return @(Get-Item -LiteralPath $HistoryFile)
    }
    if (-not (Test-Path -LiteralPath $HistoryDir -PathType Container)) {
        Fail "egress probe history directory not found: $HistoryDir"
    }
    $files = @(Get-ChildItem -LiteralPath $HistoryDir -File -Filter "egress-probes-*.jsonl" | Sort-Object Name -Descending)
    if ($files.Count -eq 0) {
        Fail "no egress probe history files found in: $HistoryDir"
    }
    if ($Latest) {
        return @($files | Select-Object -First 1)
    }
    return $files
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
        "fallback_available" { return "Fallback доступен" }
        "fallback_unavailable" { return "Fallback недоступен" }
        "related_target_missing" { return "Связанный target не в policy" }
        "probe_error" { return "Ошибка проверки" }
        "unstable_probe" { return "Нестабильная проверка" }
        "route_review" { return "Нужно проверить вручную" }
        "egress_path_degraded" { return "Маршрут деградировал" }
        "strict_non_ru_violation" { return "Strict non-RU нарушен" }
        default { return [string]$Type }
    }
}

function Get-TargetKey($Target) {
    "$($Target.protocol)|$($Target.value)|$($Target.port)|$(if ($Target.path) { $Target.path } else { '/' })"
}

function Get-NormalizedTargetKey($Protocol, $Value, $Port, $Path) {
    "$Protocol|$Value|$Port|$(if ($Path) { $Path } else { '/' })"
}

function Get-DefaultPort($Protocol, $Port) {
    if ($Port -and [int]$Port -gt 0) {
        return [int]$Port
    }
    switch ([string]$Protocol) {
        "https" { return 443 }
        "http" { return 80 }
        "icmp" { return 0 }
        default { return [int]$Port }
    }
}

function Get-Observation($Record) {
    if ($Record.target_status) {
        return $Record.target_status
    }
    return $Record.observation
}

function Get-RelatedTargetFromRedirect($Record) {
    $target = $Record.target
    if (-not $target -or [string]$target.protocol -notin @("http", "https")) {
        return $null
    }
    $obs = Get-Observation $Record
    if (-not $obs -or [string]::IsNullOrWhiteSpace([string]$obs.http_final_url)) {
        return $null
    }
    try {
        $uri = [System.Uri]::new([string]$obs.http_final_url)
    } catch {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($uri.Host) -or $uri.Host -eq [string]$target.value) {
        return $null
    }
    $protocol = $uri.Scheme.ToLowerInvariant()
    if ($protocol -notin @("http", "https")) {
        return $null
    }
    $port = if ($uri.IsDefaultPort) { Get-DefaultPort $protocol 0 } else { [int]$uri.Port }
    return [pscustomobject]@{
        type = "domain"
        value = $uri.Host
        protocol = $protocol
        port = $port
        path = "/"
        original_target = $target
        final_url = [string]$obs.http_final_url
    }
}

function Get-Recommendation($Record) {
    $mode = Get-RecordPathMode $Record
    $obs = if ($Record.target_status) { $Record.target_status } else { $Record.observation }
    $protocol = if ($Record.target -and $Record.target.protocol) { [string]$Record.target.protocol } else { "" }
    $httpStatus = if ($obs) { $obs.http_status } else { $null }
    $desired = if ($Record.behavior) { [string]$Record.behavior } else { "fallback_on_ingress_egress_failure" }

    if ($mode -eq "cascade") {
        $transportOk = $Record.cascade_transport_status -and $Record.cascade_transport_status.reachable
        $connectionOk = $Record.cascade_connection_status -and $Record.cascade_connection_status.online
        if (-not $transportOk -and -not $connectionOk) {
            return "fallback_unavailable"
        }
    }

    if ($Record.status -eq "probe_error") {
        if ($mode -eq "cascade") {
            return "fallback_unavailable"
        }
        return "probe_error"
    }

    $targetOk = $false
    if ($protocol -in @("http", "https")) {
        $targetOk = ($null -ne $httpStatus -and $httpStatus -ge 200 -and $httpStatus -lt 400)
    } elseif ($protocol -eq "tcp") {
        $targetOk = ($obs -and $null -ne $obs.tcp_connect_ms)
    } elseif ($protocol -eq "icmp") {
        $targetOk = ($obs -and $null -ne $obs.icmp_ms)
    } elseif ($protocol -eq "udp") {
        return "route_review"
    }

    if ($targetOk) {
        if ($desired -eq "require_non_ru_egress") {
            $country = if ($Record.effective_country) { [string]$Record.effective_country } else { [string]$Record.observation.external_country }
            if ($country -eq "RU") {
                return "strict_non_ru_violation"
            }
        }
        if ($mode -eq "cascade") {
            return "fallback_available"
        }
        return "good_ingress_local"
    }

    return "review"
}

function Get-RecordPathMode($Record) {
    if ($Record.path_mode) {
        return [string]$Record.path_mode
    }
    return "direct"
}

function Get-ResponseMs($Record) {
    $obs = if ($Record.target_status) { $Record.target_status } else { $Record.observation }
    if (-not $obs) {
        return $null
    }
    if ($null -ne $obs.http_total_ms) {
        return $obs.http_total_ms
    }
    if ($null -ne $obs.tcp_connect_ms) {
        return $obs.tcp_connect_ms
    }
    if ($null -ne $obs.icmp_ms) {
        return $obs.icmp_ms
    }
    return $null
}

function ConvertTo-EvidenceObservation($Record) {
    $obs = if ($Record.target_status) { $Record.target_status } else { $Record.observation }
    [ordered]@{
        mode = if ($Record.path_mode) { $Record.path_mode } else { "direct" }
        ingress_alias = if ($Record.ingress_alias) { $Record.ingress_alias } else { $Record.candidate_alias }
        egress_alias = if ($Record.egress_alias) { $Record.egress_alias } else { $Record.candidate_alias }
        cascade_connection = $Record.cascade_connection
        effective_country = $Record.effective_country
        effective_ip = $Record.effective_ip
        http_status = if ($obs) { $obs.http_status } else { $null }
        tcp_connect_ms = if ($obs) { $obs.tcp_connect_ms } else { $null }
        icmp_ms = if ($obs) { $obs.icmp_ms } else { $null }
        response_ms = Get-ResponseMs $Record
        recommendation = Get-Recommendation $Record
        attempts_used = $Record.attempts_used
        attempts_total = $Record.attempts_total
    }
}

function ConvertTo-RecommendedPath($Record) {
    $obs = if ($Record.target_status) { $Record.target_status } else { $Record.observation }
    [ordered]@{
        mode = if ($Record.path_mode) { $Record.path_mode } else { "direct" }
        ingress_alias = if ($Record.ingress_alias) { $Record.ingress_alias } else { $Record.candidate_alias }
        egress_alias = if ($Record.egress_alias) { $Record.egress_alias } else { $Record.candidate_alias }
        cascade_connection = $Record.cascade_connection
        cascade_connections = if ($Record.cascade_connections) { @($Record.cascade_connections) } else { @($Record.cascade_connection | Where-Object { $_ }) }
        cascade_path = if ($Record.cascade_path) { @($Record.cascade_path) } else { @() }
        effective_country = $Record.effective_country
        http_status = if ($obs) { $obs.http_status } else { $null }
        tcp_connect_ms = if ($obs) { $obs.tcp_connect_ms } else { $null }
        icmp_ms = if ($obs) { $obs.icmp_ms } else { $null }
        response_ms = Get-ResponseMs $Record
    }
}

function Test-GoodRecommendation($Recommendation) {
    $Recommendation -in @("good_ingress_local", "fallback_available")
}

function Test-UnstableRecord($Record) {
    $obs = if ($Record.target_status) { $Record.target_status } else { $Record.observation }
    $attemptsUsed = if ($Record.attempts_used) { [int]$Record.attempts_used } elseif ($obs -and $obs.attempts_used) { [int]$obs.attempts_used } else { 1 }
    $retryErrors = @()
    if ($Record.retry_errors) {
        $retryErrors = @($Record.retry_errors)
    } elseif ($obs -and $obs.retry_errors) {
        $retryErrors = @($obs.retry_errors)
    }
    return ($attemptsUsed -gt 1 -or $retryErrors.Count -gt 0)
}

function Get-ProfileBehavior($Profile) {
    if ($Profile -and $Profile.behavior) {
        return [string]$Profile.behavior
    }
    return ""
}

function Get-ProfileFallbackEgressAliases($Profile) {
    if (-not $Profile -or $null -eq $Profile.candidate_fallback_egress_aliases) {
        return @()
    }
    return @($Profile.candidate_fallback_egress_aliases | Where-Object { $_ })
}

function Get-RecordHttpStatus($Record) {
    $obs = if ($Record.target_status) { $Record.target_status } else { $Record.observation }
    if (-not $obs) {
        return $null
    }
    return $obs.http_status
}

function Test-DirectRecordFailedAfterAttempts($Record) {
    $mode = if ($Record.path_mode) { [string]$Record.path_mode } else { "direct" }
    if ($mode -ne "direct") {
        return $false
    }
    if ((Get-Recommendation $Record) -eq "good_ingress_local") {
        return $false
    }

    $target = $Record.target
    $obs = if ($Record.target_status) { $Record.target_status } else { $Record.observation }
    $attemptsUsed = if ($Record.attempts_used) { [int]$Record.attempts_used } elseif ($obs -and $obs.attempts_used) { [int]$obs.attempts_used } else { 1 }
    $attemptsTotal = if ($Record.attempts_total) { [int]$Record.attempts_total } elseif ($obs -and $obs.attempts_total) { [int]$obs.attempts_total } else { 1 }

    if ($target.protocol -in @("http", "https")) {
        $httpStatus = Get-RecordHttpStatus $Record
        if ($null -ne $httpStatus) {
            return $false
        }
        return ($Record.status -eq "probe_error" -or $attemptsUsed -ge $attemptsTotal)
    }

    if ($target.protocol -eq "tcp") {
        if ($obs -and $null -ne $obs.tcp_connect_ms) {
            return $false
        }
        return ($Record.status -eq "probe_error" -or $attemptsUsed -ge $attemptsTotal)
    }
    if ($target.protocol -eq "icmp") {
        if ($obs -and $null -ne $obs.icmp_ms) {
            return $false
        }
        return ($Record.status -eq "probe_error" -or $attemptsUsed -ge $attemptsTotal)
    }

    return $false
}

function Test-DeterministicFallbackAutoAccept($Profile, $Records, $BestRecord, [bool]$TargetKnown) {
    if (-not $TargetKnown -or -not $Profile) {
        return $false
    }
    if ((Get-ProfileBehavior $Profile) -ne "fallback_on_ingress_egress_failure") {
        return $false
    }

    $configuredFallbackEgressAliases = @(Get-ProfileFallbackEgressAliases $Profile)
    if ($configuredFallbackEgressAliases.Count -eq 0) {
        return $false
    }

    $directRecords = @($Records | Where-Object { (Get-RecordPathMode $_) -eq "direct" })
    if ($directRecords.Count -eq 0) {
        return $false
    }
    if (@($directRecords | Where-Object { (Get-Recommendation $_) -eq "good_ingress_local" }).Count -gt 0) {
        return $false
    }
    if (@($directRecords | Where-Object { -not (Test-DirectRecordFailedAfterAttempts $_) }).Count -gt 0) {
        return $false
    }

    $usableCascadeRecords = @($Records | Where-Object {
        (Get-RecordPathMode $_) -eq "cascade" -and
        (Get-Recommendation $_) -eq "fallback_available"
    })
    if ($usableCascadeRecords.Count -ne 1) {
        return $false
    }
    if ($configuredFallbackEgressAliases -notcontains [string]$usableCascadeRecords[0].egress_alias) {
        return $false
    }
    if (-not $BestRecord -or [string]$BestRecord.egress_alias -ne [string]$usableCascadeRecords[0].egress_alias) {
        return $false
    }

    return $true
}

function Get-IssueType($Records, $BestRecord, [bool]$TargetKnown) {
    if (-not $TargetKnown) {
        return "policy_profile_candidate"
    }

    $directRecords = @($Records | Where-Object { (Get-RecordPathMode $_) -eq "direct" })
    $directGoodRecords = @($directRecords | Where-Object { (Get-Recommendation $_) -eq "good_ingress_local" })
    if ($directRecords.Count -eq 0) {
        return $null
    }
    if ($directGoodRecords.Count -gt 0) {
        if (@($directGoodRecords | Where-Object { Test-UnstableRecord $_ }).Count -gt 0) {
            return "unstable_probe"
        }
        return $null
    }

    if ($BestRecord -and (Get-Recommendation $BestRecord) -eq "fallback_available") {
        return "fallback_available"
    }

    if ($BestRecord -and (Test-UnstableRecord $BestRecord)) {
        return "unstable_probe"
    }

    if ($BestRecord) {
        return $null
    }

    $recommendations = @($Records | ForEach-Object { Get-Recommendation $_ })
    foreach ($candidate in @("fallback_unavailable", "probe_error", "strict_non_ru_violation", "review")) {
        if ($recommendations -contains $candidate) {
            if ($candidate -eq "review") {
                return "route_review"
            }
            return $candidate
        }
    }
    return "egress_path_degraded"
}

function Get-ProposalReason($Type) {
    switch ([string]$Type) {
        "policy_profile_candidate" { return "Observed target is not covered by the active policy registry; operator should decide whether to add it to an existing grouped profile or create a new profile." }
        "fallback_available" { return "Ingress-local egress did not produce a good stable result, and a cascade fallback candidate is available for operator review." }
        "fallback_unavailable" { return "Ingress-local egress did not produce a good stable result, and no usable cascade fallback was confirmed in the selected probe history." }
        "related_target_missing" { return "HTTP probe followed a redirect to a related host that is not covered by this profile. Add the host explicitly if it should share this fallback intent." }
        "probe_error" { return "Probe failed without a usable successful observation; operator should review the target, network path, or retry later." }
        "unstable_probe" { return "Probe eventually found a usable path, but retries or transient errors were observed; operator should decide whether this is acceptable." }
        "route_review" { return "Probe result was inconclusive; operator should review the evidence before approving any future selective fallback routing." }
        "strict_non_ru_violation" { return "Strict non-RU behavior was requested, but the observed egress country was RU." }
        default { return "Existing profile has no usable observed path in the latest selected probe history; operator should review route health before selective fallback routing." }
    }
}

function Get-HumanSummary($Type) {
    switch ([string]$Type) {
        "policy_profile_candidate" { return "Цель не покрыта текущей policy. Решите, добавлять ли ее в существующий профиль или создать отдельный." }
        "fallback_available" { return "Локальный egress не дал хорошего результата, но fallback через cascade доступен." }
        "fallback_unavailable" { return "Локальный egress не дал хорошего результата, и рабочий fallback не найден." }
        "related_target_missing" { return "Проверка увидела редирект на связанный host, которого нет в профиле. Добавьте его явно, если он должен идти тем же fallback." }
        "probe_error" { return "Проверка не дала успешного результата. Лучше повторить или разобрать ошибку." }
        "unstable_probe" { return "Маршрут сработал только после повторов или с ошибками. Нужна оценка стабильности." }
        "route_review" { return "Результат неоднозначный. Нужен ручной просмотр evidence." }
        "strict_non_ru_violation" { return "Для strict non-RU результата обнаружен RU egress." }
        default { return "Для этого target нет однозначно хорошего результата." }
    }
}

function New-Proposal($Type, $Profile, $Target, $Records, $BestRecord, $HistoryFilePath, [bool]$AutoAccepted = $false) {
    $runId = if ($BestRecord -and $BestRecord.run_id) { $BestRecord.run_id } elseif ($Records.Count -gt 0) { $Records[0].run_id } else { [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ") }
    $targetPart = ConvertTo-SafeIdPart "$($Target.value)-$($Target.port)"
    $profilePart = ConvertTo-SafeIdPart $(if ($Profile) { $Profile } else { "unknown-profile" })
    $id = "$(ConvertTo-SafeIdPart $Type)-$profilePart-$targetPart"

    $goodRecords = @($Records | Where-Object { Test-GoodRecommendation (Get-Recommendation $_) })
    $observations = @($Records | Sort-Object @{ Expression = { if (Test-GoodRecommendation (Get-Recommendation $_)) { 0 } else { 1 } } }, @{ Expression = { $ms = Get-ResponseMs $_; if ($null -eq $ms) { [double]::MaxValue } else { [double]$ms } } } | Select-Object -First 5 | ForEach-Object { ConvertTo-EvidenceObservation $_ })
    $summary = if ($goodRecords.Count -gt 0) {
        "A usable path was observed, but this target still needs operator review because it is uncovered or unstable."
    } else {
        "No unambiguously good path was found for this target in the selected probe history."
    }

    $status = if ($AutoAccepted) { "accepted" } else { "suggested" }
    $proposal = [ordered]@{
        schema_version = 1
        id = $id
        type = $Type
        human_type = Get-HumanType $Type
        status = $status
        human_status = Get-HumanStatus $status
        created_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        source = "deterministic_probe"
        generator = "suggest_egress_policy.ps1"
        profile = $Profile
        target = $Target
        recommended_path = if ($BestRecord) { ConvertTo-RecommendedPath $BestRecord } else { $null }
        reason = Get-ProposalReason $Type
        human_summary = Get-HumanSummary $Type
        rollback = "This is proposal-only state. Delete or reject this proposal; no runtime route exists until an operator applies a separate approved policy."
        evidence = [ordered]@{
            source_history_file = $HistoryFilePath
            run_id = $runId
            summary = $summary
            observations = $observations
        }
        ai_advisory = $null
    }

    if ($AutoAccepted) {
        $proposal["operator_decision"] = [ordered]@{
            status = "accepted"
            human_status = Get-HumanStatus "accepted"
            previous_status = "suggested"
            previous_human_status = Get-HumanStatus "suggested"
            reason = "Deterministic fallback: ingress-local probe failed or degraded after all attempts, and the configured cascade fallback succeeded."
            operator = "auto:deterministic-fallback"
            decided_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }

    return $proposal
}

if (-not (Test-Path -LiteralPath $PolicyFile -PathType Leaf)) {
    Fail "egress policy registry not found: $PolicyFile"
}

$policy = Read-JsonFile $PolicyFile "egress policy registry"
$knownProfiles = @{}
$knownTargets = @{}
$knownTargetsByProfile = @{}
foreach ($profile in @($policy.profiles)) {
    $knownProfiles[[string]$profile.name] = $profile
    $profileTargetKeys = @{}
    foreach ($target in @($profile.targets)) {
        $key = Get-TargetKey $target
        $knownTargets[$key] = $true
        $profileTargetKeys[$key] = $true
    }
    $knownTargetsByProfile[[string]$profile.name] = $profileTargetKeys
}

if ($knownTargets.Count -eq 0) {
    Write-Host "No active egress policy targets; no proposals generated."
    exit 0
}

$recordsByGroup = @{}
foreach ($file in Get-HistoryFiles) {
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        $lineNumber += 1
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $record = $line | ConvertFrom-Json
        } catch {
            Fail "failed to parse JSONL record $($file.FullName):$lineNumber"
        }
        $targetKey = Get-TargetKey $record.target
        $groupKey = "$($record.profile)|$targetKey|$($file.FullName)"
        if (-not $recordsByGroup.ContainsKey($groupKey)) {
            $recordsByGroup[$groupKey] = New-Object System.Collections.ArrayList
        }
        $record | Add-Member -NotePropertyName source_history_file -NotePropertyValue $file.FullName -Force
        [void]$recordsByGroup[$groupKey].Add($record)
    }
}

$proposals = New-Object System.Collections.ArrayList
$proposalIds = @{}
foreach ($groupKey in $recordsByGroup.Keys) {
    $records = @($recordsByGroup[$groupKey].ToArray())
    if ($records.Count -eq 0) {
        continue
    }
    $first = $records[0]
    $targetKey = Get-TargetKey $first.target
    $targetKnown = $knownTargets.ContainsKey($targetKey)
    $profileConfig = if ($knownProfiles.ContainsKey([string]$first.profile)) { $knownProfiles[[string]$first.profile] } else { $null }

    $bestRecords = @($records |
        Where-Object { Test-GoodRecommendation (Get-Recommendation $_) } |
        Sort-Object @{ Expression = { if ($_.path_mode -eq "cascade") { 0 } else { 1 } } }, @{ Expression = { $ms = Get-ResponseMs $_; if ($null -eq $ms) { [double]::MaxValue } else { [double]$ms } } } |
        Select-Object -First 1)
    $bestRecord = if ($bestRecords.Count -gt 0) { $bestRecords[0] } else { $null }

    $issueType = Get-IssueType $records $bestRecord $targetKnown
    if ($issueType) {
        $autoAccepted = $issueType -eq "fallback_available" -and (Test-DeterministicFallbackAutoAccept $profileConfig $records $bestRecord $targetKnown)
        $proposal = New-Proposal $issueType $first.profile $first.target $records $bestRecord $first.source_history_file $autoAccepted
        if (-not $proposalIds.ContainsKey($proposal.id)) {
            $proposalIds[$proposal.id] = $true
            [void]$proposals.Add($proposal)
        }
    }

    $profileTargetKeys = if ($knownTargetsByProfile.ContainsKey([string]$first.profile)) { $knownTargetsByProfile[[string]$first.profile] } else { @{} }
    foreach ($record in $records) {
        $relatedTarget = Get-RelatedTargetFromRedirect $record
        if (-not $relatedTarget) {
            continue
        }
        $relatedKey = Get-NormalizedTargetKey $relatedTarget.protocol $relatedTarget.value $relatedTarget.port $relatedTarget.path
        if ($profileTargetKeys.ContainsKey($relatedKey)) {
            continue
        }
        $proposal = New-Proposal "related_target_missing" $first.profile ([pscustomobject]@{
            type = $relatedTarget.type
            value = $relatedTarget.value
            protocol = $relatedTarget.protocol
            port = $relatedTarget.port
            path = $relatedTarget.path
        }) $records $record $first.source_history_file $false
        $proposal.reason = "HTTP probe for $($first.target.value) followed a redirect to $($relatedTarget.final_url), but $($relatedTarget.value) is not an explicit target in profile $($first.profile)."
        $proposal.human_summary = "Добавьте $($relatedTarget.value) в targets профиля $($first.profile), если этот host должен использовать тот же fallback."
        if (-not $proposalIds.ContainsKey($proposal.id)) {
            $proposalIds[$proposal.id] = $true
            [void]$proposals.Add($proposal)
        }
    }
}

if ($proposals.Count -eq 0) {
    Write-Host "No egress policy proposals generated."
    exit 0
}

$rows = @($proposals.ToArray() | ForEach-Object {
    [pscustomobject]@{
        id = $_.id
        status = $_.human_status
        issue = $_.human_type
        target = "$($_.target.value):$($_.target.port)"
        recommended_path = if ($_.recommended_path) {
            if ($_.recommended_path.mode -eq "cascade") {
                "$($_.recommended_path.ingress_alias)->$($_.recommended_path.egress_alias)"
            } else {
                "$($_.recommended_path.mode):$($_.recommended_path.egress_alias)"
            }
        } else {
            $null
        }
        country = if ($_.recommended_path) { $_.recommended_path.effective_country } else { $null }
        http = if ($_.recommended_path) { $_.recommended_path.http_status } else { $null }
        response_ms = if ($_.recommended_path) { $_.recommended_path.response_ms } else { $null }
        internal_type = $_.type
    }
})

if ($DryRun) {
    $rows | Format-Table -AutoSize
    Write-Host "Dry-run completed. No proposal files were written."
    exit 0
}

New-Item -ItemType Directory -Force -Path $ProposalDir | Out-Null
foreach ($proposal in @($proposals.ToArray())) {
    $path = Join-Path $ProposalDir "$($proposal.id).json"
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and -not $Force) {
        $existingProposal = Read-JsonFile $path "existing proposal"
        if ($existingProposal.status -in @("rejected", "ignored")) {
            Write-Host "Skipping existing manually decided proposal: $path"
            continue
        }
        if ($existingProposal.status -ne "suggested" -or $proposal.status -ne "accepted") {
            Write-Host "Skipping existing proposal for the same profile/target/issue: $path"
            continue
        }
        Write-Host "Updating existing suggested proposal to accepted: $path"
    }
    $proposal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
    Write-Host "[OK] Proposal written: $path"
}
