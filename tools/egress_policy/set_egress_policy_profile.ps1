param(
    [string]$PolicyFile = ".\operator\egress_policy\profiles.json",
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string[]]$TargetValue,
    [ValidateSet("domain", "ip")]
    [string]$TargetType = "domain",
    [ValidateSet("https", "http", "tcp", "udp", "icmp")]
    [string]$Protocol = "https",
    [int]$Port = 0,
    [string]$Path = "/",
    [Parameter(Mandatory = $true)]
    [string[]]$IngressAlias,
    [Parameter(Mandatory = $true)]
    [string[]]$FallbackEgressAlias,
    [ValidateSet("probe", "disabled")]
    [string]$State = "probe",
    [Parameter(Mandatory = $true)]
    [string]$Reason,
    [string]$Rollback = "Probe-only intent; disable this profile or remove later approved selective fallback routing to return to ingress-local egress.",
    [switch]$Replace,
    [switch]$DryRun,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Read-Registry($Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            version = 1
            profiles = @()
        }
    }

    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        Fail "failed to parse egress policy registry: $Path"
    }
}

function Assert-ProfileName($Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[a-z][a-z0-9_]*$') {
        Fail "-Name must match ^[a-z][a-z0-9_]*`$: $Value"
    }
}

function Assert-NonEmptyList($Values, $Label) {
    $items = @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($items.Count -eq 0) {
        Fail "$Label must include at least one value"
    }
    $seen = @{}
    foreach ($item in $items) {
        if ($seen.ContainsKey($item)) {
            Fail "$Label has duplicate value: $item"
        }
        $seen[$item] = $true
    }
    return $items
}

function Get-DefaultPort($Protocol, $Port) {
    if ($Port -gt 0) {
        return $Port
    }
    switch ($Protocol) {
        "https" { return 443 }
        "http" { return 80 }
        "icmp" { return 0 }
        default { Fail "-Port is required for protocol $Protocol" }
    }
}

Assert-ProfileName $Name
if ([string]::IsNullOrWhiteSpace($Reason)) {
    Fail "-Reason must not be empty"
}
if ([string]::IsNullOrWhiteSpace($Rollback)) {
    Fail "-Rollback must not be empty"
}

$targets = Assert-NonEmptyList $TargetValue "-TargetValue"
$ingressAliases = Assert-NonEmptyList $IngressAlias "-IngressAlias"
$fallbackEgressAliases = Assert-NonEmptyList $FallbackEgressAlias "-FallbackEgressAlias"
$portValue = Get-DefaultPort $Protocol $Port
if (($Protocol -eq "icmp" -and $portValue -ne 0) -or ($Protocol -ne "icmp" -and ($portValue -le 0 -or $portValue -gt 65535))) {
    Fail "-Port must be 0 for icmp or in 1..65535 for tcp/udp/http/https"
}
if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = "/"
}
if ($Protocol -in @("tcp", "udp", "icmp")) {
    $Path = "/"
}

$registry = Read-Registry $PolicyFile
if ($registry.version -ne 1) {
    Fail "egress policy registry version must be 1"
}
if ($null -eq $registry.profiles) {
    $registry | Add-Member -NotePropertyName profiles -NotePropertyValue @() -Force
}

$existingProfiles = @($registry.profiles)
$existing = @($existingProfiles | Where-Object { $_.name -eq $Name })
if ($existing.Count -gt 0 -and -not $Replace) {
    Fail "egress profile already exists: $Name. Pass -Replace to overwrite it."
}
if ($existing.Count -gt 1) {
    Fail "egress registry contains duplicate profile name: $Name"
}

$targetObjects = @($targets | ForEach-Object {
    [ordered]@{
        type = $TargetType
        value = [string]$_
        protocol = $Protocol
        port = $portValue
        path = $Path
    }
})

$profile = [ordered]@{
    name = $Name
    state = $State
    behavior = "fallback_on_ingress_egress_failure"
    reason = $Reason
    rollback = $Rollback
    candidate_ingress_aliases = @($ingressAliases)
    candidate_fallback_egress_aliases = @($fallbackEgressAliases)
    targets = @($targetObjects)
}

$updatedProfiles = @($existingProfiles | Where-Object { $_.name -ne $Name })
$updatedProfiles += [pscustomobject]$profile
$updatedRegistry = [ordered]@{
    version = 1
    profiles = @($updatedProfiles | Sort-Object name)
}

if ($DryRun) {
    if ($Json) {
        $updatedRegistry | ConvertTo-Json -Depth 20
    } else {
        Write-Host "[dry-run] Profile would be written: $Name"
        Write-Host "Targets: $($targets -join ', ')"
        Write-Host "Ingress aliases: $($ingressAliases -join ', ')"
        Write-Host "Fallback egress aliases: $($fallbackEgressAliases -join ', ')"
    }
    exit 0
}

$policyDir = Split-Path -Parent $PolicyFile
if ($policyDir) {
    New-Item -ItemType Directory -Force -Path $policyDir | Out-Null
}
$updatedRegistry | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $PolicyFile -Encoding utf8

if ($Json) {
    $updatedRegistry | ConvertTo-Json -Depth 20
} else {
    Write-Host "[OK] Egress policy profile written: $Name"
    Write-Host "File: $PolicyFile"
    Write-Host "No route, NAT, firewall, HAProxy, SoftEther, or Docker runtime changes were made."
}
