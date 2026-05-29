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

function Get-Recommendation($Record) {
    $mode = if ($Record.path_mode) { [string]$Record.path_mode } else { "direct" }
    $httpStatus = if ($Record.target_status) { $Record.target_status.http_status } else { $Record.observation.http_status }
    $desired = if ($Record.desired_region_behavior) { [string]$Record.desired_region_behavior } else { "fallback_on_ingress_egress_failure" }

    if ($mode -eq "cascade") {
        $transportOk = $Record.cascade_transport_status -and $Record.cascade_transport_status.reachable
        $connectionOk = $Record.cascade_connection_status -and $Record.cascade_connection_status.online
        if (-not $transportOk -or -not $connectionOk) {
            return "fallback_unavailable"
        }
    }

    if ($Record.status -eq "probe_error") {
        if ($mode -eq "cascade") {
            return "fallback_unavailable"
        }
        return "probe_error"
    }

    if ($httpStatus -ge 200 -and $httpStatus -lt 400) {
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
        effective_country = $Record.effective_country
        http_status = if ($obs) { $obs.http_status } else { $null }
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

function Get-IssueType($Records, $BestRecord, [bool]$TargetKnown) {
    if (-not $TargetKnown) {
        return "policy_profile_candidate"
    }

    $directRecords = @($Records | Where-Object { (if ($_.path_mode) { [string]$_.path_mode } else { "direct" }) -eq "direct" })
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
        "probe_error" { return "Probe failed without a usable successful observation; operator should review the target, network path, or retry later." }
        "unstable_probe" { return "Probe eventually found a usable path, but retries or transient errors were observed; operator should decide whether this is acceptable." }
        "route_review" { return "Probe result was inconclusive; operator should review the evidence before approving any future enforcement." }
        "strict_non_ru_violation" { return "Strict non-RU behavior was requested, but the observed egress country was RU." }
        default { return "Existing profile has no usable observed path in the latest selected probe history; operator should review route health before enforcement." }
    }
}

function Get-HumanSummary($Type) {
    switch ([string]$Type) {
        "policy_profile_candidate" { return "Цель не покрыта текущей policy. Решите, добавлять ли ее в существующий профиль или создать отдельный." }
        "fallback_available" { return "Локальный egress не дал хорошего результата, но fallback через cascade доступен." }
        "fallback_unavailable" { return "Локальный egress не дал хорошего результата, и рабочий fallback не найден." }
        "probe_error" { return "Проверка не дала успешного результата. Лучше повторить или разобрать ошибку." }
        "unstable_probe" { return "Маршрут сработал только после повторов или с ошибками. Нужна оценка стабильности." }
        "route_review" { return "Результат неоднозначный. Нужен ручной просмотр evidence." }
        "strict_non_ru_violation" { return "Для strict non-RU результата обнаружен RU egress." }
        default { return "Для этого target нет однозначно хорошего результата." }
    }
}

function New-Proposal($Type, $Profile, $Target, $Records, $BestRecord, $HistoryFilePath) {
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

    [ordered]@{
        schema_version = 1
        id = $id
        type = $Type
        human_type = Get-HumanType $Type
        status = "suggested"
        human_status = Get-HumanStatus "suggested"
        created_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        source = "suggest_egress_policy.ps1"
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
}

if (-not (Test-Path -LiteralPath $PolicyFile -PathType Leaf)) {
    Fail "egress policy registry not found: $PolicyFile"
}

$policy = Read-JsonFile $PolicyFile "egress policy registry"
$knownProfiles = @{}
$knownTargets = @{}
foreach ($profile in @($policy.profiles)) {
    $knownProfiles[[string]$profile.name] = $true
    foreach ($target in @($profile.targets)) {
        $knownTargets[(Get-TargetKey $target)] = $true
    }
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

    $bestRecords = @($records |
        Where-Object { Test-GoodRecommendation (Get-Recommendation $_) } |
        Sort-Object @{ Expression = { if ($_.path_mode -eq "cascade") { 0 } else { 1 } } }, @{ Expression = { $ms = Get-ResponseMs $_; if ($null -eq $ms) { [double]::MaxValue } else { [double]$ms } } } |
        Select-Object -First 1)
    $bestRecord = if ($bestRecords.Count -gt 0) { $bestRecords[0] } else { $null }

    $issueType = Get-IssueType $records $bestRecord $targetKnown
    if ($issueType) {
        $proposal = New-Proposal $issueType $first.profile $first.target $records $bestRecord $first.source_history_file
        if (-not $proposalIds.ContainsKey($proposal.id)) {
            $proposalIds[$proposal.id] = $true
            [void]$proposals.Add($proposal)
        }
        continue
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
        Write-Host "Skipping existing proposal for the same profile/target/issue: $path"
        continue
    }
    $proposal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
    Write-Host "[OK] Proposal written: $path"
}
