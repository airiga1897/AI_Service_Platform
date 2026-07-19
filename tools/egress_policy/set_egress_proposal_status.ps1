param(
    [string]$ProposalDir = ".\operator\egress_policy\proposals",
    [Parameter(Mandatory = $true)]
    [Alias("Id")]
    [string]$ProposalId,
    [Parameter(Mandatory = $true)]
    [ValidateSet("accepted", "rejected", "ignored", "stale")]
    [string]$Status,
    [Parameter(Mandatory = $true)]
    [string]$Reason,
    [string]$Operator = $env:USERNAME
)

$ErrorActionPreference = "Stop"

function Fail($Message) {
    Write-Error $Message
    exit 1
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

if ([string]::IsNullOrWhiteSpace($Reason)) {
    Fail "-Reason must not be empty"
}

if (-not (Test-Path -LiteralPath $ProposalDir -PathType Container)) {
    Fail "proposal directory not found: $ProposalDir"
}

$matches = @(Get-ChildItem -LiteralPath $ProposalDir -File -Filter "*.json" | Where-Object {
    $_.BaseName -eq $ProposalId
})

if ($matches.Count -eq 0) {
    Fail "proposal not found: $ProposalId"
}
if ($matches.Count -gt 1) {
    Fail "proposal id is ambiguous: $ProposalId"
}

$path = $matches[0].FullName
try {
    $proposal = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
} catch {
    Fail "failed to parse proposal JSON: $path"
}

$previousStatus = [string]$proposal.status
$proposal.status = $Status
$proposal | Add-Member -NotePropertyName human_status -NotePropertyValue (Get-HumanStatus $Status) -Force
$proposal | Add-Member -NotePropertyName operator_decision -NotePropertyValue ([ordered]@{
    status = $Status
    human_status = Get-HumanStatus $Status
    previous_status = $previousStatus
    previous_human_status = Get-HumanStatus $previousStatus
    reason = $Reason
    operator = if ($Operator) { $Operator } else { "unknown" }
    decided_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
}) -Force

$proposal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
Write-Host "[OK] Proposal $ProposalId marked $(Get-HumanStatus $Status) ($Status)"
Write-Host "File: $path"
Write-Host "No profile, route, firewall, NAT, HAProxy, or SoftEther runtime changes were made."
