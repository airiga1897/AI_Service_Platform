param(
    [ValidateSet("plan", "apply", "verify", "rollback")]
    [string]$Action = "plan",
    [string]$Alias = "vps4",
    [string]$ProposalId = "fallback-available-vps4-test-fallback-mos-ru-443",
    [string]$AppliedRoutesDir = ".\operator\egress_policy\applied_routes",
    [string]$DefaultEgressStateDir = ".\operator\egress_policy\default_egress",
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$NetworksFile = ".\operator\networks.csv",
    [string]$OperatorDir = ".\operator",
    [string]$SshUser = "useradmin",
    [string]$SshPath = "ssh",
    [string]$EdgeSourceIp = "172.20.0.2",
    [int]$TimeoutSeconds = 10,
    [switch]$AutoAcceptHostKey = $true,
    [switch]$SkipCanaryStateCheck,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,connection,root_password"
$ExpectedNetworksHeader = "alias,policy_subnet,edge_ip,cascade_ip,cascade_router_ip,policy_gateway_ip"
$EdgeContainer = "softether-edge"
$PolicyGatewayContainer = "policy-gateway"
$StateSchemaVersion = 1

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Require-File($Path, $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Label not found: $Path"
    }
}

function Quote-BashArg($Value) {
    $text = [string]$Value
    return "'" + ($text -replace "'", "'\''") + "'"
}

function Resolve-SshExecutable($Path) {
    try {
        $command = Get-Command $Path -ErrorAction Stop
    } catch {
        Fail "SSH executable not found: $Path"
    }
    $resolvedPath = [string]$command.Path
    $lowerPath = $resolvedPath.ToLowerInvariant()
    if ($lowerPath -like "*.sbx-denybin*" -or $lowerPath.EndsWith(".bat") -or $lowerPath.EndsWith(".cmd")) {
        Fail "Resolved SSH path is not a real OpenSSH executable: $resolvedPath"
    }
    return $resolvedPath
}

function Get-OpenSshCommonArgs($KeyFile) {
    $args = @(
        "-i", $KeyFile,
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=$TimeoutSeconds",
        "-o", "IdentitiesOnly=yes",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "PasswordAuthentication=no",
        "-o", "PreferredAuthentications=publickey",
        "-o", "RequestTTY=no"
    )
    if ($AutoAcceptHostKey) {
        $args += @("-o", "StrictHostKeyChecking=accept-new")
    }
    return $args
}

function Invoke-SshText($AliasName, $Command) {
    $node = $script:Nodes[$AliasName]
    if (-not $node) {
        Fail "Unknown node alias: $AliasName"
    }
    $keyFile = Join-Path (Join-Path $OperatorDir $AliasName) "admin_key"
    Require-File $keyFile "admin key for $AliasName"
    $remote = "${SshUser}@$($node.endpoint)"
    $sshArgs = @("-n", "-T") + @(Get-OpenSshCommonArgs $keyFile) + @($remote, $Command)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $script:ErrorActionPreference = "Continue"
        $output = & $script:SshExecutablePath @sshArgs
        $exitCode = $LASTEXITCODE
    } finally {
        $script:ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        Fail "SSH command failed on ${AliasName}: $(@($output) -join "`n")"
    }
    return @($output) -join "`n"
}

function Load-CsvMap($Path, $ExpectedHeader, $KeyField, $Label) {
    Require-File $Path $Label
    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -eq 0 -or $lines[0] -ne $ExpectedHeader) {
        Fail "$Label header must be exactly: $ExpectedHeader"
    }
    $map = @{}
    foreach ($row in @(Import-Csv -LiteralPath $Path)) {
        $key = [string]$row.$KeyField
        if ($key) {
            $map[$key] = $row
        }
    }
    return $map
}

function Get-StatePath {
    return Join-Path $DefaultEgressStateDir "$Alias.json"
}

function Get-Comment {
    return "ai-sp:default-egress:$($Alias):ordinary-masq"
}

function Get-CanaryStatePath {
    return Join-Path $AppliedRoutesDir "$ProposalId.json"
}

function Get-StepDisplay {
    $network = $script:Networks[$Alias]
    if (-not $network) {
        Fail "networks.csv has no row for alias: $Alias"
    }
    $comment = Get-Comment
    return [pscustomobject]@{
        alias = $Alias
        edge_container = $EdgeContainer
        policy_gateway = $PolicyGatewayContainer
        policy_gateway_ip = [string]$network.policy_gateway_ip
        canary_state_required = -not [bool]$SkipCanaryStateCheck
        canary_state = Get-CanaryStatePath
        edge_default_route = "ip route replace default via $($network.policy_gateway_ip)"
        ordinary_nat = "iptables -t nat -A POSTROUTING -s $EdgeSourceIp/32 -m comment --comment '$comment' -j MASQUERADE"
        state_path = Get-StatePath
    }
}

function Read-State {
    $path = Get-StatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        Fail "Failed to parse default egress state: $path"
    }
}

function Write-State($PreviousDefaultRoute) {
    New-Item -ItemType Directory -Force -Path $DefaultEgressStateDir | Out-Null
    $network = $script:Networks[$Alias]
    $state = [ordered]@{
        schema_version = $StateSchemaVersion
        mode = "policy_gateway_default_egress"
        alias = $Alias
        applied_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        edge_container = $EdgeContainer
        policy_gateway_container = $PolicyGatewayContainer
        edge_source_ip = $EdgeSourceIp
        policy_gateway_ip = [string]$network.policy_gateway_ip
        previous_edge_default_route = [string]$PreviousDefaultRoute
        ordinary_nat_comment = Get-Comment
        canary_proposal_id = $ProposalId
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Get-StatePath) -Encoding utf8
}

function Test-Applied {
    $network = $script:Networks[$Alias]
    $gatewayRegex = [regex]::Escape([string]$network.policy_gateway_ip)
    $commentRegex = [regex]::Escape((Get-Comment))
    $edgeRoutes = Invoke-SshText $Alias "sudo docker exec -u 0 $(Quote-BashArg $EdgeContainer) ip route show default 2>/dev/null || true"
    $natRules = Invoke-SshText $Alias "sudo docker exec -u 0 $(Quote-BashArg $PolicyGatewayContainer) iptables -t nat -S POSTROUTING 2>/dev/null || true"
    $edgeOk = $edgeRoutes -match "(?m)^default\s+via\s+$gatewayRegex(\s|$)"
    $natOk = $natRules -match $commentRegex
    return [pscustomobject]@{
        alias = $Alias
        edge_default_via_gateway = [bool]$edgeOk
        ordinary_nat_present = [bool]$natOk
        ok = [bool]($edgeOk -and $natOk)
    }
}

$script:SshExecutablePath = Resolve-SshExecutable $SshPath
$script:Nodes = Load-CsvMap $NodesFile $ExpectedNodesHeader "current_alias" "nodes.csv"
$script:Networks = Load-CsvMap $NetworksFile $ExpectedNetworksHeader "alias" "networks.csv"

$display = Get-StepDisplay
if ($Json) {
    $display | ConvertTo-Json -Depth 8
} else {
    $display | Format-List
}

if ($Action -eq "plan") {
    exit 0
}

if ($Action -eq "apply") {
    if (-not $SkipCanaryStateCheck -and -not (Test-Path -LiteralPath (Get-CanaryStatePath) -PathType Leaf)) {
        Write-Host "[WAIT] Stage 1 canary state is required before default egress apply: $(Get-CanaryStatePath)"
        Write-Host "[WAIT] Run apply_selective_fallback_routes.ps1 first, verify the canary, then retry this command."
        exit 0
    }
    if (Read-State) {
        Write-Host "[OK] policy-gateway default egress state already exists for $Alias; verifying current state."
        $Action = "verify"
    }
}

if ($Action -eq "apply") {
    $network = $script:Networks[$Alias]
    $comment = Get-Comment
    $previousDefault = Invoke-SshText $Alias "sudo docker exec -u 0 $(Quote-BashArg $EdgeContainer) ip route show default 2>/dev/null || true"
    $gatewayCommand = "sudo docker exec -u 0 $(Quote-BashArg $PolicyGatewayContainer) sh -c $(Quote-BashArg "sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true; iptables -t nat -C POSTROUTING -s $EdgeSourceIp/32 -m comment --comment '$comment' -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $EdgeSourceIp/32 -m comment --comment '$comment' -j MASQUERADE")"
    Invoke-SshText $Alias $gatewayCommand | Out-Null
    Invoke-SshText $Alias "sudo docker exec -u 0 $(Quote-BashArg $EdgeContainer) ip route replace default via $(Quote-BashArg $network.policy_gateway_ip)" | Out-Null
    Write-State $previousDefault
    Write-Host "[OK] policy-gateway default egress applied for $Alias"
}

if ($Action -eq "verify" -or $Action -eq "apply") {
    $result = Test-Applied
    if ($Json) {
        $result | ConvertTo-Json -Depth 6
    } elseif ($result.ok) {
        Write-Host "[OK] verified policy-gateway default egress for $Alias"
    } else {
        Write-Host "[FAIL] policy-gateway default egress verification failed for $Alias"
    }
    if (-not $result.ok) {
        Fail "policy-gateway default egress verification failed"
    }
}

if ($Action -eq "rollback") {
    $state = Read-State
    if (-not $state) {
        Write-Host "No policy-gateway default egress state selected for $Alias."
        exit 0
    }
    $comment = if ($state.ordinary_nat_comment) { [string]$state.ordinary_nat_comment } else { Get-Comment }
    $rollbackDefault = [string]$state.previous_edge_default_route
    $restoreCommand = if ([string]::IsNullOrWhiteSpace($rollbackDefault)) {
        "sudo docker exec -u 0 $(Quote-BashArg $EdgeContainer) ip route del default 2>/dev/null || true"
    } else {
        "sudo docker exec -u 0 $(Quote-BashArg $EdgeContainer) sh -c $(Quote-BashArg "ip route replace $rollbackDefault")"
    }
    Invoke-SshText $Alias $restoreCommand | Out-Null
    Invoke-SshText $Alias "sudo docker exec -u 0 $(Quote-BashArg $PolicyGatewayContainer) sh -c $(Quote-BashArg "iptables -t nat -D POSTROUTING -s $EdgeSourceIp/32 -m comment --comment '$comment' -j MASQUERADE 2>/dev/null || true")" | Out-Null
    Remove-Item -LiteralPath (Get-StatePath) -Force
    Write-Host "[OK] policy-gateway default egress rolled back for $Alias"
}
