param(
    [string]$NodesFile = ".\operator\nodes.csv",

    [string]$StateFile = ".\operator\state.csv",

    [string]$ControlRole = "orchestration",

    [string]$ControlAlias = "",

    [string]$OperatorDir = ".\operator",

    [string]$SshUser = "useradmin",

    [string]$SshKeyFile = "",

    [string]$RemoteNodesFile = "/tmp/ai-service-platform.nodes.csv",

    [string]$SoftetherDir = ".\operator\softether",

    [string]$RemoteSoftetherDir = "/tmp/ai-service-platform.softether",

    [string]$HaproxyDir = ".\operator\haproxy",

    [string]$RemoteHaproxyDir = "/tmp/ai-service-platform.haproxy",

    [string]$RemotePrepareScript = "/opt/ai-service-platform/tools/bootstrap/prepare_orchestration_inventory.sh",

    [string]$CreateInventoryScript = "tools/bootstrap/create_inventory.sh",

    [string]$PrepareInventoryScript = "tools/bootstrap/prepare_orchestration_inventory.sh",

    [string]$VerifyControlScript = "tools/bootstrap/verify_control_node.sh",

    [string]$RemoteVerifyScript = "/opt/ai-service-platform/tools/bootstrap/verify_control_node.sh",

    [string]$Include = "",

    [switch]$AutoAcceptHostKey,

    [switch]$FixKeyAcl,

    [switch]$SkipVerify,

    [switch]$SkipServicePlan
)

$ErrorActionPreference = "Stop"
$ExpectedHeader = "current_alias,endpoint,connection,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$IsWindowsPlatform = ($PSVersionTable.PSEdition -eq "Desktop") -or ($PSVersionTable.ContainsKey("Platform") -and $PSVersionTable.Platform -eq "Win32NT") -or ($env:OS -eq "Windows_NT")

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Require-File($Path, $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Label not found: $Path"
    }
}

function New-SanitizedNodesFile($SourcePath) {
    $tempFile = (New-TemporaryFile).FullName
    Set-Content -LiteralPath $tempFile -Value $ExpectedHeader -Encoding ascii

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
        $fields = $line -split ",", 5
        if ($fields.Count -ne 4) {
            Fail "nodes.csv row has invalid column count: $line"
        }
        $fields[3] = ""
        Add-Content -LiteralPath $tempFile -Value ($fields -join ",") -Encoding ascii
    }

    return $tempFile
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

Require-File $NodesFile "NodesFile"
Require-File $CreateInventoryScript "CreateInventoryScript"
Require-File $PrepareInventoryScript "PrepareInventoryScript"
Require-File $VerifyControlScript "VerifyControlScript"

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Fail "ssh not found in PATH. Install Windows OpenSSH Client or fix PATH."
}
if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
    Fail "scp not found in PATH. Install Windows OpenSSH Client or fix PATH."
}
if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    Fail "ssh-keygen not found in PATH. Install Windows OpenSSH Client or fix PATH."
}

try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $sshVersion = (& ssh -V 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ($sshVersion -notmatch "OpenSSH") {
    Fail "ssh in PATH does not look like OpenSSH. Output:`n$sshVersion"
}

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
$stateRows = Import-Csv -LiteralPath $StateFile
$controlNode = Resolve-ControlNodeFromState $rows $stateRows $ControlRole $ControlAlias
$useStateFile = $true
if ($controlNode.endpoint -eq "local" -or $controlNode.connection -eq "local") {
    Fail "Cannot sync to control node when endpoint/connection is local in operator nodes.csv: $($controlNode.current_alias)"
}

if (-not $SshKeyFile) {
    $SshKeyFile = Join-Path (Join-Path $OperatorDir $controlNode.current_alias) "admin_key"
}
Require-File $SshKeyFile "SshKeyFile"
if (-not $Include) {
    $Include = ($rows | Where-Object { $_.current_alias } | ForEach-Object { $_.current_alias }) -join ","
}

$sanitized = New-SanitizedNodesFile $NodesFile
$remoteCreateInventoryTemp = "/tmp/ai-service-platform.create_inventory.sh"
$remotePrepareInventoryTemp = "/tmp/ai-service-platform.prepare_orchestration_inventory.sh"
$remoteVerifyTemp = "/tmp/ai-service-platform.verify_control_node.sh"
$remote = "$SshUser@$($controlNode.endpoint)"

function Test-PrivateKeyAcl($KeyFile) {
    $broadPrincipalSids = @(
        "S-1-1-0",       # Everyone
        "S-1-5-11",      # Authenticated Users
        "S-1-5-32-545"   # BUILTIN\Users
    )
    $acl = Get-Acl -LiteralPath $KeyFile
    $badEntries = @()
    foreach ($entry in $acl.Access) {
        $identity = [string]$entry.IdentityReference
        $sid = ""
        try {
            $sid = $entry.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        } catch {
            $sid = ""
        }
        $hasRead = (($entry.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Read) -ne 0) -or
            (($entry.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::ReadData) -ne 0) -or
            (($entry.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne 0)
        if ($entry.AccessControlType -eq "Allow" -and $hasRead -and ($broadPrincipalSids -contains $sid)) {
            $badEntries += $identity
        }
    }
    return @($badEntries | Select-Object -Unique)
}

function Repair-PrivateKeyAcl($KeyFile) {
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Host "Fixing OpenSSH private key ACL for $KeyFile"
    & icacls $KeyFile "/inheritance:r" | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Fail "icacls failed to disable inheritance for $KeyFile"
    }
    & icacls $KeyFile "/grant:r" "$currentUser`:R" | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Fail "icacls failed to grant read access to $currentUser for $KeyFile"
    }
}

function Ensure-PrivateKeyAcl($KeyFile) {
    if (-not $IsWindowsPlatform) {
        return
    }

    $badEntries = Test-PrivateKeyAcl $KeyFile
    if ($badEntries.Count -eq 0) {
        return
    }

    $badText = $badEntries -join ", "
    Write-Warning "OpenSSH private key ACL is too open for $KeyFile. Broad readable entries: $badText. Fixing automatically."
    Repair-PrivateKeyAcl $KeyFile
    $remainingBadEntries = Test-PrivateKeyAcl $KeyFile
    if ($remainingBadEntries.Count -gt 0) {
        Fail "OpenSSH private key ACL is still too open after automatic repair: $($remainingBadEntries -join ', ')"
    }
}

function Get-SshCommonArgs($KeyFile) {
    $args = @("-i", $KeyFile, "-o", "IdentitiesOnly=yes")
    if ($AutoAcceptHostKey) {
        $args += @("-o", "StrictHostKeyChecking=accept-new")
    }
    return $args
}

function Invoke-ScpKey($KeyFile, $Source, $Target, $Label) {
    $scpArgs = @(Get-SshCommonArgs $KeyFile) + @($Source, $Target)
    & scp @scpArgs
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label failed"
    }
}

function Invoke-ScpKeyRecursive($KeyFile, $Source, $Target, $Label) {
    $scpArgs = @("-r") + @(Get-SshCommonArgs $KeyFile) + @($Source, $Target)
    & scp @scpArgs
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label failed"
    }
}

function Invoke-SshKey($KeyFile, $Remote, $Command, $Label) {
    $sshArgs = @(Get-SshCommonArgs $KeyFile) + @($Remote, $Command)
    & ssh @sshArgs
    if ($LASTEXITCODE -ne 0) {
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

function Clear-OpenSshHostKey($Endpoint) {
    if (-not $AutoAcceptHostKey) {
        return
    }

    Write-Host "Removing old OpenSSH known_hosts entries for $Endpoint"
    & ssh-keygen -R $Endpoint | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Fail "ssh-keygen -R failed for $Endpoint"
    }
}

Ensure-PrivateKeyAcl $SshKeyFile
Clear-OpenSshHostKey $controlNode.endpoint

try {
    Write-Host "Syncing sanitized nodes.csv to control node $($controlNode.current_alias) at $remote"
    Invoke-ScpKey $SshKeyFile $sanitized "${remote}:$RemoteNodesFile" "scp sanitized nodes.csv"

    $remoteStateFile = "/tmp/ai-service-platform.state.csv"
    if ($useStateFile) {
        Write-Host "Syncing state.csv to control node $($controlNode.current_alias)"
        Invoke-ScpKey $SshKeyFile $StateFile "${remote}:$remoteStateFile" "scp state.csv"
    }

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
    $verifyCommand = ""
    if (-not $SkipVerify) {
        $verifyCommand = "sudo mkdir -p `"`$(dirname '$RemoteVerifyScript')`"; sudo install -m 700 '$remoteVerifyTemp' '$RemoteVerifyScript'; sudo bash '$RemoteVerifyScript';"
    }
    $helperCommand = "sudo mkdir -p /opt/ai-service-platform/tools/bootstrap; sudo install -m 700 '$remoteCreateInventoryTemp' /opt/ai-service-platform/tools/bootstrap/create_inventory.sh; sudo install -m 700 '$remotePrepareInventoryTemp' '$RemotePrepareScript'; sudo install -m 700 '$remoteVerifyTemp' '$RemoteVerifyScript';"
    $remoteCommand = "set -e; $helperCommand $softetherCommand $haproxyCommand $prepareCommand; $verifyCommand rm -rf '$RemoteSoftetherDir' '$RemoteHaproxyDir'; rm -f '$RemoteNodesFile' '$remoteStateFile' '$remoteCreateInventoryTemp' '$remotePrepareInventoryTemp' '$remoteVerifyTemp'"

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
}
