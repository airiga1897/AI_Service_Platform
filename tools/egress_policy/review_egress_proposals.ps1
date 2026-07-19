param(
    [string]$ProposalDir = ".\operator\egress_policy\proposals",
    [ValidateSet("suggested", "accepted", "rejected", "ignored", "stale", "all")]
    [string]$Status = "suggested",
    [string]$Operator = $env:USERNAME
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

function Get-PathText($Proposal) {
    $path = $Proposal.recommended_path
    if (-not $path) {
        return "-"
    }
    if ($path.mode -eq "cascade") {
        return "$($path.ingress_alias)->$($path.egress_alias) $($path.cascade_connection)"
    }
    if ($path.egress_alias) {
        return "$($path.mode):$($path.egress_alias)"
    }
    return [string]$path.mode
}

function Write-ProposalCard($Proposal, [int]$Index, [int]$Total) {
    $target = $Proposal.target
    $path = $Proposal.recommended_path
    Write-Host ""
    Write-Host "[$Index/$Total] $($Proposal.id)"
    Write-Host "Статус:  $(Get-HumanStatus $Proposal.status)"
    Write-Host "Тип:     $(Get-HumanType $Proposal)"
    Write-Host "Профиль: $($Proposal.profile)"
    Write-Host "Цель:    $($target.protocol)://$($target.value):$($target.port)"
    Write-Host "Маршрут: $(Get-PathText $Proposal)"
    if ($path) {
        Write-Host "Итог:    country=$($path.effective_country) http=$($path.http_status) response_ms=$($path.response_ms)"
    }
    if ($Proposal.human_summary) {
        Write-Host "Смысл:   $($Proposal.human_summary)"
    } else {
        Write-Host "Смысл:   $($Proposal.reason)"
    }
}

function Write-ProposalDetails($Proposal) {
    Write-Host ""
    Write-Host "Reason:"
    Write-Host "  $($Proposal.reason)"
    Write-Host "Rollback:"
    Write-Host "  $($Proposal.rollback)"
    Write-Host "Evidence:"
    Write-Host "  history: $($Proposal.evidence.source_history_file)"
    Write-Host "  run_id:  $($Proposal.evidence.run_id)"
    Write-Host "  summary: $($Proposal.evidence.summary)"
    foreach ($obs in @($Proposal.evidence.observations)) {
        Write-Host "  - $($obs.mode) in=$($obs.ingress_alias) out=$($obs.egress_alias) country=$($obs.effective_country) http=$($obs.http_status) ms=$($obs.response_ms) rec=$($obs.recommendation)"
    }
}

function Set-ProposalStatus($Proposal, $Path, $NewStatus, $Reason) {
    $previousStatus = [string]$Proposal.status
    $Proposal.status = $NewStatus
    $Proposal | Add-Member -NotePropertyName human_status -NotePropertyValue (Get-HumanStatus $NewStatus) -Force
    $Proposal | Add-Member -NotePropertyName operator_decision -NotePropertyValue ([ordered]@{
        status = $NewStatus
        human_status = Get-HumanStatus $NewStatus
        previous_status = $previousStatus
        previous_human_status = Get-HumanStatus $previousStatus
        reason = $Reason
        operator = if ($Operator) { $Operator } else { "unknown" }
        decided_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    }) -Force

    $Proposal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
    Write-Host "[OK] $(Get-HumanStatus $NewStatus): $($Proposal.id)"
    Write-Host "Runtime не изменялся: профили, маршруты, firewall, NAT, HAProxy и SoftEther не тронуты."
}

function Read-DecisionReason($Prompt, $Default, [bool]$Required) {
    while ($true) {
        $value = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = $Default
        }
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
        if (-not $Required) {
            return $value
        }
        Write-Host "Причина обязательна для этого решения."
    }
}

if (-not (Test-Path -LiteralPath $ProposalDir -PathType Container)) {
    Fail "proposal directory not found: $ProposalDir"
}

$items = New-Object System.Collections.ArrayList
foreach ($file in @(Get-ChildItem -LiteralPath $ProposalDir -File -Filter "*.json" | Sort-Object Name)) {
    $proposal = Read-JsonFile $file.FullName
    if ($Status -ne "all" -and [string]$proposal.status -ne $Status) {
        continue
    }
    [void]$items.Add([pscustomobject]@{
        path = $file.FullName
        proposal = $proposal
    })
}

if ($items.Count -eq 0) {
    Write-Host "Нет proposals со статусом: $(Get-HumanStatus $Status)"
    exit 0
}

$goodCount = 0
$needsDecisionCount = 0
foreach ($item in @($items.ToArray())) {
    if ([string]$item.proposal.status -eq "suggested") {
        $needsDecisionCount += 1
    } else {
        $goodCount += 1
    }
}

Write-Host "Proposal inbox"
Write-Host "К просмотру: $($items.Count); требует решения: $needsDecisionCount; уже решено/отложено: $goodCount"
Write-Host "Действия: A=accept, R=reject, I=ignore, D=details, S=skip, Q=quit"

for ($index = 0; $index -lt $items.Count; $index += 1) {
    $item = $items[$index]
    $proposal = $item.proposal
    while ($true) {
        Write-ProposalCard $proposal ($index + 1) $items.Count
        $action = (Read-Host "Action [A/R/I/D/S/Q]").Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($action)) {
            $action = "S"
        }

        switch ($action) {
            "A" {
                $reason = Read-DecisionReason "Причина принятия (Enter = default)" "Подтверждено оператором для подготовки policy draft." $false
                Set-ProposalStatus $proposal $item.path "accepted" $reason
                break
            }
            "R" {
                $reason = Read-DecisionReason "Причина отклонения" "" $true
                Set-ProposalStatus $proposal $item.path "rejected" $reason
                break
            }
            "I" {
                $reason = Read-DecisionReason "Причина отложения (Enter = default)" "Отложено оператором без изменения policy." $false
                Set-ProposalStatus $proposal $item.path "ignored" $reason
                break
            }
            "D" {
                Write-ProposalDetails $proposal
                continue
            }
            "S" {
                Write-Host "Пропущено: $($proposal.id)"
                break
            }
            "Q" {
                Write-Host "Review stopped by operator."
                exit 0
            }
            default {
                Write-Host "Неизвестное действие. Используйте A, R, I, D, S или Q."
                continue
            }
        }
        break
    }
}

Write-Host "[OK] Proposal review finished."
