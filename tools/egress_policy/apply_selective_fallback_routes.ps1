param(
    [ValidateSet("plan", "apply", "rollback")]
    [string]$Action = "plan",
    [string]$ProposalDir = ".\operator\egress_policy\proposals",
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$NetworksFile = ".\operator\networks.csv",
    [string]$OperatorDir = ".\operator",
    [string[]]$Id = @(),
    [string]$SshUser = "useradmin",
    [string]$SshPath = "ssh",
    [int]$TimeoutSeconds = 10,
    [switch]$AutoAcceptHostKey = $true,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,connection,root_password"
$ExpectedNetworksHeader = "alias,policy_subnet,edge_ip,cascade_ip,cascade_router_ip"
$CascadeContainer = "softether-cascade"
$EdgeContainer = "softether-edge"
$TapInterface = "tap_vpnpolicy"

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Require-File($Path, $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Label not found: $Path"
    }
}

function Read-JsonFile($Path, $Label) {
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        Fail "Failed to parse ${Label}: $Path"
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
        if (-not $key) {
            continue
        }
        if ($map.ContainsKey($key)) {
            Fail "$Label has duplicate ${KeyField}: $key"
        }
        $map[$key] = $row
    }
    return $map
}

function Get-Proposals {
    if (-not (Test-Path -LiteralPath $ProposalDir -PathType Container)) {
        return @()
    }
    $filter = @($Id | Where-Object { $_ })
    $items = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $ProposalDir -Filter "*.json" -File | Sort-Object Name)) {
        $proposal = Read-JsonFile $file.FullName "proposal"
        if ($filter.Count -gt 0 -and $filter -notcontains $proposal.id) {
            continue
        }
        if ($proposal.status -ne "accepted" -or $proposal.type -ne "fallback_available") {
            continue
        }
        if (-not $proposal.recommended_path -or $proposal.recommended_path.mode -ne "cascade") {
            continue
        }
        $items += [pscustomobject]@{ Proposal = $proposal; Path = $file.FullName }
    }
    return $items
}

function Resolve-TargetIps($Target) {
    if ($Target.type -eq "ip") {
        return @([string]$Target.value)
    }
    try {
        return @([System.Net.Dns]::GetHostAddresses([string]$Target.value) |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
            ForEach-Object { $_.IPAddressToString } |
            Sort-Object -Unique)
    } catch {
        Fail "Failed to resolve target $($Target.value): $($_.Exception.Message)"
    }
}

function New-Step($Proposal, $TargetIp) {
    $path = $Proposal.recommended_path
    $ingress = [string]$path.ingress_alias
    $egress = [string]$path.egress_alias
    $ingressNetwork = $script:Networks[$ingress]
    $egressNetwork = $script:Networks[$egress]
    if (-not $ingressNetwork) { Fail "networks.csv has no row for ingress alias: $ingress" }
    if (-not $egressNetwork) { Fail "networks.csv has no row for egress alias: $egress" }
    return [pscustomobject]@{
        id = [string]$Proposal.id
        profile = [string]$Proposal.profile
        target = [string]$Proposal.target.value
        target_ip = [string]$TargetIp
        protocol = [string]$Proposal.target.protocol
        port = [int]$Proposal.target.port
        ingress_alias = $ingress
        egress_alias = $egress
        ingress_cascade_ip = [string]$ingressNetwork.cascade_ip
        ingress_edge_ip = [string]$ingressNetwork.edge_ip
        ingress_policy_subnet = [string]$ingressNetwork.policy_subnet
        ingress_router_ip = [string]$ingressNetwork.cascade_router_ip
        egress_router_ip = [string]$egressNetwork.cascade_router_ip
    }
}

function Invoke-StepApply($Step) {
    $comment = "ai-sp:$($Step.id):$($Step.target_ip)"
    $edgeCommand = @(
        "set -euo pipefail",
        "sudo docker exec $(Quote-BashArg $EdgeContainer) ip route replace $(Quote-BashArg "$($Step.target_ip)/32") via $(Quote-BashArg $Step.ingress_cascade_ip)"
    ) -join "; "
    Invoke-SshText $Step.ingress_alias $edgeCommand | Out-Null

    $ingressCascadeCommand = @(
        "set -euo pipefail",
        "sudo docker exec $(Quote-BashArg $CascadeContainer) sh -c $(Quote-BashArg "ip route replace $($Step.target_ip)/32 via $($Step.egress_router_ip) dev $TapInterface")"
    ) -join "; "
    Invoke-SshText $Step.ingress_alias $ingressCascadeCommand | Out-Null

    $egressCommand = @(
        "set -euo pipefail",
        "sudo docker exec $(Quote-BashArg $CascadeContainer) sh -c $(Quote-BashArg "ip route replace $($Step.ingress_policy_subnet) via $($Step.ingress_router_ip) dev $TapInterface; sysctl -w net.ipv4.ip_forward=1 >/dev/null; iptables -t nat -C POSTROUTING -d $($Step.target_ip)/32 -m comment --comment '$comment' -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -d $($Step.target_ip)/32 -m comment --comment '$comment' -j MASQUERADE")"
    ) -join "; "
    Invoke-SshText $Step.egress_alias $egressCommand | Out-Null
}

function Invoke-StepRollback($Step) {
    $comment = "ai-sp:$($Step.id):$($Step.target_ip)"
    Invoke-SshText $Step.ingress_alias ("sudo docker exec $(Quote-BashArg $EdgeContainer) ip route del $(Quote-BashArg "$($Step.target_ip)/32") 2>/dev/null || true") | Out-Null
    Invoke-SshText $Step.ingress_alias ("sudo docker exec $(Quote-BashArg $CascadeContainer) ip route del $(Quote-BashArg "$($Step.target_ip)/32") 2>/dev/null || true") | Out-Null
    $egressCommand = "sudo docker exec $(Quote-BashArg $CascadeContainer) sh -c $(Quote-BashArg "iptables -t nat -D POSTROUTING -d $($Step.target_ip)/32 -m comment --comment '$comment' -j MASQUERADE 2>/dev/null || true")"
    Invoke-SshText $Step.egress_alias $egressCommand | Out-Null
}

$script:SshExecutablePath = Resolve-SshExecutable $SshPath
$script:Nodes = Load-CsvMap $NodesFile $ExpectedNodesHeader "current_alias" "nodes.csv"
$script:Networks = Load-CsvMap $NetworksFile $ExpectedNetworksHeader "alias" "networks.csv"
$proposals = @(Get-Proposals)
if ($proposals.Count -eq 0) {
    Write-Host "No accepted fallback_available proposals selected."
    exit 0
}

$steps = @()
foreach ($item in $proposals) {
    foreach ($ip in @(Resolve-TargetIps $item.Proposal.target)) {
        $steps += New-Step $item.Proposal $ip
    }
}

if ($Json) {
    $steps | ConvertTo-Json -Depth 6
} else {
    $steps | Select-Object id, target, target_ip, protocol, port, ingress_alias, egress_alias, ingress_cascade_ip, egress_router_ip | Format-Table
}

if ($Action -eq "plan") {
    exit 0
}

foreach ($step in $steps) {
    if ($Action -eq "apply") {
        Invoke-StepApply $step
        Write-Host "[OK] applied selective fallback route $($step.id) -> $($step.target_ip)"
    } elseif ($Action -eq "rollback") {
        Invoke-StepRollback $step
        Write-Host "[OK] rolled back selective fallback route $($step.id) -> $($step.target_ip)"
    }
}
