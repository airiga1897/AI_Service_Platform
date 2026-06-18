param(
    [string]$PolicyFile = ".\operator\egress_policy\profiles.json",
    [string]$StateFile = ".\operator\state.csv",
    [string]$ProposalDir = ".\operator\egress_policy\proposals",
    [string]$AppliedRoutesDir = ".\operator\egress_policy\applied_routes",
    [string]$ProbeScript = ".\tools\egress_policy\probe_egress_policy.ps1",
    [string]$SuggestScript = ".\tools\egress_policy\suggest_egress_policy.ps1",
    [string]$ApplyScript = ".\tools\egress_policy\apply_selective_fallback_routes.ps1",
    [string]$RefreshScript = ".\tools\egress_policy\refresh_selective_fallback_dns_sets.ps1",
    [Alias("Profile")]
    [string[]]$ProfileName = @(),
    [string[]]$TargetDomain = @(),
    [string]$SshPath = "ssh",
    [int]$ProbeTimeoutSeconds = 5,
    [int]$ProbeAttempts = 1,
    [int]$ProbeRetryDelaySeconds = 1,
    [bool]$RequireDeterministic = $true,
    [switch]$AllowRollbackOnly,
    [switch]$Check,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Require-File($Path, $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Label not found: $Path"
    }
}

function Require-Directory($Path, $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Fail "$Label not found: $Path"
    }
}

function Read-JsonFile($Path, $Label) {
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        Fail "failed to parse ${Label}: $Path"
    }
}

function Read-StateRows($Path) {
    Require-File $Path "state file"
    $firstLine = Get-Content -LiteralPath $Path -TotalCount 1
    if ($firstLine -ne $ExpectedStateHeader) {
        Fail "unexpected state.csv header in $Path"
    }
    return @(Import-Csv -LiteralPath $Path)
}

function Split-ListValue($Value) {
    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return @()
    }
    return @(([string]$Value).Split("+", [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-CascadeTopology($StateRows) {
    $rows = @($StateRows | Where-Object { $_.kind -eq "cascade_topology" -and $_.state -eq "present" })
    if ($rows.Count -eq 0) {
        Fail "cascade_topology row not found in state.csv"
    }
    if ($rows.Count -gt 1) {
        Fail "multiple active cascade_topology rows found in state.csv"
    }
    $row = $rows[0]
    $activeEdges = @(Split-ListValue $row.active_aliases)
    $oldEdges = @(Split-ListValue $row.old_aliases)
    return [pscustomobject]@{
        Name = [string]$row.name
        ActiveEdges = $activeEdges
        OldEdges = $oldEdges
        ActiveSet = @{}
        OldSet = @{}
    }
}

function Initialize-TopologySets($Topology) {
    foreach ($edge in $Topology.ActiveEdges) {
        $Topology.ActiveSet[$edge] = $true
    }
    foreach ($edge in $Topology.OldEdges) {
        $Topology.OldSet[$edge] = $true
    }
    return $Topology
}

function Get-ProfileMap($Policy) {
    $map = @{}
    foreach ($profile in @($Policy.profiles)) {
        $name = [string]$profile.name
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $map[$name] = $profile
        }
    }
    return $map
}

function Find-PolicyProfile($Policy, $Name) {
    $matches = @($Policy.profiles | Where-Object { ([string]$_.name) -eq ([string]$Name) })
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches[0]
}

function Get-ActiveProfileEdges($Profile, $Topology) {
    $edges = New-Object System.Collections.Generic.List[string]
    foreach ($ingress in @($Profile.candidate_ingress_aliases)) {
        foreach ($egress in @($Profile.candidate_fallback_egress_aliases)) {
            $edge = "$ingress>$egress"
            if (($Topology.ActiveEdges -contains $edge) -or $Topology.ActiveSet.ContainsKey($edge)) {
                [void]$edges.Add($edge)
            }
        }
    }
    return @($edges.ToArray() | Sort-Object -Unique)
}

function Get-RouteSteps($RouteState) {
    $steps = @()
    if ($RouteState.PSObject.Properties.Name -contains "steps") {
        $steps = @($RouteState.steps)
    }
    return @($steps | Where-Object { $_ })
}

function Get-StringArray($Items) {
    return @($Items | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-TargetMatches($Step, $TargetFilter) {
    if ($TargetFilter.Count -eq 0) {
        return $true
    }
    return $TargetFilter -contains ([string]$Step.target)
}

function Test-ProfileMatches($Step, $ProfileFilter) {
    if ($ProfileFilter.Count -eq 0) {
        return $true
    }
    return $ProfileFilter -contains ([string]$Step.profile)
}

function Get-StaleAppliedRoutes($AppliedRoutesDir, $Topology, $ProfileFilter, $TargetFilter) {
    Require-Directory $AppliedRoutesDir "applied routes directory"
    $items = New-Object System.Collections.Generic.List[object]
    $files = @(Get-ChildItem -LiteralPath $AppliedRoutesDir -File -Filter "*.json" | Sort-Object Name)
    foreach ($file in $files) {
        $state = Read-JsonFile $file.FullName "applied route state"
        $steps = @(Get-RouteSteps $state | Where-Object {
            (Test-ProfileMatches $_ $ProfileFilter) -and (Test-TargetMatches $_ $TargetFilter)
        })
        if ($steps.Count -eq 0) {
            continue
        }

        $staleSteps = @()
        foreach ($step in $steps) {
            $edge = "$($step.ingress_alias)>$($step.egress_alias)"
            if (-not $Topology.ActiveSet.ContainsKey($edge)) {
                $staleSteps += [pscustomobject]@{
                    Step = $step
                    Edge = $edge
                    Retired = $Topology.OldSet.ContainsKey($edge)
                }
            }
        }
        if ($staleSteps.Count -eq 0) {
            continue
        }

        $targets = @(Get-StringArray ($steps | ForEach-Object { $_.target }) | Sort-Object -Unique)
        $ports = @(Get-StringArray ($steps | ForEach-Object { $_.port }) | Sort-Object -Unique)
        $profiles = @(Get-StringArray ($steps | ForEach-Object { $_.profile }) | Sort-Object -Unique)
        $staleEdges = @(Get-StringArray ($staleSteps | ForEach-Object { $_.Edge }) | Sort-Object -Unique)
        $retiredEdges = @(Get-StringArray ($staleSteps | Where-Object { $_.Retired } | ForEach-Object { $_.Edge }) | Sort-Object -Unique)

        [void]$items.Add([pscustomobject]@{
            ProposalId = [string]$state.proposal_id
            Path = $file.FullName
            Profiles = $profiles
            Targets = $targets
            Ports = $ports
            StaleEdges = $staleEdges
            RetiredEdges = $retiredEdges
            AllStaleEdgesRetired = ($staleEdges.Count -gt 0 -and $staleEdges.Count -eq $retiredEdges.Count)
        })
    }
    return $items.ToArray()
}

function Get-ProposalPathById($ProposalDir, $Id) {
    return Join-Path $ProposalDir "$Id.json"
}

function Test-DeterministicProposal($Proposal) {
    if ($Proposal.status -ne "accepted" -or $Proposal.type -ne "fallback_available") {
        return $false
    }
    if (-not $RequireDeterministic) {
        return $true
    }
    if ($Proposal.source -ne "deterministic_probe") {
        return $false
    }
    if (-not $Proposal.operator_decision) {
        return $false
    }
    return ([string]$Proposal.operator_decision.operator) -eq "auto:deterministic-fallback"
}

function Get-ProposalEdge($Proposal) {
    if (-not $Proposal.recommended_path) {
        return ""
    }
    return "$($Proposal.recommended_path.ingress_alias)>$($Proposal.recommended_path.egress_alias)"
}

function Get-ProposalTargetValue($Proposal) {
    if ($Proposal.target -and ($Proposal.target.PSObject.Properties.Name -contains "value")) {
        return [string]$Proposal.target.value
    }
    return [string]$Proposal.target
}

function Get-ProposalTargetPort($Proposal) {
    if ($Proposal.PSObject.Properties.Name -contains "port" -and -not [string]::IsNullOrWhiteSpace([string]$Proposal.port)) {
        return [string]$Proposal.port
    }
    if ($Proposal.target -and ($Proposal.target.PSObject.Properties.Name -contains "port")) {
        return [string]$Proposal.target.port
    }
    return ""
}

function Get-ProfileTargetSet($Policy, $ProfileFilter, $TargetFilter) {
    $set = @{}
    foreach ($profile in @($Policy.profiles)) {
        $profileName = [string]$profile.name
        if ($ProfileFilter.Count -gt 0 -and -not ($ProfileFilter -contains $profileName)) {
            continue
        }
        foreach ($target in @($profile.targets)) {
            $targetValue = [string]$target.value
            if ($TargetFilter.Count -gt 0 -and -not ($TargetFilter -contains $targetValue)) {
                continue
            }
            $set["$profileName|$targetValue|$($target.port)"] = $true
        }
    }
    return $set
}

function Get-ApplicableReplacementProposals($ProposalDir, $StaleRoutes, $Topology) {
    Require-Directory $ProposalDir "proposal directory"
    $targetSet = @{}
    $profileSet = @{}
    foreach ($route in $StaleRoutes) {
        foreach ($target in $route.Targets) { $targetSet[$target] = $true }
        foreach ($profile in $route.Profiles) { $profileSet[$profile] = $true }
    }

    $items = New-Object System.Collections.Generic.List[object]
    $files = @(Get-ChildItem -LiteralPath $ProposalDir -File -Filter "*.json" | Sort-Object Name)
    foreach ($file in $files) {
        $proposal = Read-JsonFile $file.FullName "egress proposal"
        if (-not (Test-DeterministicProposal $proposal)) {
            continue
        }
        $profile = [string]$proposal.profile
        $target = Get-ProposalTargetValue $proposal
        $port = Get-ProposalTargetPort $proposal
        if ($profileSet.Count -gt 0 -and -not $profileSet.ContainsKey($profile)) {
            continue
        }
        if ($targetSet.Count -gt 0 -and -not $targetSet.ContainsKey($target)) {
            continue
        }
        $edge = Get-ProposalEdge $proposal
        if (-not $Topology.ActiveSet.ContainsKey($edge)) {
            continue
        }
        [void]$items.Add([pscustomobject]@{
            Id = [string]$proposal.id
            Profile = $profile
            Target = $target
            Port = $port
            Edge = $edge
            Path = $file.FullName
        })
    }
    return $items.ToArray()
}

function Get-ApplicableAcceptedProposals($ProposalDir, $Topology, $Policy, $ProfileFilter, $TargetFilter) {
    Require-Directory $ProposalDir "proposal directory"
    $allowedTargets = Get-ProfileTargetSet $Policy $ProfileFilter $TargetFilter
    $items = New-Object System.Collections.Generic.List[object]
    $files = @(Get-ChildItem -LiteralPath $ProposalDir -File -Filter "*.json" | Sort-Object Name)
    foreach ($file in $files) {
        $proposal = Read-JsonFile $file.FullName "egress proposal"
        if (-not (Test-DeterministicProposal $proposal)) {
            continue
        }
        $profile = [string]$proposal.profile
        $target = Get-ProposalTargetValue $proposal
        $port = Get-ProposalTargetPort $proposal
        if ($allowedTargets.Count -gt 0 -and -not $allowedTargets.ContainsKey("$profile|$target|$port")) {
            continue
        }
        $edge = Get-ProposalEdge $proposal
        if (-not $Topology.ActiveSet.ContainsKey($edge)) {
            continue
        }
        [void]$items.Add([pscustomobject]@{
            Id = [string]$proposal.id
            Profile = $profile
            Target = $target
            Port = $port
            Edge = $edge
            Path = $file.FullName
        })
    }
    return $items.ToArray()
}

function Assert-LastExitCode($Label) {
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label failed with exit code $LASTEXITCODE"
    }
}

function Require-ChildScript($ScriptPath, $Label) {
    Require-File $ScriptPath $Label
    Write-Host "[RUN] $Label"
}

function Format-ListCell($Items) {
    $values = @(Get-StringArray $Items)
    if ($values.Count -eq 0) {
        return "-"
    }
    return ($values -join ",")
}

if ($Check -and $Apply) {
    Fail "use either -Check or -Apply, not both"
}
if (-not $Check -and -not $Apply) {
    $Check = $true
}
if ($ProbeTimeoutSeconds -lt 1) {
    Fail "-ProbeTimeoutSeconds must be at least 1"
}
if ($ProbeAttempts -lt 1) {
    Fail "-ProbeAttempts must be at least 1"
}
if ($ProbeRetryDelaySeconds -lt 0) {
    Fail "-ProbeRetryDelaySeconds must be 0 or greater"
}

Require-File $PolicyFile "egress policy file"
$policy = Read-JsonFile $PolicyFile "egress policy"
$profileMap = Get-ProfileMap $policy
$profileFilter = @(Get-StringArray $ProfileName)
$targetFilter = @(Get-StringArray $TargetDomain)

foreach ($profile in $profileFilter) {
    if (-not $profileMap.ContainsKey($profile)) {
        Fail "egress profile not found: $profile"
    }
}

$topology = Initialize-TopologySets (Get-CascadeTopology (Read-StateRows $StateFile))
$staleRoutes = @(Get-StaleAppliedRoutes $AppliedRoutesDir $topology $profileFilter $targetFilter)
$plan = New-Object System.Collections.Generic.List[object]
foreach ($route in $staleRoutes) {
    $activeCandidates = New-Object System.Collections.Generic.List[string]
    foreach ($profileName in $route.Profiles) {
        $profile = Find-PolicyProfile $policy $profileName
        if ($profile) {
            foreach ($edge in @(Get-ActiveProfileEdges $profile $topology)) {
                [void]$activeCandidates.Add($edge)
            }
        }
    }
    [void]$plan.Add([pscustomobject]@{
        proposal_id = $route.ProposalId
        profiles = Format-ListCell $route.Profiles
        targets = Format-ListCell $route.Targets
        ports = Format-ListCell $route.Ports
        stale_edges = Format-ListCell $route.StaleEdges
        retired_edges = Format-ListCell $route.RetiredEdges
        active_candidates = Format-ListCell (@($activeCandidates.ToArray() | Sort-Object -Unique))
        action = if ($Apply) { "probe,suggest,rollback,apply,refresh" } else { "plan only" }
    })
}

if ($staleRoutes.Count -gt 0) {
    Write-Host "Selective fallback stale-route plan:"
    foreach ($item in $plan) {
        Write-Host ("  {0}" -f $item.proposal_id)
        Write-Host ("    profile: {0}; targets: {1}; ports: {2}" -f $item.profiles, $item.targets, $item.ports)
        Write-Host ("    stale: {0}; retired: {1}; active candidates: {2}" -f $item.stale_edges, $item.retired_edges, $item.active_candidates)
        Write-Host ("    action: {0}" -f $item.action)
    }
} else {
    Write-Host "No stale selective fallback applied routes matched the selected filters."
    $acceptedPlan = @(Get-ApplicableAcceptedProposals $ProposalDir $topology $policy $profileFilter $targetFilter)
    if ($acceptedPlan.Count -eq 0) {
        Write-Host "No accepted deterministic active fallback proposals matched the selected filters."
        exit 0
    }
    Write-Host "Accepted deterministic active fallback proposals available for apply:"
    foreach ($proposal in $acceptedPlan) {
        Write-Host ("  {0}: {1}:{2} {3}" -f $proposal.Id, $proposal.Target, $proposal.Port, $proposal.Edge)
    }
    if ($Check) {
        Write-Host "Check mode: no apply or refresh was run."
        exit 0
    }
    $applyIds = @(Get-StringArray ($acceptedPlan | ForEach-Object { $_.Id }) | Sort-Object -Unique)
    $label = "apply active selective fallback routes"
    Require-ChildScript $ApplyScript $label
    & $ApplyScript -Action apply -Id $applyIds -SshPath $SshPath
    Assert-LastExitCode $label

    $refreshProfiles = @(Get-StringArray ($acceptedPlan | ForEach-Object { $_.Profile }) | Sort-Object -Unique)
    $refreshDomains = @(Get-StringArray ($acceptedPlan | ForEach-Object { $_.Target }) | Sort-Object -Unique)
    $label = "refresh selective fallback DNS sets"
    Require-ChildScript $RefreshScript $label
    & $RefreshScript -Apply -Verify -Profile $refreshProfiles -Domain $refreshDomains -SshPath $SshPath
    Assert-LastExitCode $label
    Write-Host "Selective fallback reconciliation completed."
    exit 0
}

if ($Check) {
    Write-Host "Check mode: no probe, rollback, apply, or refresh was run."
    exit 0
}

$profilesToProbe = @()
foreach ($route in $staleRoutes) {
    foreach ($profile in $route.Profiles) {
        $profilesToProbe += $profile
    }
}
$profilesToProbe = @($profilesToProbe | Sort-Object -Unique)

foreach ($profile in $profilesToProbe) {
    $label = "probe egress policy profile $profile"
    Require-ChildScript $ProbeScript $label
    & $ProbeScript `
        -PolicyFile $PolicyFile `
        -Profile $profile `
        -IncludeCascade `
        -SshPath $SshPath `
        -TimeoutSeconds $ProbeTimeoutSeconds `
        -ProbeAttempts $ProbeAttempts `
        -ProbeRetryDelaySeconds $ProbeRetryDelaySeconds
    Assert-LastExitCode $label
}

$label = "suggest egress policy from latest probes"
Require-ChildScript $SuggestScript $label
& $SuggestScript -PolicyFile $PolicyFile -ProposalDir $ProposalDir -Latest -Force
Assert-LastExitCode $label

$replacementProposals = @(Get-ApplicableReplacementProposals $ProposalDir $staleRoutes $topology)
if ($replacementProposals.Count -eq 0) {
    $retiredOnly = @($staleRoutes | Where-Object { $_.AllStaleEdgesRetired })
    $missingTargets = @($staleRoutes | ForEach-Object {
        $route = $_
        foreach ($target in $route.Targets) {
            foreach ($port in $route.Ports) {
                "${target}:$port"
            }
        }
    } | Sort-Object -Unique)
    if ($retiredOnly.Count -ne $staleRoutes.Count -or -not $AllowRollbackOnly) {
        Fail "no deterministic accepted proposal on an active cascade edge was produced; rollback skipped. missing replacement targets: $($missingTargets -join ', ')"
    }
    Write-Warning "No deterministic active replacement proposal was produced. Retired stale routes will be rolled back, but no replacement will be applied."
} else {
    Write-Host "Accepted deterministic active replacement proposals:"
    foreach ($proposal in $replacementProposals) {
        Write-Host ("  {0}: {1}:{2} {3}" -f $proposal.Id, $proposal.Target, $proposal.Port, $proposal.Edge)
    }
}

$rollbackIds = @(Get-StringArray ($staleRoutes | ForEach-Object { $_.ProposalId }) | Sort-Object -Unique)
Write-Host "Rollback ids: $(Format-ListCell $rollbackIds)"
if ($rollbackIds.Count -gt 0) {
    $label = "rollback stale selective fallback routes"
    Require-ChildScript $ApplyScript $label
    & $ApplyScript -Action rollback -Id $rollbackIds -SshPath $SshPath
    Assert-LastExitCode $label
}

$applyIds = @(Get-StringArray ($replacementProposals | ForEach-Object { $_.Id }) | Sort-Object -Unique)
Write-Host "Apply ids: $(Format-ListCell $applyIds)"
if ($applyIds.Count -gt 0) {
    $label = "apply active selective fallback routes"
    Require-ChildScript $ApplyScript $label
    & $ApplyScript -Action apply -Id $applyIds -SshPath $SshPath
    Assert-LastExitCode $label

    $refreshProfiles = @(Get-StringArray ($replacementProposals | ForEach-Object { $_.Profile }) | Sort-Object -Unique)
    $refreshDomains = @(Get-StringArray ($replacementProposals | ForEach-Object { $_.Target }) | Sort-Object -Unique)
    $label = "refresh selective fallback DNS sets"
    Require-ChildScript $RefreshScript $label
    & $RefreshScript -Apply -Verify -Profile $refreshProfiles -Domain $refreshDomains -SshPath $SshPath
    Assert-LastExitCode $label
}

Write-Host "Selective fallback reconciliation completed."
