param(
    [string]$NodesFile = ".\operator\nodes.csv",

    [string]$StateFile = ".\operator\state.csv",

    [string]$ControlRole = "orchestration",

    [string]$ControlAlias = "",

    [string]$OperatorDir = ".\operator",

    [string]$KnownHostsFile = "",

    [string]$SshUser = "useradmin",

    [string]$SshKeyFile = "",

    [string]$RemoteNodesFile = "/tmp/ai-service-platform.nodes.csv",

    [string]$SoftetherDir = ".\operator\softether",

    [string]$RemoteSoftetherDir = "/tmp/ai-service-platform.softether",

    [string]$HaproxyDir = ".\operator\haproxy",

    [string]$RemoteHaproxyDir = "/tmp/ai-service-platform.haproxy",

    [string]$EgressPolicyDir = ".\operator\egress_policy",

    [string]$RemoteEgressPolicyDir = "/tmp/ai-service-platform.egress_policy",

    [string]$EdgeBanlistDir = ".\operator\edge_banlist",

    [string]$RemoteEdgeBanlistDir = "/tmp/ai-service-platform.edge_banlist",

    [string]$PostgresDir = ".\operator\postgres",

    [string]$RemotePostgresDir = "/tmp/ai-service-platform.postgres",

    [string]$PlatformNetworksDir = ".\operator\platform_networks",

    [string]$RemotePlatformNetworksDir = "/tmp/ai-service-platform.platform_networks",

    [string]$NetworksFile = ".\operator\networks.csv",

    [string]$NetworksOverrideFile = ".\operator\networks.override.csv",

    [string]$GenerateNetworkPlanScript = "tools/network/generate_vpn_network_plan.ps1",

    [string]$RemoteNetworksFile = "/tmp/ai-service-platform.networks.csv",

    [string]$RemotePrepareScript = "/opt/ai-service-platform/tools/bootstrap/prepare_orchestration_inventory.sh",

    [string]$CreateInventoryScript = "tools/bootstrap/create_inventory.sh",

    [string]$PrepareInventoryScript = "tools/bootstrap/prepare_orchestration_inventory.sh",

    [string]$VerifyControlScript = "tools/bootstrap/verify_control_node.sh",

    [string]$RemoteVerifyScript = "/opt/ai-service-platform/tools/bootstrap/verify_control_node.sh",

    [string]$Include = "",

    [switch]$AutoAcceptHostKey = $true,

    [switch]$FixKeyAcl,

    [switch]$SkipVerify,

    [int]$VerifyRetries = 3,

    [int]$VerifyRetryDelaySeconds = 5,

    [int]$VerifyAnsibleTimeoutSeconds = 20,

    [int]$SshTransferRetries = 6,

    [int]$SshTransferRetryDelaySeconds = 5,

    [switch]$SkipServicePlan
)

$ErrorActionPreference = "Stop"
$ExpectedHeader = "current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$IsWindowsPlatform = ($PSVersionTable.PSEdition -eq "Desktop") -or ($PSVersionTable.ContainsKey("Platform") -and $PSVersionTable.Platform -eq "Win32NT") -or ($env:OS -eq "Windows_NT")
. (Join-Path $PSScriptRoot "..\common\private_key_acl.ps1")

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Require-File($Path, $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Label not found: $Path"
    }
}

function Write-AsciiNoBomLines($Path, $Lines) {
    $text = (($Lines | ForEach-Object { [string]$_ }) -join "`n") + "`n"
    $encoding = New-Object System.Text.ASCIIEncoding
    [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Path), $text, $encoding)
}

function Format-HexPrefix($Bytes, $Count) {
    if (-not $Bytes -or $Bytes.Length -eq 0) {
        return ""
    }
    $last = [Math]::Min($Bytes.Length, $Count) - 1
    return (($Bytes[0..$last] | ForEach-Object { "{0:X2}" -f $_ }) -join " ")
}

function Assert-SanitizedNodesFile($Path) {
    $firstLine = Get-Content -LiteralPath $Path -TotalCount 1
    if ($firstLine -eq $ExpectedHeader) {
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path))
    Write-Host ("Sanitized nodes.csv diagnostic: path={0}" -f $Path)
    Write-Host ("Sanitized nodes.csv diagnostic: first_line_length={0}" -f ([string]$firstLine).Length)
    Write-Host ("Sanitized nodes.csv diagnostic: first_bytes={0}" -f (Format-HexPrefix $bytes 32))
    Fail "sanitized nodes.csv header must be exactly: $ExpectedHeader"
}

function New-SanitizedNodesFile($SourcePath) {
    $tempFile = (New-TemporaryFile).FullName
    $sanitizedLines = New-Object System.Collections.Generic.List[string]
    $sanitizedLines.Add($ExpectedHeader)

    $lines = Get-Content -LiteralPath $SourcePath
    if (-not $lines -or $lines.Count -eq 0) {
        Fail "nodes.csv is empty: $SourcePath"
    }
    if ($lines[0] -ne $ExpectedHeader) {
        Fail "nodes.csv header must be exactly: $ExpectedHeader"
    }

    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        if (-not $line) {
            continue
        }
        $fields = $line -split ",", 7
        if ($fields.Count -ne 6) {
            Fail "nodes.csv row has invalid column count: $line"
        }
        $fields[5] = ""
        $sanitizedLines.Add(($fields -join ","))
    }

    Write-AsciiNoBomLines $tempFile $sanitizedLines
    Assert-SanitizedNodesFile $tempFile
    return $tempFile
}

function Get-NodeSshPort($Node) {
    $port = [string]$Node.ssh_port
    if (-not $port) {
        return "22"
    }
    $portNumber = 0
    if (-not [int]::TryParse($port, [ref]$portNumber) -or $portNumber -lt 1 -or $portNumber -gt 65535) {
        Fail "Invalid ssh_port for $($Node.current_alias): $port"
    }
    return [string]$portNumber
}

function Get-KnownHostTarget($Endpoint, $Port) {
    if ([string]$Port -eq "22") {
        return $Endpoint
    }
    return "[$Endpoint]:$Port"
}

function Split-AliasList($Value) {
    if (-not $Value) {
        return @()
    }
    return @($Value -split "\+" | Where-Object { $_ })
}

function Write-ServicePlan($NodeRows, $StateRows) {
    Write-Host ""
    Write-Host "========================================"
    Write-Host "  Service plan"
    Write-Host "========================================"

    $serviceRows = @($StateRows | Where-Object { $_.kind -eq "service" })
    if ($serviceRows.Count -eq 0) {
        Write-Host "No service rows found in state.csv"
        return
    }

    foreach ($service in $serviceRows) {
        $activeAliases = @(Split-AliasList $service.active_aliases)
        Write-Host ""
        Write-Host ("Service: {0}" -f $service.name)
        Write-Host ("  state:         {0}" -f $service.state)
        Write-Host ("  ansible_group: {0}" -f $service.ansible_group)

        foreach ($node in $NodeRows) {
            if (-not $node.current_alias) {
                continue
            }

            $desired = "absent"
            if ($service.state -eq "present" -and ($activeAliases -contains $node.current_alias)) {
                $desired = "present"
            }
            Write-Host ("  {0}: desired {1}" -f $node.current_alias, $desired)
        }

        if ($service.candidate_aliases) {
            Write-Host ("  candidates: {0}" -f $service.candidate_aliases)
        }
        if ($service.old_aliases) {
            Write-Host ("  old:        {0}" -f $service.old_aliases)
        }
    }

    $edgeRouteRows = @($StateRows | Where-Object { $_.kind -eq "edge_route" })
    foreach ($route in $edgeRouteRows) {
        $activeAliases = @(Split-AliasList $route.active_aliases)
        Write-Host ""
        Write-Host ("Edge route: {0}" -f $route.name)
        Write-Host ("  state:         {0}" -f $route.state)
        Write-Host ("  ansible_group: {0}" -f $route.ansible_group)

        foreach ($node in $NodeRows) {
            if (-not $node.current_alias) {
                continue
            }

            $desired = "absent"
            if ($route.state -eq "present" -and ($activeAliases -contains $node.current_alias)) {
                $desired = "present"
            }
            Write-Host ("  {0}: desired {1}" -f $node.current_alias, $desired)
        }
    }
}

function Resolve-ControlNodeFromState($NodeRows, $StateRows, $Role, $ExplicitAlias) {
    $roleRows = @($StateRows | Where-Object { ($_.kind -eq "platform_role" -or $_.kind -eq "role") -and $_.name -eq $Role -and $_.state -eq "present" })
    if ($roleRows.Count -eq 0) {
        Fail "No active control role found in state.csv: kind=platform_role,name=$Role,state=present"
    }
    if ($roleRows.Count -gt 1) {
        Fail "Multiple state.csv rows found for control role '$Role'. Keep exactly one row."
    }

    $activeAliases = @(Split-AliasList $roleRows[0].active_aliases)
    if ($ExplicitAlias) {
        if ($activeAliases -notcontains $ExplicitAlias) {
            Fail "Control alias $ExplicitAlias is not active for role '$Role' in state.csv."
        }
        $activeAliases = @($ExplicitAlias)
    }
    if ($activeAliases.Count -eq 0) {
        Fail "Control role '$Role' must have exactly one active_aliases value in state.csv."
    }
    if ($activeAliases.Count -gt 1) {
        Fail "Control role '$Role' has multiple active aliases in state.csv: $($activeAliases -join ', '). Keep one active alias and put reserve nodes in candidate_aliases."
    }

    $node = $NodeRows | Where-Object { $_.current_alias -eq $activeAliases[0] } | Select-Object -First 1
    if (-not $node) {
        Fail "Control alias from state.csv not found in nodes.csv: $($activeAliases[0])"
    }
    return $node
}

function Resolve-OpenSshExecutable($Name) {
    $candidates = @()
    if ($env:WINDIR) {
        $candidates += Join-Path $env:WINDIR "System32\OpenSSH\$Name.exe"
    }
    $commands = Get-Command "$Name.exe" -ErrorAction SilentlyContinue
    if ($commands) {
        $candidates += @($commands | ForEach-Object { $_.Source })
    }
    $commands = Get-Command $Name -ErrorAction SilentlyContinue
    if ($commands) {
        $candidates += @($commands | ForEach-Object { $_.Source })
    }

    foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and ([IO.Path]::GetExtension($candidate) -ieq ".exe")) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    Fail "$Name.exe not found. Install Windows OpenSSH Client or fix PATH."
}

function Resolve-OpenSshClient() {
    $sshPath = Resolve-OpenSshExecutable "ssh"
    $version = (& $env:ComSpec /d /c "`"$sshPath`" -V 2>&1" | ForEach-Object { [string]$_ }) -join "`n"
    if ($version -notmatch "OpenSSH") {
        Fail "Resolved ssh is not OpenSSH: $sshPath. Output:`n$version"
    }
    return $sshPath
}

Require-File $NodesFile "NodesFile"
Require-File $CreateInventoryScript "CreateInventoryScript"
Require-File $PrepareInventoryScript "PrepareInventoryScript"
Require-File $VerifyControlScript "VerifyControlScript"
Require-File $GenerateNetworkPlanScript "GenerateNetworkPlanScript"

$script:SshExecutablePath = Resolve-OpenSshClient
$script:ScpExecutablePath = Resolve-OpenSshExecutable "scp"
$script:SshKeygenExecutablePath = Resolve-OpenSshExecutable "ssh-keygen"

$firstLine = Get-Content -LiteralPath $NodesFile -TotalCount 1
if ($firstLine -ne $ExpectedHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedHeader"
}

$rows = Import-Csv -LiteralPath $NodesFile
$useStateFile = $false
if (-not $StateFile -or -not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
    Fail "StateFile is required. Control/orchestration selection lives in state.csv."
}
$stateFirstLine = Get-Content -LiteralPath $StateFile -TotalCount 1
if ($stateFirstLine -ne $ExpectedStateHeader) {
    Fail "state.csv header must be exactly: $ExpectedStateHeader"
}
if ($VerifyRetries -lt 1) {
    Fail "VerifyRetries must be greater than zero"
}
if ($VerifyRetryDelaySeconds -lt 1) {
    Fail "VerifyRetryDelaySeconds must be greater than zero"
}
if ($VerifyAnsibleTimeoutSeconds -lt 1) {
    Fail "VerifyAnsibleTimeoutSeconds must be greater than zero"
}
if ($SshTransferRetries -lt 1) {
    Fail "SshTransferRetries must be greater than zero"
}
if ($SshTransferRetryDelaySeconds -lt 1) {
    Fail "SshTransferRetryDelaySeconds must be greater than zero"
}
$stateRows = Import-Csv -LiteralPath $StateFile
$controlNode = Resolve-ControlNodeFromState $rows $stateRows $ControlRole $ControlAlias
$useStateFile = $true
if ($controlNode.endpoint -eq "local" -or $controlNode.connection -eq "local") {
    Fail "Cannot sync to control node when endpoint/connection is local in operator nodes.csv: $($controlNode.current_alias)"
}

if (-not $SshKeyFile) {
    $SshKeyFile = Join-Path (Join-Path $OperatorDir $controlNode.current_alias) "admin_key"
}
if (-not $KnownHostsFile) {
    $KnownHostsFile = Join-Path ([System.IO.Path]::GetTempPath()) "ai-service-platform.known_hosts"
}
Require-File $SshKeyFile "SshKeyFile"
if (-not $Include) {
    $Include = ($rows | Where-Object { $_.current_alias } | ForEach-Object { $_.current_alias }) -join ","
}

$sanitized = New-SanitizedNodesFile $NodesFile
$egressPolicySyncDir = $null
$remoteCreateInventoryTemp = "/tmp/ai-service-platform.create_inventory.sh"
$remotePrepareInventoryTemp = "/tmp/ai-service-platform.prepare_orchestration_inventory.sh"
$remoteVerifyTemp = "/tmp/ai-service-platform.verify_control_node.sh"
$controlSshPort = Get-NodeSshPort $controlNode
$remote = "$SshUser@$($controlNode.endpoint)"

Write-Host "Generating VPN network plan from nodes.csv/state.csv"
$generateNetworkPlanPath = (Resolve-Path -LiteralPath $GenerateNetworkPlanScript).Path
& $generateNetworkPlanPath -NodesFile $NodesFile -StateFile $StateFile -OverrideFile $NetworksOverrideFile -OutputFile $NetworksFile
if ($LASTEXITCODE -ne 0) {
    Fail "VPN network plan generation failed"
}
Require-File $NetworksFile "NetworksFile"

function Get-OpenSshCommonArgs($KeyFile) {
    $args = @(
        "-i", $KeyFile,
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "IdentitiesOnly=yes",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "PasswordAuthentication=no",
        "-o", "PreferredAuthentications=publickey"
    )
    if ($AutoAcceptHostKey) {
        $args += @("-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=$KnownHostsFile")
    }
    return $args
}

function Get-SshKeyArgs($KeyFile) {
    return @("-n", "-T", "-p", $controlSshPort) + @(Get-OpenSshCommonArgs $KeyFile) + @("-o", "RequestTTY=no")
}

function Get-ScpKeyArgs($KeyFile) {
    return @("-B", "-P", $controlSshPort) + @(Get-OpenSshCommonArgs $KeyFile)
}

function Invoke-ScpKey($KeyFile, $Source, $Target, $Label) {
    $scpArgs = @(Get-ScpKeyArgs $KeyFile) + @($Source, $Target)
    for ($attempt = 1; $attempt -le $SshTransferRetries; $attempt++) {
        & $script:ScpExecutablePath @scpArgs
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            return
        }
        if ($exitCode -eq 255 -and $attempt -lt $SshTransferRetries) {
            Write-Warning "$Label hit SSH transport error (exit 255), retrying $attempt/$SshTransferRetries..."
            Start-Sleep -Seconds $SshTransferRetryDelaySeconds
            continue
        }
        Fail "$Label failed"
    }
}

function Invoke-ScpKeyRecursive($KeyFile, $Source, $Target, $Label) {
    $scpArgs = @("-r") + @(Get-ScpKeyArgs $KeyFile) + @($Source, $Target)
    for ($attempt = 1; $attempt -le $SshTransferRetries; $attempt++) {
        & $script:ScpExecutablePath @scpArgs
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            return
        }
        if ($exitCode -eq 255 -and $attempt -lt $SshTransferRetries) {
            Write-Warning "$Label hit SSH transport error (exit 255), retrying $attempt/$SshTransferRetries..."
            Start-Sleep -Seconds $SshTransferRetryDelaySeconds
            continue
        }
        Fail "$Label failed"
    }
}

function Invoke-SshKey($KeyFile, $Remote, $Command, $Label) {
    $sshArgs = @(Get-SshKeyArgs $KeyFile) + @($Remote, $Command)
    for ($attempt = 1; $attempt -le $SshTransferRetries; $attempt++) {
        & $script:SshExecutablePath @sshArgs
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            return
        }
        if ($exitCode -eq 255 -and $attempt -lt $SshTransferRetries) {
            Write-Warning "$Label hit SSH transport error (exit 255), retrying $attempt/$SshTransferRetries..."
            Start-Sleep -Seconds $SshTransferRetryDelaySeconds
            continue
        }
        Fail "$Label failed"
    }
}

function Quote-BashArg($Value) {
    $text = [string]$Value
    return "'" + ($text -replace "'", "'\''") + "'"
}

function New-TarGzDirectoryArchive($SourceDir) {
    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        Fail "tar not found in PATH. It is required to upload operator directories as single archives."
    }

    $sourceFullPath = (Resolve-Path -LiteralPath $SourceDir).Path
    $sourceParent = Split-Path -Parent $sourceFullPath
    $sourceLeaf = Split-Path -Leaf $sourceFullPath
    $archivePath = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.sync." + [guid]::NewGuid().ToString("N") + ".tar.gz")

    & tar -czf $archivePath -C $sourceParent $sourceLeaf
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        Fail "Failed to create archive for directory: $SourceDir"
    }

    return @{ ArchivePath = $archivePath; SourceLeaf = $sourceLeaf }
}

function New-EgressPolicySyncDirectory($SourceDir) {
    $profilesPath = Join-Path $SourceDir "profiles.json"
    if (-not (Test-Path -LiteralPath $profilesPath -PathType Leaf)) {
        return $null
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.egress-policy." + [guid]::NewGuid().ToString("N"))
    $tempDir = Join-Path $tempRoot "egress_policy"
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    Copy-Item -LiteralPath $profilesPath -Destination (Join-Path $tempDir "profiles.json")
    return $tempDir
}

function Invoke-TarDirectoryUpload($KeyFile, $SourceDir, $Remote, $RemoteDir, $Label) {
    $bundle = $null
    $remoteArchive = "/tmp/ai-service-platform.sync.$([guid]::NewGuid().ToString('N')).tar.gz"
    $remoteExtractDir = "/tmp/ai-service-platform.sync.$([guid]::NewGuid().ToString('N'))"

    try {
        $bundle = New-TarGzDirectoryArchive $SourceDir
        Invoke-ScpKey $KeyFile $bundle.ArchivePath "${Remote}:$remoteArchive" "$Label archive upload"
        $extractCommand = @(
            "set -e",
            "rm -rf $(Quote-BashArg $remoteExtractDir) $(Quote-BashArg $RemoteDir)",
            "mkdir -p $(Quote-BashArg $remoteExtractDir)",
            "tar -xzf $(Quote-BashArg $remoteArchive) -C $(Quote-BashArg $remoteExtractDir)",
            "mv $(Quote-BashArg "$remoteExtractDir/$($bundle.SourceLeaf)") $(Quote-BashArg $RemoteDir)",
            "rm -rf $(Quote-BashArg $remoteExtractDir) $(Quote-BashArg $remoteArchive)"
        ) -join "; "
        Invoke-SshKey $KeyFile $Remote $extractCommand "$Label archive extract"
    } finally {
        if ($bundle) {
            Remove-Item -LiteralPath $bundle.ArchivePath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Clear-OpenSshHostKey($Endpoint, $Port) {
    if (-not $AutoAcceptHostKey) {
        return
    }

    $knownHosts = $KnownHostsFile
    $sshDir = Split-Path -Parent $knownHosts
    if ($sshDir) {
        New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    }
    New-Item -ItemType File -Force -Path $knownHosts | Out-Null

    $knownHostTarget = Get-KnownHostTarget $Endpoint $Port
    Write-Host "Removing old OpenSSH known_hosts entries for $knownHostTarget"
    & $script:SshKeygenExecutablePath -F $knownHostTarget -f $knownHosts *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "No existing OpenSSH known_hosts entry for $knownHostTarget; continuing."
        return
    }

    & $script:SshKeygenExecutablePath -R $knownHostTarget -f $knownHosts | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Fail "ssh-keygen -R failed for $knownHostTarget"
    }
}

Ensure-OpenSshPrivateKeyAcl $SshKeyFile
Clear-OpenSshHostKey $controlNode.endpoint $controlSshPort

try {
    Write-Host "Syncing sanitized nodes.csv to control node $($controlNode.current_alias) at $remote"
    Invoke-ScpKey $SshKeyFile $sanitized "${remote}:$RemoteNodesFile" "scp sanitized nodes.csv"

    $remoteStateFile = "/tmp/ai-service-platform.state.csv"
    if ($useStateFile) {
        Write-Host "Syncing state.csv to control node $($controlNode.current_alias)"
        Invoke-ScpKey $SshKeyFile $StateFile "${remote}:$remoteStateFile" "scp state.csv"
    }
    Write-Host "Syncing networks.csv to control node $($controlNode.current_alias)"
    Invoke-ScpKey $SshKeyFile $NetworksFile "${remote}:$RemoteNetworksFile" "scp networks.csv"

    $syncSoftether = Test-Path -LiteralPath $SoftetherDir -PathType Container
    if ($syncSoftether) {
        Write-Host "Syncing SoftEther operator secret directory to control node $($controlNode.current_alias)"
        Invoke-TarDirectoryUpload $SshKeyFile $SoftetherDir $remote $RemoteSoftetherDir "SoftEther operator directory"
    }
    $syncHaproxy = Test-Path -LiteralPath $HaproxyDir -PathType Container
    if ($syncHaproxy) {
        Write-Host "Syncing HAProxy operator directory to control node $($controlNode.current_alias)"
        Invoke-TarDirectoryUpload $SshKeyFile $HaproxyDir $remote $RemoteHaproxyDir "HAProxy operator directory"
    }
    $syncEdgeBanlist = Test-Path -LiteralPath $EdgeBanlistDir -PathType Container
    if ($syncEdgeBanlist) {
        Write-Host "Syncing edge_banlist operator directory to control node $($controlNode.current_alias)"
        Invoke-TarDirectoryUpload $SshKeyFile $EdgeBanlistDir $remote $RemoteEdgeBanlistDir "edge_banlist operator directory"
    }
    $syncPostgres = Test-Path -LiteralPath $PostgresDir -PathType Container
    if ($syncPostgres) {
        Write-Host "Syncing postgres operator directory to control node $($controlNode.current_alias)"
        Invoke-TarDirectoryUpload $SshKeyFile $PostgresDir $remote $RemotePostgresDir "postgres operator directory"
    }
    $syncPlatformNetworks = Test-Path -LiteralPath $PlatformNetworksDir -PathType Container
    if ($syncPlatformNetworks) {
        Write-Host "Syncing platform_networks operator directory to control node $($controlNode.current_alias)"
        Invoke-TarDirectoryUpload $SshKeyFile $PlatformNetworksDir $remote $RemotePlatformNetworksDir "platform_networks operator directory"
    }
    $egressPolicySyncDir = New-EgressPolicySyncDirectory $EgressPolicyDir
    $syncEgressPolicy = $null -ne $egressPolicySyncDir
    if ($syncEgressPolicy) {
        Write-Host "Syncing egress policy intent to control node $($controlNode.current_alias)"
        Invoke-TarDirectoryUpload $SshKeyFile $egressPolicySyncDir $remote $RemoteEgressPolicyDir "Egress policy operator directory"
    }
    Write-Host "Syncing bootstrap helper scripts to control node $($controlNode.current_alias)"
    Invoke-ScpKey $SshKeyFile $CreateInventoryScript "${remote}:$remoteCreateInventoryTemp" "scp create_inventory.sh"
    Invoke-ScpKey $SshKeyFile $PrepareInventoryScript "${remote}:$remotePrepareInventoryTemp" "scp prepare inventory script"
    Invoke-ScpKey $SshKeyFile $VerifyControlScript "${remote}:$remoteVerifyTemp" "scp verify_control_node.sh"

    $prepareCommand = "sudo bash '$RemotePrepareScript' --source-nodes-file '$RemoteNodesFile' --skip-check"
    if ($AutoAcceptHostKey) {
        $prepareCommand = "$prepareCommand --refresh-known-hosts"
    }
    if ($useStateFile) {
        $prepareCommand = "$prepareCommand --source-state-file '$remoteStateFile'"
    }
    if ($Include) {
        $prepareCommand = "$prepareCommand --include '$Include'"
    }
    $softetherCommand = ""
    if ($syncSoftether) {
        $softetherCommand = "sudo mkdir -p /opt/ai-service-platform/operator; if [ -d '$RemoteSoftetherDir/softether' ]; then sudo rm -rf /opt/ai-service-platform/operator/softether && sudo cp -a '$RemoteSoftetherDir/softether' /opt/ai-service-platform/operator/softether; else sudo rm -rf /opt/ai-service-platform/operator/softether && sudo cp -a '$RemoteSoftetherDir' /opt/ai-service-platform/operator/softether; fi;"
    }
    $haproxyCommand = ""
    if ($syncHaproxy) {
        $haproxyCommand = "sudo mkdir -p /opt/ai-service-platform/operator; if [ -d '$RemoteHaproxyDir/haproxy' ]; then sudo rm -rf /opt/ai-service-platform/operator/haproxy && sudo cp -a '$RemoteHaproxyDir/haproxy' /opt/ai-service-platform/operator/haproxy; else sudo rm -rf /opt/ai-service-platform/operator/haproxy && sudo cp -a '$RemoteHaproxyDir' /opt/ai-service-platform/operator/haproxy; fi;"
    }
    $edgeBanlistCommand = ""
    if ($syncEdgeBanlist) {
        $edgeBanlistCommand = "sudo mkdir -p /opt/ai-service-platform/operator; if [ -d '$RemoteEdgeBanlistDir/edge_banlist' ]; then sudo rm -rf /opt/ai-service-platform/operator/edge_banlist && sudo cp -a '$RemoteEdgeBanlistDir/edge_banlist' /opt/ai-service-platform/operator/edge_banlist; else sudo rm -rf /opt/ai-service-platform/operator/edge_banlist && sudo cp -a '$RemoteEdgeBanlistDir' /opt/ai-service-platform/operator/edge_banlist; fi;"
    }
    $postgresCommand = ""
    if ($syncPostgres) {
        $postgresCommand = "sudo mkdir -p /opt/ai-service-platform/operator; if [ -d '$RemotePostgresDir/postgres' ]; then sudo rm -rf /opt/ai-service-platform/operator/postgres && sudo cp -a '$RemotePostgresDir/postgres' /opt/ai-service-platform/operator/postgres; else sudo rm -rf /opt/ai-service-platform/operator/postgres && sudo cp -a '$RemotePostgresDir' /opt/ai-service-platform/operator/postgres; fi;"
    }
    $platformNetworksCommand = ""
    if ($syncPlatformNetworks) {
        $platformNetworksCommand = "sudo mkdir -p /opt/ai-service-platform/operator; if [ -d '$RemotePlatformNetworksDir/platform_networks' ]; then sudo rm -rf /opt/ai-service-platform/operator/platform_networks && sudo cp -a '$RemotePlatformNetworksDir/platform_networks' /opt/ai-service-platform/operator/platform_networks; else sudo rm -rf /opt/ai-service-platform/operator/platform_networks && sudo cp -a '$RemotePlatformNetworksDir' /opt/ai-service-platform/operator/platform_networks; fi;"
    }
    $egressPolicyCommand = ""
    if ($syncEgressPolicy) {
        $egressPolicyCommand = "sudo mkdir -p /opt/ai-service-platform/operator; if [ -d '$RemoteEgressPolicyDir/egress_policy' ]; then sudo rm -rf /opt/ai-service-platform/operator/egress_policy && sudo cp -a '$RemoteEgressPolicyDir/egress_policy' /opt/ai-service-platform/operator/egress_policy; else sudo rm -rf /opt/ai-service-platform/operator/egress_policy && sudo cp -a '$RemoteEgressPolicyDir' /opt/ai-service-platform/operator/egress_policy; fi;"
    }
    $verifyCommand = ""
    if (-not $SkipVerify) {
        $verifyCommand = "sudo mkdir -p `"`$(dirname '$RemoteVerifyScript')`"; sudo install -m 700 '$remoteVerifyTemp' '$RemoteVerifyScript'; sudo bash '$RemoteVerifyScript' --retries $VerifyRetries --retry-delay $VerifyRetryDelaySeconds --ansible-timeout $VerifyAnsibleTimeoutSeconds;"
    }
    $networksCommand = "sudo mkdir -p /opt/ai-service-platform/operator; sudo install -m 600 '$RemoteNetworksFile' /opt/ai-service-platform/operator/networks.csv;"
    $helperCommand = "sudo mkdir -p /opt/ai-service-platform/tools/bootstrap; sudo install -m 700 '$remoteCreateInventoryTemp' /opt/ai-service-platform/tools/bootstrap/create_inventory.sh; sudo install -m 700 '$remotePrepareInventoryTemp' '$RemotePrepareScript'; sudo install -m 700 '$remoteVerifyTemp' '$RemoteVerifyScript';"
    $remoteCommand = "set -e; $helperCommand $softetherCommand $haproxyCommand $edgeBanlistCommand $postgresCommand $platformNetworksCommand $egressPolicyCommand $networksCommand $prepareCommand; $verifyCommand rm -rf '$RemoteSoftetherDir' '$RemoteHaproxyDir' '$RemoteEdgeBanlistDir' '$RemotePostgresDir' '$RemotePlatformNetworksDir' '$RemoteEgressPolicyDir'; rm -f '$RemoteNodesFile' '$remoteStateFile' '$RemoteNetworksFile' '$remoteCreateInventoryTemp' '$remotePrepareInventoryTemp' '$remoteVerifyTemp'"

    Write-Host "Running control node inventory preparation"
    Invoke-SshKey $SshKeyFile $remote $remoteCommand "remote prepare inventory"

    if ($SkipVerify) {
        Write-Host "Control node nodes.csv and inventory.ini are in sync; verify skipped"
    } else {
        Write-Host "Control node nodes.csv, inventory.ini, and verification are complete"
    }

    if ($useStateFile -and -not $SkipServicePlan) {
        Write-ServicePlan $rows $stateRows
    } elseif ($SkipServicePlan) {
        Write-Host "Service plan skipped"
    }
} finally {
    Remove-Item -LiteralPath $sanitized -Force -ErrorAction SilentlyContinue
    if ($egressPolicySyncDir) {
        $egressPolicySyncRoot = Split-Path -Parent $egressPolicySyncDir
        Remove-Item -LiteralPath $egressPolicySyncRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
