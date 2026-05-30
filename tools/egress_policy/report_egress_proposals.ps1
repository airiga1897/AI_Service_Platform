param(
    [string]$ProposalDir = ".\operator\egress_policy\proposals",
    [string]$ProposalFile = "",
    [Alias("Id")]
    [string]$ProposalId = "",
    [ValidateSet("", "suggested", "accepted", "rejected", "ignored", "stale")]
    [string]$Status = "",
    [switch]$Detail,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Read-JsonFile($Path) {
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        Fail "failed to parse proposal JSON: $Path"
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

function Get-HumanType($Proposal) {
    if ($Proposal.human_type) {
        return [string]$Proposal.human_type
    }
    switch ([string]$Proposal.type) {
        "policy_profile_candidate" { return "Новый target вне policy" }
        "fallback_available" { return "Fallback доступен" }
        "fallback_unavailable" { return "Fallback недоступен" }
        "related_target_missing" { return "Связанный target не в policy" }
        "probe_error" { return "Ошибка проверки" }
        "unstable_probe" { return "Нестабильная проверка" }
        "route_review" { return "Нужно проверить вручную" }
        "egress_path_degraded" { return "Маршрут деградировал" }
        "strict_non_ru_violation" { return "Strict non-RU нарушен" }
        "cascade_down" { return "Legacy cascade недоступен" }
        "avoid_ru" { return "Legacy RU egress" }
        default { return [string]$Proposal.type }
    }
}

function Get-ProposalFiles() {
    if ($ProposalFile) {
        if (-not (Test-Path -LiteralPath $ProposalFile -PathType Leaf)) {
            Fail "proposal file not found: $ProposalFile"
        }
        return @(Get-Item -LiteralPath $ProposalFile)
    }

    if (-not (Test-Path -LiteralPath $ProposalDir -PathType Container)) {
        Fail "proposal directory not found: $ProposalDir"
    }

    $files = @(Get-ChildItem -LiteralPath $ProposalDir -File -Filter "*.json" | Sort-Object Name)
    if ($files.Count -eq 0) {
        Fail "no proposal files found in: $ProposalDir"
    }
    return $files
}

function Convert-ProposalToRow($Proposal) {
    $path = $Proposal.recommended_path
    $target = $Proposal.target
    [pscustomobject]@{
        id = $Proposal.id
        status = Get-HumanStatus $Proposal.status
        issue = Get-HumanType $Proposal
        target = if ($target) { "$($target.value):$($target.port)" } else { $null }
        recommended_path = if ($path) {
            if ($path.mode -eq "cascade") {
                "$($path.ingress_alias)->$($path.egress_alias)"
            } elseif ($path.egress_alias) {
                "$($path.mode):$($path.egress_alias)"
            } else {
                $path.mode
            }
        } else {
            $null
        }
        country = if ($path) { $path.effective_country } else { $null }
        http = if ($path) { $path.http_status } else { $null }
        response_ms = if ($path) { $path.response_ms } else { $null }
        source = $Proposal.source
        profile = $Proposal.profile
        internal_type = $Proposal.type
        created_at_utc = $Proposal.created_at_utc
    }
}

$proposals = New-Object System.Collections.ArrayList
foreach ($file in Get-ProposalFiles) {
    $proposal = Read-JsonFile $file.FullName
    if ($ProposalId -and $proposal.id -ne $ProposalId) {
        continue
    }
    if ($Status -and [string]$proposal.status -ne $Status) {
        continue
    }
    $proposal | Add-Member -NotePropertyName source_file -NotePropertyValue $file.FullName -Force
    [void]$proposals.Add($proposal)
}

if ($proposals.Count -eq 0) {
    if ($ProposalId) {
        Fail "no proposal matched id: $ProposalId"
    }
    Fail "no proposals found"
}

$result = @($proposals.ToArray())

if ($Json) {
    $result | ConvertTo-Json -Depth 12
    exit 0
}

if ($Detail) {
    foreach ($proposal in $result) {
        Write-Host ""
        Write-Host "Id:      $($proposal.id)"
        Write-Host "Статус:  $(Get-HumanStatus $proposal.status)"
        Write-Host "Тип:     $(Get-HumanType $proposal)"
        Write-Host "Профиль: $($proposal.profile)"
        Write-Host "Source:  $($proposal.source)"
        Write-Host "Цель:    $($proposal.target.protocol)://$($proposal.target.value):$($proposal.target.port)"
        if ($proposal.recommended_path) {
            $path = $proposal.recommended_path
            Write-Host "Маршрут: $($path.mode) $($path.ingress_alias)->$($path.egress_alias) $($path.cascade_connection)"
            Write-Host "Итог:    country=$($path.effective_country) http=$($path.http_status) response_ms=$($path.response_ms)"
        }
        if ($proposal.human_summary) {
            Write-Host "Для оператора:"
            Write-Host "  $($proposal.human_summary)"
        }
        Write-Host "Reason:"
        Write-Host "  $($proposal.reason)"
        Write-Host "Rollback:"
        Write-Host "  $($proposal.rollback)"
        Write-Host "Evidence:"
        Write-Host "  history: $($proposal.evidence.source_history_file)"
        Write-Host "  run_id:  $($proposal.evidence.run_id)"
        Write-Host "  summary: $($proposal.evidence.summary)"
        foreach ($obs in @($proposal.evidence.observations)) {
            Write-Host "  - $($obs.mode) in=$($obs.ingress_alias) out=$($obs.egress_alias) country=$($obs.effective_country) http=$($obs.http_status) ms=$($obs.response_ms) rec=$($obs.recommendation)"
        }
        Write-Host "File:    $($proposal.source_file)"
    }
    exit 0
}

$result |
    ForEach-Object { Convert-ProposalToRow $_ } |
    Sort-Object status, issue, id |
    Format-Table -AutoSize
