[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*(\+[A-Za-z0-9][A-Za-z0-9_.-]*)*$')]
    [string]$EgressPaths,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*(,[A-Za-z0-9][A-Za-z0-9_.-]*)*$')]
    [string]$TargetAliases,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
    [string]$SourceAlias = 'vps3',

    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$serviceRemote = Join-Path $repoRoot 'tools\services\service_remote.ps1'

if (-not (Test-Path -LiteralPath $serviceRemote -PathType Leaf)) {
    throw "Canonical service runner not found: $serviceRemote"
}

$paths = @($EgressPaths -split '\+')
$targets = @($TargetAliases -split ',')
$unknownTargets = @($targets | Where-Object { $_ -notin $paths })
if ($unknownTargets.Count -gt 0) {
    throw "TargetAliases must be a subset of EgressPaths: $($unknownTargets -join ', ')"
}
if ($targets -contains $SourceAlias) {
    throw 'SourceAlias must not be included in TargetAliases'
}

$steps = [System.Collections.Generic.List[object]]::new()
function Add-Step {
    param(
        [string]$Service,
        [string]$Action,
        [string]$Limit,
        [bool]$IsCheck,
        [string]$Label,
        [string]$PlatformRouterEgressPaths = '',
        [string]$GeoPolicyActivePath = 'auto'
    )
    $steps.Add([ordered]@{
        service = $Service
        action = $Action
        limit = $Limit
        check = $IsCheck
        platform_router_egress_paths = $PlatformRouterEgressPaths
        geo_policy_active_path = $GeoPolicyActivePath
        label = $Label
    }) | Out-Null
}

$targetLimit = $targets -join ','
Add-Step 'platform_router' 'apply' $targetLimit $true `
    'Preflight target platform_router transport servers' $EgressPaths
if (-not $Check) {
    Add-Step 'platform_router' 'apply' $targetLimit $false `
        'Apply target platform_router transport servers' $EgressPaths
}

Add-Step 'edge_haproxy' 'apply' $targetLimit $true `
    'Preflight target edge_haproxy SNI publication'
if (-not $Check) {
    Add-Step 'edge_haproxy' 'apply' $targetLimit $false `
        'Apply target edge_haproxy SNI publication'
}

Add-Step 'platform_router' 'apply' $SourceAlias $true `
    'Preflight source platform_router clients' $EgressPaths
if (-not $Check) {
    Add-Step 'platform_router' 'apply' $SourceAlias $false `
        'Apply and accept source platform_router clients' $EgressPaths
    Add-Step 'geo_policy' 'apply' $SourceAlias $true `
        'Run mutation-free GeoPolicy acceptance' '' 'auto'
}

$batchPlan = Join-Path ([System.IO.Path]::GetTempPath()) (
    'ai-service-platform.geo-policy-transport.' + [guid]::NewGuid().ToString('N') + '.json'
)
try {
    $steps | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $batchPlan -Encoding ascii
    Write-Host "GeoPolicy transport workflow: paths=$EgressPaths targets=$targetLimit source=$SourceAlias check=$([bool]$Check)"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $serviceRemote `
        -BatchPlanFile $batchPlan
    if ($LASTEXITCODE -ne 0) {
        throw "GeoPolicy transport workflow failed with exit code $LASTEXITCODE"
    }
} finally {
    Remove-Item -LiteralPath $batchPlan -Force -ErrorAction SilentlyContinue
}
