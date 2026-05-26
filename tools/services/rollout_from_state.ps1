param(
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$StateFile = ".\operator\state.csv",
    [string]$OperatorDir = ".\operator",
    [string]$ControlRole = "orchestration",
    [string]$ControlAlias = "",
    [string]$SyncScript = "tools/bootstrap/sync_to_orchestration.ps1",
    [string]$StandbyPrepareScript = "tools/bootstrap/prepare_orchestration_standby.ps1",
    [string]$ServiceRemoteScript = "tools/services/service_remote.ps1",
    [string]$OperatorBackupScript = "tools/operator_backup/backup_operator.ps1",
    [string]$OperatorBackupDir = "D:\Backup\Projects\AI_SP\operator",
    [string]$OperatorBackupRemoteDir = "/opt/backups/ai-service-platform/operator",
    [int]$OperatorBackupKeepLatest = 30,
    [string]$VpnIngressDomain = "mine-craft.su",
    [string[]]$ReseedVpnEdge = @(),
    [switch]$AutoAcceptHostKey,
    [switch]$SkipSync,
    [switch]$SkipStandbySync,
    [switch]$SkipPostcheck,
    [switch]$SkipDryRun,
    [switch]$SkipOperatorBackup
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,connection,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$SupportedServices = @("edge_haproxy", "vpn_edge", "vpn_cascade")
$ReservedServices = @()
$script:OperatorBackupCompleted = $false

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
    if (-not $Value) { return @() }
    return @($Value -split "\+" | Where-Object { $_ })
}

function Split-OperatorAliasList($Value) {
    if (-not $Value) { return @() }
    $aliases = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        foreach ($alias in @([string]$item -split "[,+]" | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            Add-UniqueAlias $aliases $alias
        }
    }
    return @($aliases)
}

function Get-PresentServiceAliases($Rows, $Name) {
    $aliases = New-Object System.Collections.Generic.List[string]
    $rows = @($Rows | Where-Object { $_.kind -eq "service" -and $_.name -eq $Name -and $_.state -eq "present" })
    foreach ($row in $rows) {
        foreach ($alias in (Split-AliasList $row.active_aliases)) {
            Add-UniqueAlias $aliases $alias
        }
    }
    return @($aliases)
}

function Get-OrchestrationCandidateAliases($Rows, $Role) {
    $roleRows = @($Rows | Where-Object { ($_.kind -eq "platform_role" -or $_.kind -eq "role") -and $_.name -eq $Role -and $_.state -eq "present" })
    if ($roleRows.Count -eq 0) {
        Fail "state.csv has no present platform_role '$Role'"
    }
    if ($roleRows.Count -gt 1) {
        Fail "state.csv has multiple present platform_role '$Role' rows; keep exactly one"
    }
    return @(Split-AliasList $roleRows[0].candidate_aliases)
}

function Get-EdgeRouteAliasesByState($Rows, $Name, $States) {
    $aliases = New-Object System.Collections.Generic.List[string]
    $rows = @($Rows | Where-Object { $_.kind -eq "edge_route" -and $_.name -eq $Name -and $States -contains $_.state })
    foreach ($row in $rows) {
        foreach ($alias in (Split-AliasList $row.active_aliases)) {
            Add-UniqueAlias $aliases $alias
        }
    }
    return @($aliases)
}

function Get-AnyEdgeRouteAliasesByState($Rows, $States) {
    $aliases = New-Object System.Collections.Generic.List[string]
    $rows = @($Rows | Where-Object { $_.kind -eq "edge_route" -and $States -contains $_.state })
    foreach ($row in $rows) {
        foreach ($alias in (Split-AliasList $row.active_aliases)) {
            Add-UniqueAlias $aliases $alias
        }
    }
    return @($aliases)
}

function Add-UniqueAlias($List, $Alias) {
    if ($List -notcontains $Alias) {
        [void]$List.Add($Alias)
    }
}

function Invoke-OperatorBackupIfNeeded($Reason) {
    if ($script:OperatorBackupCompleted) {
        return
    }
    if ($SkipOperatorBackup) {
        Write-Warning "Operator backup skipped before local mutation: $Reason"
        $script:OperatorBackupCompleted = $true
        return
    }

    Require-File $OperatorBackupScript "OperatorBackupScript"
    Write-Host "Operator backup before local mutation: $Reason"
    $args = @(
        "-NodesFile", $NodesFile,
        "-StateFile", $StateFile,
        "-OperatorDir", $OperatorDir,
        "-ControlRole", $ControlRole,
        "-LocalBackupDir", $OperatorBackupDir,
        "-RemoteBackupDir", $OperatorBackupRemoteDir,
        "-KeepLatest", $OperatorBackupKeepLatest
    )
    if ($AutoAcceptHostKey) { $args += "-AutoAcceptHostKey" }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $OperatorBackupScript @args
    if ($LASTEXITCODE -ne 0) {
        Fail "operator backup failed before local mutation: $Reason"
    }
    $script:OperatorBackupCompleted = $true
}

function Write-StateCsv($Path, $Rows) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($ExpectedStateHeader)
    foreach ($row in $Rows) {
        $lines.Add(("{0},{1},{2},{3},{4},{5},{6}" -f
            $row.kind,
            $row.name,
            $row.ansible_group,
            $row.active_aliases,
            $row.candidate_aliases,
            $row.old_aliases,
            $row.state))
    }
    Set-Content -LiteralPath $Path -Value $lines -Encoding ascii
}

function Normalize-StateRows($Rows, $NodeRows, $StatePath) {
    $nodeAliases = @($NodeRows | ForEach-Object { $_.current_alias } | Where-Object { $_ })
    $changed = $false

    foreach ($row in $Rows) {
        if ($row.kind -eq "role") {
            $row.kind = "platform_role"
            $changed = $true
        }

        foreach ($field in @("active_aliases", "candidate_aliases", "old_aliases")) {
            foreach ($alias in (Split-AliasList $row.$field)) {
                if ($nodeAliases -notcontains $alias) {
                    Fail "state.csv references alias '$alias' in $($row.kind):$($row.name), but nodes.csv has no such alias."
                }
            }
        }
    }

    if ($changed) {
        Invoke-OperatorBackupIfNeeded "normalize state.csv role rows"
        Write-StateCsv $StatePath $Rows
        Write-Host "Normalized state.csv: role -> platform_role"
    }

    return $Rows
}

function Get-PresentVpnIngressAliases($Rows) {
    $aliases = New-Object System.Collections.Generic.List[string]
    $rows = @($Rows | Where-Object { $_.kind -eq "edge_route" -and $_.name -eq "vpn_ingress" -and $_.state -eq "present" })
    foreach ($row in $rows) {
        foreach ($alias in (Split-AliasList $row.active_aliases)) {
            Add-UniqueAlias $aliases $alias
        }
    }
    return @($aliases)
}

function Get-VpnCascadeLinkSecretPath() {
    return (Join-Path (Join-Path (Join-Path (Join-Path $OperatorDir "softether") "cascade") "secrets") "lab-vps5-vps4.json")
}

function Get-VpnCascadeOrderedAliases($Aliases) {
    $secretPath = Get-VpnCascadeLinkSecretPath
    if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) {
        Fail "vpn_cascade requires link secret JSON before rollout: $secretPath"
    }

    try {
        $link = Get-Content -Raw -LiteralPath $secretPath | ConvertFrom-Json
    } catch {
        Fail "vpn_cascade link secret JSON is not valid: $secretPath"
    }

    if (-not $link.ingress_alias -or -not $link.egress_alias) {
        Fail "vpn_cascade link secret must include ingress_alias and egress_alias: $secretPath"
    }

    $ordered = New-Object System.Collections.Generic.List[string]
    foreach ($alias in @($link.egress_alias, $link.ingress_alias)) {
        if ($Aliases -contains $alias) {
            Add-UniqueAlias $ordered $alias
        }
    }
    foreach ($alias in $Aliases) {
        Add-UniqueAlias $ordered $alias
    }
    return @($ordered)
}

function New-VpnIngressAliasBlock($Aliases, $Domain) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($alias in $Aliases) {
        $lines.Add("    ${alias}:")
        $lines.Add("      sni:")
        $lines.Add("        - vpn-${alias}.${Domain}")
    }
    return @($lines)
}

function New-VpnIngressRoutesBlock($Aliases, $Domain) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("vpn_ingress:")
    $lines.Add("  per_alias:")
    foreach ($line in (New-VpnIngressAliasBlock $Aliases $Domain)) {
        $lines.Add($line)
    }
    $lines.Add("  backend:")
    $lines.Add("    host: 172.20.0.2")
    $lines.Add("  ports:")
    $lines.Add("    sstp: 443")
    $lines.Add("    softether_alt: 992")
    $lines.Add("    management: 5555")
    return @($lines)
}

function Find-TopLevelSectionEnd($Lines, $StartIndex) {
    for ($i = $StartIndex + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^\S") {
            return $i
        }
    }
    return $Lines.Count
}

function Normalize-HaproxyRoutes($RoutesPath, $VpnAliases, $Domain) {
    if ($VpnAliases.Count -eq 0) {
        return
    }

    $routesDir = Split-Path -Parent $RoutesPath
    if ($routesDir -and -not (Test-Path -LiteralPath $routesDir -PathType Container)) {
        Invoke-OperatorBackupIfNeeded "create HAProxy routes directory"
        New-Item -ItemType Directory -Force -Path $routesDir | Out-Null
    }

    if (-not (Test-Path -LiteralPath $RoutesPath -PathType Leaf)) {
        Invoke-OperatorBackupIfNeeded "create HAProxy routes.yml"
        Set-Content -LiteralPath $RoutesPath -Value (New-VpnIngressRoutesBlock $VpnAliases $Domain) -Encoding ascii
        Write-Host "Created HAProxy routes.yml with vpn_ingress aliases: $($VpnAliases -join ', ')"
        return
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content -LiteralPath $RoutesPath)) {
        $lines.Add([string]$line)
    }

    $vpnIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^vpn_ingress:\s*$") {
            $vpnIndex = $i
            break
        }
    }

    if ($vpnIndex -lt 0) {
        $newLines = New-Object System.Collections.Generic.List[string]
        foreach ($line in (New-VpnIngressRoutesBlock $VpnAliases $Domain)) {
            $newLines.Add($line)
        }
        $newLines.Add("")
        foreach ($line in $lines) {
            $newLines.Add($line)
        }
        Invoke-OperatorBackupIfNeeded "add vpn_ingress route config"
        Set-Content -LiteralPath $RoutesPath -Value $newLines -Encoding ascii
        Write-Host "Added vpn_ingress route config for aliases: $($VpnAliases -join ', ')"
        return
    }

    $vpnEnd = Find-TopLevelSectionEnd $lines $vpnIndex
    $perAliasIndex = -1
    for ($i = $vpnIndex + 1; $i -lt $vpnEnd; $i++) {
        if ($lines[$i] -match "^  per_alias:\s*$") {
            $perAliasIndex = $i
            break
        }
    }

    if ($perAliasIndex -lt 0) {
        $insertAt = $vpnIndex + 1
        $insertLines = New-Object System.Collections.Generic.List[string]
        $insertLines.Add("  per_alias:")
        foreach ($line in (New-VpnIngressAliasBlock $VpnAliases $Domain)) {
            $insertLines.Add($line)
        }
        $lines.InsertRange($insertAt, [string[]]$insertLines)
        Invoke-OperatorBackupIfNeeded "add vpn_ingress.per_alias route config"
        Set-Content -LiteralPath $RoutesPath -Value $lines -Encoding ascii
        Write-Host "Added vpn_ingress.per_alias for aliases: $($VpnAliases -join ', ')"
        return
    }

    $perAliasEnd = $vpnEnd
    for ($i = $perAliasIndex + 1; $i -lt $vpnEnd; $i++) {
        if ($lines[$i] -match "^  \S") {
            $perAliasEnd = $i
            break
        }
    }

    $existing = @()
    for ($i = $perAliasIndex + 1; $i -lt $perAliasEnd; $i++) {
        $match = [regex]::Match($lines[$i], "^    ([A-Za-z0-9_.-]+):\s*$")
        if ($match.Success) {
            $existing += $match.Groups[1].Value
        }
    }

    $missing = @($VpnAliases | Where-Object { $existing -notcontains $_ })
    if ($missing.Count -eq 0) {
        return
    }

    $lines.InsertRange($perAliasEnd, [string[]](New-VpnIngressAliasBlock $missing $Domain))
    Invoke-OperatorBackupIfNeeded "add missing vpn_ingress aliases"
    Set-Content -LiteralPath $RoutesPath -Value $lines -Encoding ascii
    Write-Host "Added vpn_ingress routes for aliases: $($missing -join ', ')"
}

function Invoke-ChildScript($ScriptPath, $Arguments, $Label) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label failed with exit code $LASTEXITCODE"
    }
}

function Invoke-ServiceRemote($Service, $Action, $Limit, [switch]$Check, [switch]$ConfirmPurge) {
    $args = @(
        $Service,
        $Action,
        "-NodesFile", $NodesFile,
        "-StateFile", $StateFile,
        "-OperatorDir", $OperatorDir,
        "-ControlRole", $ControlRole
    )
    if ($ControlAlias) { $args += @("-ControlAlias", $ControlAlias) }
    if ($Limit) { $args += @("-Limit", $Limit) }
    if ($Check) { $args += "-Check" }
    if ($ConfirmPurge) { $args += "-ConfirmPurge" }
    Invoke-ChildScript $ServiceRemoteScript $args "$Service $Action"
}

function Invoke-ServiceApplyDryRun($Service, $Limit, $Label) {
    if ($SkipDryRun) {
        Write-Host "${Label}: dry-run skipped"
        Write-Host "Dry-run: skipped by operator request"
        return
    }
    Write-Host "${Label}: dry-run"
    Invoke-ServiceRemote $Service "apply" $Limit -Check
}

function Invoke-VpnEdgeReseed($Alias, $ReseededAliases, $Summary) {
    if ($ReseededAliases -contains $Alias) {
        return
    }
    Write-Host "vpn_edge on ${Alias}: reseed"
    Invoke-ServiceRemote "vpn_edge" "reseed" $Alias
    Add-UniqueAlias $ReseededAliases $Alias
    $Summary.Add("vpn_edge ${Alias}: reseeded") | Out-Null
}

function Invoke-Sync() {
    $args = @(
        "-NodesFile", $NodesFile,
        "-StateFile", $StateFile,
        "-OperatorDir", $OperatorDir,
        "-ControlRole", $ControlRole
    )
    if ($ControlAlias) { $args += @("-ControlAlias", $ControlAlias) }
    if ($AutoAcceptHostKey) { $args += "-AutoAcceptHostKey" }
    Invoke-ChildScript $SyncScript $args "sync to orchestration"
}

function Invoke-StandbySync($Aliases) {
    if ($Aliases.Count -eq 0) {
        return
    }

    Write-Host ""
    Write-Host "Step 1b/3: sync standby orchestration candidate nodes"
    foreach ($alias in $Aliases) {
        Write-Host "Preparing standby orchestration node ${alias}"
        $args = @(
            "-Alias", $alias,
            "-NodesFile", $NodesFile,
            "-StateFile", $StateFile,
            "-OperatorDir", $OperatorDir,
            "-ControlRole", $ControlRole,
            "-SyncScript", $SyncScript,
            "-SkipServicePlan"
        )
        if ($AutoAcceptHostKey) { $args += "-AutoAcceptHostKey" }
        Invoke-ChildScript $StandbyPrepareScript $args "standby orchestration preparation for $alias"
    }
}

function Invoke-Postcheck($Service, $State, $Alias) {
    if ($SkipPostcheck) {
        Write-Host "Postcheck skipped for $Service on $Alias"
        return
    }

    switch ($Service) {
        "edge_haproxy" {
            switch ($State) {
                "present" {
                    Invoke-ServiceRemote $Service "plan" $Alias
                    Write-Host "[OK] edge_haproxy postcheck placeholder completed for $Alias"
                }
                "absent" {
                    Write-Host "[OK] edge_haproxy absent requested for $Alias; config/data should remain on target"
                }
                "purged" {
                    Write-Host "[OK] edge_haproxy purge requested for $Alias; runtime directory removal is handled by the role"
                }
            }
        }
        default {
            Write-Host "No postcheck implemented yet for $Service on $Alias"
        }
    }
}

Require-File $NodesFile "NodesFile"
Require-File $StateFile "StateFile"
Require-File $SyncScript "SyncScript"
if (-not $SkipStandbySync) {
    Require-File $StandbyPrepareScript "StandbyPrepareScript"
}
Require-File $ServiceRemoteScript "ServiceRemoteScript"

$nodesHeader = Get-Content -LiteralPath $NodesFile -TotalCount 1
if ($nodesHeader -ne $ExpectedNodesHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedNodesHeader"
}
$stateHeader = Get-Content -LiteralPath $StateFile -TotalCount 1
if ($stateHeader -ne $ExpectedStateHeader) {
    Fail "state.csv header must be exactly: $ExpectedStateHeader"
}

$nodeRows = Import-Csv -LiteralPath $NodesFile
$stateRows = Import-Csv -LiteralPath $StateFile
$stateRows = @(Normalize-StateRows $stateRows $nodeRows $StateFile)
Normalize-HaproxyRoutes (Join-Path (Join-Path $OperatorDir "haproxy") "routes.yml") (Get-PresentVpnIngressAliases $stateRows) $VpnIngressDomain
$reseedVpnEdgeAliases = @(Split-OperatorAliasList $ReseedVpnEdge)
$standbyOrchestrationAliases = @(Get-OrchestrationCandidateAliases $stateRows $ControlRole)

$serviceRows = @($stateRows | Where-Object { $_.kind -eq "service" })
if ($serviceRows.Count -eq 0) {
    Fail "state.csv has no service rows"
}
$edgeRouteRows = @($stateRows | Where-Object { $_.kind -eq "edge_route" })
$edgeHaproxyAliases = @(Get-PresentServiceAliases $stateRows "edge_haproxy")
$vpnEdgeAliases = @(Get-PresentServiceAliases $stateRows "vpn_edge")
$vpnIngressAliases = @(Get-EdgeRouteAliasesByState $stateRows "vpn_ingress" @("present"))
$presentEdgeRouteAliases = @(Get-AnyEdgeRouteAliasesByState $stateRows @("present"))
$edgeRouteApplyAliases = New-Object System.Collections.Generic.List[string]
$edgeRouteRemovalAliases = New-Object System.Collections.Generic.List[string]

$nodeAliases = @($nodeRows | ForEach-Object { $_.current_alias } | Where-Object { $_ })
foreach ($alias in $reseedVpnEdgeAliases) {
    if ($nodeAliases -notcontains $alias) {
        Fail "ReseedVpnEdge alias '$alias' is not present in nodes.csv"
    }
    if ($vpnEdgeAliases -notcontains $alias) {
        Fail "ReseedVpnEdge alias '$alias' requires service vpn_edge present on the same alias in state.csv"
    }
}

foreach ($routeRow in $edgeRouteRows) {
    if ($routeRow.state -notin @("present", "absent", "purged")) {
        Fail "$($routeRow.name) edge_route state must be one of: present, absent, purged"
    }
    if ($routeRow.state -ne "present") {
        continue
    }
    $routeAliases = @(Split-AliasList $routeRow.active_aliases)
    if ($routeAliases.Count -eq 0) {
        Fail "edge_route $($routeRow.name) has state=present but active_aliases is empty"
    }
    foreach ($alias in $routeAliases) {
        if ($edgeHaproxyAliases -notcontains $alias) {
            Fail "edge_route $($routeRow.name) is present on $alias, but service edge_haproxy is not present on the same alias"
        }
        if ($routeRow.name -eq "vpn_ingress" -and ($vpnEdgeAliases -notcontains $alias)) {
            Fail "edge_route vpn_ingress is present on $alias, but service vpn_edge is not present on the same alias"
        }
        Add-UniqueAlias $edgeRouteApplyAliases $alias
    }
}

foreach ($routeRow in @($edgeRouteRows | Where-Object { $_.state -in @("absent", "purged") })) {
    foreach ($alias in (Split-AliasList $routeRow.active_aliases)) {
        if ($edgeHaproxyAliases -contains $alias) {
            Add-UniqueAlias $edgeRouteRemovalAliases $alias
        }
    }
}

foreach ($serviceRow in $serviceRows) {
    if ($serviceRow.state -notin @("present", "absent", "purged")) {
        Fail "$($serviceRow.name) state must be one of: present, absent, purged"
    }
    foreach ($alias in (Split-AliasList $serviceRow.active_aliases)) {
        if ($serviceRow.name -eq "vpn_edge" -and $serviceRow.state -eq "present" -and ($vpnIngressAliases -notcontains $alias)) {
            Fail "service vpn_edge is present on $alias, but edge_route vpn_ingress is not present on the same alias"
        }
        if ($serviceRow.name -eq "vpn_edge" -and $serviceRow.state -in @("absent", "purged") -and ($vpnIngressAliases -contains $alias)) {
            Fail "service vpn_edge is $($serviceRow.state) on $alias, but edge_route vpn_ingress is still present on the same alias"
        }
        if ($serviceRow.name -eq "edge_haproxy" -and $serviceRow.state -in @("absent", "purged") -and ($presentEdgeRouteAliases -contains $alias)) {
            Fail "service edge_haproxy is $($serviceRow.state) on $alias, but an edge_route is still present on the same alias"
        }
    }
}

if (-not $SkipSync) {
    Write-Host "Step 1/3: sync operator state to active orchestration node"
    Invoke-Sync
    if (-not $SkipStandbySync) {
        Invoke-StandbySync $standbyOrchestrationAliases
    } else {
        Write-Host "Step 1b/3: standby orchestration sync skipped by -SkipStandbySync"
    }
} else {
    Write-Host "Step 1/3: sync skipped by -SkipSync"
    Write-Host "Step 1b/3: standby orchestration sync skipped because sync is skipped"
}

$summary = New-Object System.Collections.Generic.List[string]
$plannedServices = New-Object System.Collections.Generic.List[string]
$processedServiceActions = New-Object System.Collections.Generic.List[string]
$reseededVpnEdgeAliases = New-Object System.Collections.Generic.List[string]
Write-Host ""
Write-Host "Step 2/3: rollout services from state.csv"

if ($edgeRouteRemovalAliases.Count -gt 0) {
    Write-Host ""
    Write-Host "Step 2a/3: remove absent edge routes through edge_haproxy before stopping backends"
    if ($plannedServices -notcontains "edge_haproxy") {
        Invoke-ServiceRemote "edge_haproxy" "plan" ""
        Add-UniqueAlias $plannedServices "edge_haproxy"
    }
    foreach ($alias in $edgeRouteRemovalAliases) {
        Invoke-ServiceApplyDryRun "edge_haproxy" $alias "edge_haproxy route removal on ${alias}"
        Write-Host "edge_haproxy route removal on ${alias}: apply"
        Invoke-ServiceRemote "edge_haproxy" "apply" $alias
        Add-UniqueAlias $processedServiceActions "edge_haproxy|present|$alias"
        $summary.Add("edge_haproxy routes ${alias}: removed absent routes") | Out-Null
    }
}

$orderedServiceRows = @(
    @($serviceRows | Where-Object { $_.state -eq "present" -and $_.name -ne "edge_haproxy" })
    @($serviceRows | Where-Object { $_.state -eq "present" -and $_.name -eq "edge_haproxy" })
    @($serviceRows | Where-Object { $_.state -in @("absent", "purged") -and $_.name -ne "edge_haproxy" })
    @($serviceRows | Where-Object { $_.state -in @("absent", "purged") -and $_.name -eq "edge_haproxy" })
)

foreach ($serviceRow in $orderedServiceRows) {
    $service = $serviceRow.name
    $state = $serviceRow.state
    $aliases = @(Split-AliasList $serviceRow.active_aliases)
    if ($service -eq "vpn_cascade" -and $state -eq "present") {
        $aliases = @(Get-VpnCascadeOrderedAliases $aliases)
    }

    if ($state -notin @("present", "absent", "purged")) {
        Fail "$service state must be one of: present, absent, purged"
    }

    if ($ReservedServices -contains $service) {
        Write-Host "${service}: reserved/not implemented; skipped"
        $summary.Add("${service}: skipped reserved") | Out-Null
        continue
    }
    if ($SupportedServices -notcontains $service) {
        Write-Host "${service}: not implemented yet; skipped"
        $summary.Add("${service}: skipped not implemented") | Out-Null
        continue
    }

    Write-Host ""
    Write-Host "Service: $service"
    Write-Host "State:   $state"
    if ($plannedServices -notcontains $service) {
        Invoke-ServiceRemote $service "plan" ""
        Add-UniqueAlias $plannedServices $service
    }

    if ($aliases.Count -eq 0) {
        if ($state -eq "present") {
            Fail "$service has state=present but active_aliases is empty"
        }
        Write-Host "${service}: no active_aliases for state=$state; no-op"
        $summary.Add("${service}: no-op") | Out-Null
        continue
    }

    foreach ($alias in $aliases) {
        $actionKey = "$service|$state|$alias"
        if ($processedServiceActions -contains $actionKey) {
            Write-Host "$service on ${alias}: duplicate state row for state=$state; skipped"
            continue
        }
        Add-UniqueAlias $processedServiceActions $actionKey

        if ($state -eq "present") {
            Invoke-ServiceApplyDryRun $service $alias "$service on ${alias}"
            Write-Host "$service on ${alias}: apply"
            Invoke-ServiceRemote $service "apply" $alias
            Invoke-Postcheck $service $state $alias
            $summary.Add("$service ${alias}: present") | Out-Null
            if ($service -eq "vpn_edge" -and ($reseedVpnEdgeAliases -contains $alias)) {
                Invoke-VpnEdgeReseed $alias $reseededVpnEdgeAliases $summary
            }
        } elseif ($state -eq "absent") {
            Write-Host "$service on ${alias}: absent"
            Invoke-ServiceRemote $service "absent" $alias
            Invoke-Postcheck $service $state $alias
            $summary.Add("$service ${alias}: absent") | Out-Null
        } elseif ($state -eq "purged") {
            Write-Host "$service on ${alias}: purge"
            Invoke-ServiceRemote $service "purge" $alias -ConfirmPurge
            Invoke-Postcheck $service $state $alias
            $summary.Add("$service ${alias}: purged") | Out-Null
        }
    }
}

if ($edgeRouteApplyAliases.Count -gt 0) {
    Write-Host ""
    Write-Host "Step 2b/3: apply edge route rendering through edge_haproxy"
    foreach ($alias in $edgeRouteApplyAliases) {
        if ($processedServiceActions -contains "edge_haproxy|present|$alias") {
            Write-Host "edge_haproxy routes on ${alias}: already applied by edge_haproxy service apply"
            continue
        }
        Invoke-ServiceApplyDryRun "edge_haproxy" $alias "edge_haproxy routes on ${alias}"
        Write-Host "edge_haproxy routes on ${alias}: apply"
        Invoke-ServiceRemote "edge_haproxy" "apply" $alias
        $summary.Add("edge_haproxy routes ${alias}: applied") | Out-Null
    }
}

foreach ($alias in $reseedVpnEdgeAliases) {
    Invoke-VpnEdgeReseed $alias $reseededVpnEdgeAliases $summary
}

Write-Host ""
Write-Host "Step 3/3: summary"
foreach ($item in $summary) {
    Write-Host "  $item"
}
Write-Host "Rollout from state completed."
