param(
    [string]$ProposalDir = ".\operator\egress_policy\proposals",
    [string]$Id = "",
    [ValidateSet("policy_profile_candidate", "route_review", "fallback_available", "fallback_unavailable", "probe_error")]
    [string]$Type = "route_review",
    [string]$Profile = "",
    [ValidateSet("domain", "ip")]
    [string]$TargetType = "domain",
    [Parameter(Mandatory = $true)]
    [string]$TargetValue,
    [ValidateSet("https", "http", "tcp", "udp", "icmp")]
    [string]$Protocol = "https",
    [int]$Port = -1,
    [string]$Path = "/",
    [string]$IngressAlias = "",
    [string]$EgressAlias = "",
    [string]$CascadeConnection = "",
    [Parameter(Mandatory = $true)]
    [string]$Summary,
    [string]$Evidence = "",
    [switch]$Replace,
    [switch]$DryRun,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Fail($Message) {
    Write-Error $Message
    exit 1
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

function Get-HumanType($Value) {
    switch ([string]$Value) {
        "policy_profile_candidate" { return "Новый target вне policy" }
        "fallback_available" { return "Fallback доступен" }
        "fallback_unavailable" { return "Fallback недоступен" }
        "probe_error" { return "Ошибка проверки" }
        "route_review" { return "Нужно проверить вручную" }
        default { return [string]$Value }
    }
}

function Get-DefaultPort($Protocol, $Port) {
    if ($Port -ge 0) {
        return $Port
    }
    switch ($Protocol) {
        "https" { return 443 }
        "http" { return 80 }
        "icmp" { return 0 }
        default { Fail "-Port is required for protocol $Protocol" }
    }
}

if ([string]::IsNullOrWhiteSpace($TargetValue)) {
    Fail "-TargetValue must not be empty"
}
if ([string]::IsNullOrWhiteSpace($Summary)) {
    Fail "-Summary must not be empty"
}

$portValue = Get-DefaultPort $Protocol $Port
if (($Protocol -eq "icmp" -and $portValue -ne 0) -or ($Protocol -ne "icmp" -and ($portValue -le 0 -or $portValue -gt 65535))) {
    Fail "-Port must be 0 for icmp or in 1..65535 for tcp/udp/http/https"
}
if ($Protocol -in @("tcp", "udp", "icmp")) {
    $Path = "/"
}

if (-not $Id) {
    $Id = "ai-advisory-$(ConvertTo-SafeIdPart $Type)-$(ConvertTo-SafeIdPart "$TargetValue-$portValue")"
}
if ($Id -notmatch '^[a-z0-9][a-z0-9_-]*$') {
    Fail "-Id must match ^[a-z0-9][a-z0-9_-]*`$: $Id"
}

$recommendedPath = $null
if ($IngressAlias -or $EgressAlias -or $CascadeConnection) {
    $recommendedPath = [ordered]@{
        mode = if ($EgressAlias) { "cascade" } else { "review" }
        ingress_alias = $IngressAlias
        egress_alias = $EgressAlias
        cascade_connection = $CascadeConnection
    }
}

$proposal = [ordered]@{
    schema_version = 1
    id = $Id
    type = $Type
    human_type = Get-HumanType $Type
    status = "suggested"
    human_status = Get-HumanStatus "suggested"
    created_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    source = "ai_advisory"
    profile = $Profile
    target = [ordered]@{
        type = $TargetType
        value = $TargetValue
        protocol = $Protocol
        port = $portValue
        path = $Path
    }
    recommended_path = $recommendedPath
    reason = "AI advisory proposal. Operator review is required before any active policy or route change."
    human_summary = $Summary
    rollback = "Proposal-only state. Reject, ignore, or delete this proposal; no runtime route exists until a separate accepted apply-stage."
    evidence = [ordered]@{
        source_history_file = $null
        run_id = $null
        summary = $Evidence
        observations = @()
    }
    ai_advisory = [ordered]@{
        summary = $Summary
        evidence = $Evidence
        created_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
}

$path = Join-Path $ProposalDir "$Id.json"
if ((Test-Path -LiteralPath $path -PathType Leaf) -and -not $Replace) {
    Fail "proposal already exists: $path. Pass -Replace to overwrite it."
}

if ($DryRun) {
    if ($Json) {
        $proposal | ConvertTo-Json -Depth 20
    } else {
        Write-Host "[dry-run] AI advisory proposal would be written: $path"
        Write-Host "Status: Требует решения"
        Write-Host "No proposal file was written."
    }
    exit 0
}

New-Item -ItemType Directory -Force -Path $ProposalDir | Out-Null
$proposal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8

if ($Json) {
    $proposal | ConvertTo-Json -Depth 20
} else {
    Write-Host "[OK] AI advisory proposal written: $path"
    Write-Host "Status: Требует решения"
    Write-Host "No profile, route, firewall, NAT, HAProxy, SoftEther, or Docker runtime changes were made."
}
