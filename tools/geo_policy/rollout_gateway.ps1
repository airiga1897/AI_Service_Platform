[CmdletBinding()]
param(
    [ValidateSet('Check', 'Apply', 'Rollback')]
    [string]$Mode = 'Check',

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
    [string]$SourceAlias = 'vps3',

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*(\+[A-Za-z0-9][A-Za-z0-9_.-]*)*$')]
    [string]$EgressPaths = 'vps1+vps2+vps4',

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*(,[A-Za-z0-9][A-Za-z0-9_.-]*)*$')]
    [string]$TargetAliases = 'vps1,vps2,vps4'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$serviceRemote = Join-Path $repoRoot 'tools\services\service_remote.ps1'

if (-not (Test-Path -LiteralPath $serviceRemote -PathType Leaf)) {
    throw "Canonical service runner not found: $serviceRemote"
}

$pathAliases = @($EgressPaths -split '\+')
$targetAliasList = @($TargetAliases -split ',')
$unknownTargets = @($targetAliasList | Where-Object { $_ -notin $pathAliases })
if ($unknownTargets.Count -gt 0) {
    throw "TargetAliases must be a subset of EgressPaths: $($unknownTargets -join ',')"
}

function Invoke-ServiceStep {
    param([string[]]$Arguments, [string]$Label)
    Write-Host "[gateway] $Label"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $serviceRemote @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "GeoPolicy gateway workflow failed during '$Label' with exit code $LASTEXITCODE"
    }
}

$platformArgs = @(
    'platform_router', 'apply',
    '-Limit', $SourceAlias,
    '-PlatformRouterEgressPaths', $EgressPaths,
    '-PlatformRouterSourceGatewayState', 'enabled'
)
$vpnArgs = @('vpn_edge', 'apply', '-Limit', $SourceAlias)
$targetArgs = @(
    'platform_router', 'apply',
    '-Limit', $TargetAliases,
    '-PlatformRouterEgressPaths', $EgressPaths,
    '-PlatformRouterSourceGatewayState', 'preserve'
)

switch ($Mode) {
    'Check' {
        Invoke-ServiceStep (@($vpnArgs) + '-Check') `
            'Preflight VPN policy handoff network and source attachment'
        Invoke-ServiceStep (@($targetArgs) + '-Check') `
            'Preflight target VPN policy handoff forwarding and SNAT'
        Invoke-ServiceStep (@($platformArgs) + '-Check') `
            'Preflight source gateways without network mutations'
    }
    'Apply' {
        Invoke-ServiceStep (@($vpnArgs) + '-Check') `
            'Preflight VPN policy handoff network and source attachment'
        Invoke-ServiceStep $vpnArgs `
            'Apply VPN policy handoff network and source attachment'
        Invoke-ServiceStep (@($targetArgs) + '-Check') `
            'Preflight target VPN policy handoff forwarding and SNAT'
        Invoke-ServiceStep $targetArgs `
            'Apply target VPN policy handoff forwarding and SNAT'
        Invoke-ServiceStep (@($platformArgs) + '-Check') `
            'Preflight source gateways without network mutations'
        Invoke-ServiceStep $platformArgs `
            'Apply source gateways and host fail-closed guard'
        Invoke-ServiceStep @(
            'geo_policy', 'apply', '-Limit', $SourceAlias,
            '-GeoPolicyActivePath', 'auto', '-Check'
        ) 'Run mutation-free GeoPolicy acceptance'
    }
    'Rollback' {
        Invoke-ServiceStep @('geo_policy', 'absent', '-Limit', $SourceAlias) `
            'Remove GeoPolicy while preserving transport'
        $rollbackArgs = @(
            'platform_router', 'apply',
            '-Limit', $SourceAlias,
            '-PlatformRouterEgressPaths', $EgressPaths,
            '-PlatformRouterSourceGatewayState', 'disabled'
        )
        Invoke-ServiceStep (@($rollbackArgs) + '-Check') `
            'Preflight Docker default-route restoration'
        Invoke-ServiceStep $rollbackArgs `
            'Restore Docker defaults and remove the host guard'
    }
}

Write-Host "[OK] GeoPolicy gateway workflow completed: mode=$Mode source=$SourceAlias"
