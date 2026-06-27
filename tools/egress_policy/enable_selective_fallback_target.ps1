param(
    [Parameter(Mandatory = $true)]
    [string]$Domain,
    [string]$IngressAlias = "",
    [string]$EgressAlias = "",
    [int[]]$Ports = @(80, 443),
    [string]$Profile = "vps4_test_fallback",
    [string]$ProposalDir = ".\operator\egress_policy\proposals",
    [string]$PolicyFile = ".\operator\egress_policy\profiles.json",
    [string]$StateFile = ".\operator\state.csv",
    [string]$CascadeFile = ".\operator\softether\cascade\secrets\lab-cascade.json",
    [string]$ApplyScript = ".\tools\egress_policy\apply_selective_fallback_routes.ps1",
    [switch]$Apply,
    [switch]$Verify,
    [switch]$Replace,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function ConvertTo-SafeIdPart($Value) {
    $text = ([string]$Value).Trim().ToLowerInvariant()
    $text = $text -replace '[^a-z0-9]+', '-'
    $text = $text.Trim('-')
    if ([string]::IsNullOrWhiteSpace($text)) {
        Fail "value cannot be converted to a stable id part: $Value"
    }
    return $text
}

function Get-ProtocolForPort($Port) {
    switch ([int]$Port) {
        80 { return "http" }
        443 { return "https" }
        default { return "tcp" }
    }
}

function Assert-Alias($Value, $Label) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[a-z][a-z0-9_-]*$') {
        Fail "$Label must match ^[a-z][a-z0-9_-]*`$: $Value"
    }
}

function Assert-Profile($Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[a-z][a-z0-9_]*$') {
        Fail "-Profile must match ^[a-z][a-z0-9_]*`$: $Value"
    }
}

function Read-JsonFile($Path) {
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        Fail "failed to parse JSON: $Path"
    }
}

function Get-PropertyArray($Object, $Name) {
    if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -contains $Name)) {
        return @()
    }
    return @($Object.$Name | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
}

function Read-StateRows($Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "state.csv not found: $Path"
    }
    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -eq 0 -or $lines[0] -ne $ExpectedStateHeader) {
        Fail "state.csv header must be exactly: $ExpectedStateHeader"
    }
    return @(Import-Csv -LiteralPath $Path)
}

function Split-AliasList($Value) {
    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return @()
    }
    return @(([string]$Value).Split("+", [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-ActiveCascadeEdges($StateRows) {
    $rows = @($StateRows | Where-Object { $_.kind -eq "cascade_topology" -and $_.state -eq "present" })
    if ($rows.Count -eq 0) {
        Fail "cascade_topology row not found in state.csv"
    }
    if ($rows.Count -gt 1) {
        Fail "multiple present cascade_topology rows found in state.csv"
    }
    return @(Split-AliasList $rows[0].active_aliases)
}

function Resolve-FallbackPath($ProfileName, $IngressOverride, $EgressOverride) {
    $hasIngressOverride = -not [string]::IsNullOrWhiteSpace($IngressOverride)
    $hasEgressOverride = -not [string]::IsNullOrWhiteSpace($EgressOverride)
    if ($hasIngressOverride -xor $hasEgressOverride) {
        Fail "pass both -IngressAlias and -EgressAlias, or omit both to auto-select from -Profile"
    }

    $policy = $null
    if (Test-Path -LiteralPath $PolicyFile -PathType Leaf) {
        $policy = Read-JsonFile $PolicyFile
    }
    $cascade = $null
    if (Test-Path -LiteralPath $CascadeFile -PathType Leaf) {
        $cascade = Read-JsonFile $CascadeFile
    }

    if ($hasIngressOverride -and $hasEgressOverride) {
        $ingress = [string]$IngressOverride
        $egress = [string]$EgressOverride
    } else {
        if (-not $policy) {
            Fail "policy profile file not found; pass -IngressAlias and -EgressAlias explicitly or create $PolicyFile"
        }
        $profiles = @($policy.profiles | Where-Object { $_.name -eq $ProfileName })
        if ($profiles.Count -eq 0) {
            Fail "egress profile not found: $ProfileName. Pass -IngressAlias/-EgressAlias or create the profile."
        }
        if ($profiles.Count -gt 1) {
            Fail "egress profile is duplicated: $ProfileName"
        }
        $profileObject = $profiles[0]
        $anchorSet = @{}
        foreach ($aliasName in @(Get-PropertyArray $profileObject "ingress_anchor_aliases" | Sort-Object -Unique)) {
            $anchorSet[$aliasName] = $true
        }
        if ($anchorSet.Count -eq 0) {
            Fail "profile $ProfileName must include ingress_anchor_aliases. Pass -IngressAlias and -EgressAlias explicitly for a one-off path."
        }
        $matchingEdges = @(Get-ActiveCascadeEdges (Read-StateRows $StateFile) | Where-Object {
            $_ -match '^([^>]+)>([^>]+)$' -and $anchorSet.ContainsKey($Matches[1])
        })
        if ($matchingEdges.Count -ne 1) {
            Fail "profile $ProfileName does not resolve to exactly one active fallback path in state.csv. Pass -IngressAlias and -EgressAlias explicitly."
        }
        $matchingEdges[0] -match '^([^>]+)>([^>]+)$' | Out-Null
        $ingress = $Matches[1]
        $egress = $Matches[2]
    }

    if (-not $cascade) {
        Fail "cascade graph file not found: $CascadeFile"
    }
    $activeLinks = @($cascade.links | Where-Object {
        ([string]$_.state -eq "" -or [string]$_.state -eq "active") -and
        [string]$_.ingress_alias -eq $ingress -and
        [string]$_.egress_alias -eq $egress
    })
    if ($activeLinks.Count -eq 0) {
        Fail "no active cascade link found for selected path $ingress -> $egress in $CascadeFile"
    }
    if ($activeLinks.Count -gt 1) {
        Fail "multiple active cascade links found for selected path $ingress -> $egress in $CascadeFile"
    }
    $connection = [string]$activeLinks[0].connection_name
    if ([string]::IsNullOrWhiteSpace($connection)) {
        $connection = "$ingress-to-$egress"
    }
    return [pscustomobject]@{
        ingress_alias = $ingress
        egress_alias = $egress
        cascade_connection = $connection
    }
}

function Test-ProposalEquivalent($Proposal, $Expected) {
    if ($Proposal.schema_version -ne $Expected.schema_version) { return $false }
    if ([string]$Proposal.id -ne [string]$Expected.id) { return $false }
    if ([string]$Proposal.type -ne [string]$Expected.type) { return $false }
    if ([string]$Proposal.status -ne [string]$Expected.status) { return $false }
    if ([string]$Proposal.profile -ne [string]$Expected.profile) { return $false }
    if ([string]$Proposal.target.type -ne [string]$Expected.target.type) { return $false }
    if ([string]$Proposal.target.value -ne [string]$Expected.target.value) { return $false }
    if ([string]$Proposal.target.protocol -ne [string]$Expected.target.protocol) { return $false }
    if ([int]$Proposal.target.port -ne [int]$Expected.target.port) { return $false }
    if ([string]$Proposal.recommended_path.mode -ne [string]$Expected.recommended_path.mode) { return $false }
    if ([string]$Proposal.recommended_path.ingress_alias -ne [string]$Expected.recommended_path.ingress_alias) { return $false }
    if ([string]$Proposal.recommended_path.egress_alias -ne [string]$Expected.recommended_path.egress_alias) { return $false }
    if ([string]$Proposal.recommended_path.cascade_connection -ne [string]$Expected.recommended_path.cascade_connection) { return $false }
    return $true
}

function New-Proposal($Id, $DomainValue, $Port, $Protocol, $ProfileName, $Path) {
    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $ingress = [string]$Path.ingress_alias
    $egress = [string]$Path.egress_alias
    $connection = [string]$Path.cascade_connection
    return [ordered]@{
        schema_version = 1
        id = $Id
        type = "fallback_available"
        human_type = "Fallback available"
        status = "accepted"
        human_status = "Accepted"
        created_at_utc = $now
        source = "semi_auto_selective_fallback_target"
        generator = "enable_selective_fallback_target.ps1"
        profile = $ProfileName
        target = [ordered]@{
            type = "domain"
            value = $DomainValue
            protocol = $Protocol
            port = [int]$Port
            path = "/"
        }
        recommended_path = [ordered]@{
            mode = "cascade"
            ingress_alias = $ingress
            egress_alias = $egress
            cascade_connection = $connection
            cascade_connections = $connection
            cascade_path = [ordered]@{
                connection = $connection
                ingress_alias = $ingress
                egress_alias = $egress
            }
            effective_country = $null
            http_status = $null
            response_ms = $null
        }
        reason = "Operator-approved semi-auto selective fallback target onboarding for ${DomainValue}:${Port} via $ingress -> $egress."
        human_summary = "Semi-auto selective fallback target for ${DomainValue}:${Port}."
        rollback = "Run apply_selective_fallback_routes.ps1 -Action rollback -Id $Id to remove persisted exact routes and scoped NAT rules."
        evidence = [ordered]@{
            source_history_file = $null
            run_id = "semi-auto-$($now -replace '[-:]', '')"
            summary = "Operator requested selective fallback onboarding for $DomainValue on port $Port."
            observations = @(
                [ordered]@{
                    mode = "cascade"
                    ingress_alias = $ingress
                    egress_alias = $egress
                    cascade_connection = $connection
                    effective_country = $null
                    effective_ip = $null
                    http_status = $null
                    response_ms = $null
                    recommendation = "fallback_available"
                    attempts_used = 0
                    attempts_total = 0
                }
            )
        }
        ai_advisory = $null
        operator_decision = [ordered]@{
            status = "accepted"
            human_status = "Accepted"
            previous_status = "none"
            previous_human_status = "None"
            reason = "Operator explicitly enabled semi-auto selective fallback for $DomainValue."
            operator = "manual:operator"
            decided_at_utc = $now
        }
    }
}

function Invoke-SelectiveFallbackRouteScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RouteAction,
        [Parameter(Mandatory = $true)]
        [string]$ProposalId,
        [switch]$SkipVerify
    )
    $scriptPath = (Resolve-Path -LiteralPath $ApplyScript).Path
    Write-Host "[INFO] invoking route script: $scriptPath -Action $RouteAction -Id $ProposalId"
    & $scriptPath -Action $RouteAction -Id $ProposalId -SkipVerify:$SkipVerify
    if ($LASTEXITCODE -ne 0) {
        Fail "apply script failed: $scriptPath -Action $RouteAction -Id $ProposalId"
    }
}

function Write-Proposal($Path, $Proposal, $ReplaceExisting) {
    $existing = $null
    $status = "created"
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existing = Read-JsonFile $Path
        if (Test-ProposalEquivalent $existing ([pscustomobject]$Proposal)) {
            return "reused"
        }
        if (-not $ReplaceExisting) {
            Fail "proposal already exists with different content: $Path. Pass -Replace to overwrite it."
        }
        $status = "replaced"
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $Proposal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
    return $status
}

$Domain = $Domain.Trim().ToLowerInvariant()
if ($Domain -notmatch '^[a-z0-9][a-z0-9.-]*[a-z0-9]$') {
    Fail "-Domain must be a DNS name: $Domain"
}
if (-not [string]::IsNullOrWhiteSpace($IngressAlias)) {
    Assert-Alias $IngressAlias "-IngressAlias"
}
if (-not [string]::IsNullOrWhiteSpace($EgressAlias)) {
    Assert-Alias $EgressAlias "-EgressAlias"
}
Assert-Profile $Profile
$fallbackPath = Resolve-FallbackPath $Profile $IngressAlias $EgressAlias
$IngressAlias = [string]$fallbackPath.ingress_alias
$EgressAlias = [string]$fallbackPath.egress_alias
Assert-Alias $IngressAlias "resolved ingress alias"
Assert-Alias $EgressAlias "resolved egress alias"
if ($IngressAlias -eq $EgressAlias) {
    Fail "-IngressAlias and -EgressAlias must be different for selective fallback onboarding"
}

$portsToEnable = @($Ports | Sort-Object -Unique)
if ($portsToEnable.Count -eq 0) {
    Fail "-Ports must include at least one port"
}
foreach ($port in $portsToEnable) {
    if ($port -le 0 -or $port -gt 65535) {
        Fail "-Ports values must be in 1..65535: $port"
    }
}

if (($Apply -or $Verify) -and -not (Test-Path -LiteralPath $ApplyScript -PathType Leaf)) {
    Fail "apply script not found: $ApplyScript"
}

$profileId = ConvertTo-SafeIdPart $Profile
$domainId = ConvertTo-SafeIdPart $Domain
$results = @()

foreach ($port in $portsToEnable) {
    $protocol = Get-ProtocolForPort $port
    $proposalPrefix = "fallback-available-$profileId"
    if (-not $profileId.EndsWith("-fallback")) {
        $proposalPrefix = "$proposalPrefix-fallback"
    }
    $proposalId = "$proposalPrefix-$domainId-$port"
    $proposalPath = Join-Path $ProposalDir "$proposalId.json"
    $proposal = New-Proposal $proposalId $Domain $port $protocol $Profile $fallbackPath
    $proposalStatus = Write-Proposal $proposalPath $proposal $Replace

    $applyStatus = "not_requested"
    $verifyStatus = "not_requested"
    if ($Apply) {
        Invoke-SelectiveFallbackRouteScript -RouteAction "refresh" -ProposalId $proposalId -SkipVerify
        $applyStatus = "refreshed"
    }
    if ($Apply -or $Verify) {
        Invoke-SelectiveFallbackRouteScript -RouteAction "verify" -ProposalId $proposalId
        $verifyStatus = "verified"
    }

    $results += [pscustomobject]@{
        id = $proposalId
        domain = $Domain
        protocol = $protocol
        port = [int]$port
        ingress_alias = $IngressAlias
        egress_alias = $EgressAlias
        proposal = $proposalStatus
        apply = $applyStatus
        verify = $verifyStatus
        proposal_path = $proposalPath
    }
}

if ($Json) {
    $results | ConvertTo-Json -Depth 5
} else {
    $results | Format-Table -AutoSize
}
