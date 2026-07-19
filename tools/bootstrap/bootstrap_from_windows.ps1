param(
    [string]$NodesFile = ".\operator\nodes.csv",

    [string]$StateFile = ".\operator\state.csv",

    [Parameter(Mandatory=$true)]
    [string]$Alias,

    [string]$SetupScript = "tools/bootstrap/setup_vps.sh",

    [string]$CreateInventoryScript = "tools/bootstrap/create_inventory.sh",

    [string]$PrepareInventoryScript = "tools/bootstrap/prepare_orchestration_inventory.sh",

    [string]$VerifyControlScript = "tools/bootstrap/verify_control_node.sh",

    [string]$AnsibleAuthorizedKeyFile,

    [string]$OperatorDir = ".\operator",

    [string]$OperatorBackupScript = "tools/operator_backup/backup_operator.ps1",

    [string]$OperatorBackupDir = "D:\Backup\Projects\AI_SP\operator",

    [string]$OperatorBackupRemoteDir = "/opt/backups/ai-service-platform/operator",

    [int]$OperatorBackupKeepLatest = 30,

    [string]$AdminUser = "useradmin",

    [string]$OutputAnsibleAuthorizedKeyFile = ".\operator\ansible_control.managed_nodes.pub",

    [switch]$Force,

    [switch]$AutoAcceptHostKey = $true,

    [switch]$RegenerateRemoteKeys,

    [switch]$SkipOperatorBackup
)

$ErrorActionPreference = "Stop"
$ExpectedHeader = "current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$PublicKeyBeginMarker = "__ANSIBLE_CONTROL_PUBLIC_KEY_BEGIN__"
$PublicKeyEndMarker = "__ANSIBLE_CONTROL_PUBLIC_KEY_END__"
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

function Assert-NoUtf8Bom($Path, $Label) {
    Require-File $Path $Label
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path))
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Fail "$Label must be UTF-8 without BOM: $Path"
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

function New-SanitizedNodesFileFromRows($Rows) {
    $tempFile = (New-TemporaryFile).FullName
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($ExpectedHeader)

    foreach ($item in $Rows) {
        $itemSshPort = Get-NodeSshPort $item
        $lines.Add(("{0},{1},{2},{3},{4}," -f $item.current_alias,$item.endpoint,$item.expected_ip,$item.connection,$itemSshPort))
    }

    Write-AsciiNoBomLines $tempFile $lines
    Assert-SanitizedNodesFile $tempFile
    return $tempFile
}

function Clear-RootPasswordForAlias($Path, $AliasToClear) {
    $lines = Get-Content -LiteralPath $Path
    if (-not $lines -or $lines.Count -eq 0) {
        Fail "nodes.csv is empty: $Path"
    }
    if ($lines[0] -ne $ExpectedHeader) {
        Fail "nodes.csv header must be exactly: $ExpectedHeader"
    }

    $updated = New-Object System.Collections.Generic.List[string]
    $updated.Add($ExpectedHeader)
    $foundAlias = $false

    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        if (-not $line) {
            continue
        }

        $fields = $line -split ",", 7
        if ($fields.Count -ne 6) {
            Fail "nodes.csv row has invalid column count: $line"
        }

        if ($fields[0] -eq $AliasToClear) {
            $fields[5] = ""
            $foundAlias = $true
        }
        $updated.Add(($fields -join ","))
    }

    if (-not $foundAlias) {
        Fail "Alias not found while clearing root_password: $AliasToClear"
    }

    Write-AsciiNoBomLines $Path $updated
    Write-Host "Cleared root_password in local nodes.csv for $AliasToClear"
}

function Split-AliasList($Value) {
    if (-not $Value) { return @() }
    return @($Value -split "\+" | Where-Object { $_ })
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

function Is-OrchestrationCapableNode($StateRows, $AliasToCheck) {
    $rows = @($StateRows | Where-Object { ($_.kind -eq "platform_role" -or $_.kind -eq "role") -and $_.name -eq "orchestration" -and $_.state -eq "present" })
    if ($rows.Count -eq 0) {
        Fail "No active orchestration platform_role found in state.csv."
    }
    if ($rows.Count -gt 1) {
        Fail "Multiple orchestration rows found in state.csv. Keep exactly one present row."
    }
    $activeAliases = @(Split-AliasList $rows[0].active_aliases)
    if ($activeAliases.Count -ne 1) {
        Fail "orchestration must have exactly one active alias in state.csv."
    }
    $candidateAliases = @(Split-AliasList $rows[0].candidate_aliases)
    return (($activeAliases[0] -eq $AliasToCheck) -or ($candidateAliases -contains $AliasToCheck))
}

function Get-ActiveOrchestrationAlias($StateRows) {
    $rows = @($StateRows | Where-Object { ($_.kind -eq "platform_role" -or $_.kind -eq "role") -and $_.name -eq "orchestration" -and $_.state -eq "present" })
    if ($rows.Count -eq 0) {
        Fail "No active orchestration platform_role found in state.csv."
    }
    if ($rows.Count -gt 1) {
        Fail "Multiple orchestration rows found in state.csv. Keep exactly one present row."
    }
    $activeAliases = @(Split-AliasList $rows[0].active_aliases)
    if ($activeAliases.Count -ne 1) {
        Fail "orchestration must have exactly one active alias in state.csv."
    }
    return $activeAliases[0]
}

function Get-MarkedBlock($Lines, $BeginMarker, $EndMarker, $Label) {
    $blockLines = New-Object System.Collections.Generic.List[string]
    $insideBlock = $false
    $seenBlock = $false
    $escapeChar = [char]27

    foreach ($line in $Lines) {
        $lineText = [regex]::Replace([string]$line, "$escapeChar\[[0-9;]*m", "").Trim()
        if ($lineText -eq $BeginMarker) {
            if ($insideBlock -or $seenBlock) {
                Fail "Found duplicate or nested begin marker for $Label"
            }
            $insideBlock = $true
            $seenBlock = $true
            continue
        }
        if ($lineText -eq $EndMarker) {
            if (-not $insideBlock) {
                Fail "Found end marker without begin marker for $Label"
            }
            $insideBlock = $false
            continue
        }
        if ($insideBlock) {
            $blockLines.Add($lineText)
        }
    }

    if (-not $seenBlock -or $insideBlock -or $blockLines.Count -eq 0) {
        Fail "Could not capture $Label from remote bootstrap output."
    }

    return $blockLines
}

function Save-TextFile($Path, $Lines, $AllowOverwrite, $KeepExisting) {
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $AllowOverwrite) {
        if ($KeepExisting) {
            Write-Host "Keeping existing output key file: $Path"
            return
        }
        Fail "Output key file already exists: $Path. Use -Force to overwrite it."
    }

    $outputDir = Split-Path -Parent $Path
    if ($outputDir) {
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    }
    Set-Content -LiteralPath $Path -Value $Lines -Encoding ascii
}

function Assert-OutputKeyPathAvailable($Path, $AllowOverwrite, $AllowExisting) {
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $AllowOverwrite) {
        if ($AllowExisting) {
            return
        }
        Fail "Output key file already exists: $Path. Use -Force to overwrite it."
    }
}

function Assert-BootstrapKeyPathsAvailable($AliasToSave, $IsManagement, $BaseOperatorDir, $PublicKeyPath, $AllowOverwrite, $AllowExisting) {
    $aliasDir = Join-Path $BaseOperatorDir $AliasToSave

    Assert-OutputKeyPathAvailable (Join-Path $aliasDir "deploy_key") $AllowOverwrite $AllowExisting
    Assert-OutputKeyPathAvailable (Join-Path $aliasDir "admin_key") $AllowOverwrite $AllowExisting

    if ($IsManagement) {
        Assert-OutputKeyPathAvailable (Join-Path $aliasDir "ansible_control_key") $AllowOverwrite $AllowExisting
        Assert-OutputKeyPathAvailable (Join-Path $aliasDir "ansible_control.managed_nodes.pub") $AllowOverwrite $AllowExisting
        Assert-OutputKeyPathAvailable $PublicKeyPath $AllowOverwrite $AllowExisting
    }
}

function Test-OutputFileWillChange($Path, $AllowOverwrite, $KeepExisting) {
    if ($AllowOverwrite) {
        return $true
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (-not $KeepExisting)
    }
    return $true
}

function Test-BootstrapLocalMutationExpected($AliasToSave, $IsManagement, $BaseOperatorDir, $PublicKeyPath, $AllowOverwrite, $KeepExisting, $WillClearRootPassword) {
    if ($WillClearRootPassword) {
        return $true
    }

    $aliasDir = Join-Path $BaseOperatorDir $AliasToSave
    foreach ($path in @((Join-Path $aliasDir "deploy_key"), (Join-Path $aliasDir "admin_key"))) {
        if (Test-OutputFileWillChange $path $AllowOverwrite $KeepExisting) {
            return $true
        }
    }

    if ($IsManagement) {
        foreach ($path in @(
            (Join-Path $aliasDir "ansible_control_key"),
            (Join-Path $aliasDir "ansible_control.managed_nodes.pub"),
            $PublicKeyPath
        )) {
            if (Test-OutputFileWillChange $path $AllowOverwrite $KeepExisting) {
                return $true
            }
        }
    }

    return $false
}

function Get-FullPath($Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Copy-StagedBootstrapKeysToSnapshot($SnapshotOperatorDir, $StagedAlias, $StagedKeyRoot, $StagedIsManagement, $StagedPublicKeyPath) {
    if ([string]::IsNullOrWhiteSpace($StagedAlias)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($StagedKeyRoot)) {
        Fail "Staged bootstrap key root is empty before operator backup snapshot for $StagedAlias"
    }

    $sourceAliasDir = Join-Path $StagedKeyRoot $StagedAlias
    if (-not (Test-Path -LiteralPath $sourceAliasDir -PathType Container)) {
        Fail "Staged bootstrap key directory missing before operator backup snapshot: $sourceAliasDir"
    }

    $snapshotAliasDir = Join-Path $SnapshotOperatorDir $StagedAlias
    New-Item -ItemType Directory -Force -Path $snapshotAliasDir | Out-Null

    $keyNames = @("deploy_key", "admin_key")
    if ($StagedIsManagement) {
        $keyNames += @("ansible_control_key", "ansible_control.managed_nodes.pub")
    }

    foreach ($name in $keyNames) {
        $source = Join-Path $sourceAliasDir $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            Fail "Staged bootstrap key missing before operator backup snapshot: $source"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $snapshotAliasDir $name) -Force
    }

    if ($StagedIsManagement -and -not [string]::IsNullOrWhiteSpace($StagedPublicKeyPath)) {
        $operatorFullPath = Get-FullPath $OperatorDir
        if (-not $operatorFullPath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
            $operatorFullPath = $operatorFullPath + [System.IO.Path]::DirectorySeparatorChar
        }

        $publicKeyFullPath = Get-FullPath $StagedPublicKeyPath
        if ($publicKeyFullPath.StartsWith($operatorFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relativePublicKeyPath = $publicKeyFullPath.Substring($operatorFullPath.Length)
            $snapshotPublicKeyPath = Join-Path $SnapshotOperatorDir $relativePublicKeyPath
            $snapshotPublicKeyDir = Split-Path -Parent $snapshotPublicKeyPath
            New-Item -ItemType Directory -Force -Path $snapshotPublicKeyDir | Out-Null
            Copy-Item -LiteralPath (Join-Path $sourceAliasDir "ansible_control.managed_nodes.pub") -Destination $snapshotPublicKeyPath -Force
        }
    }
}

function New-OperatorBackupSnapshot($ClearRootPasswordAlias, $StagedAlias = "", $StagedKeyRoot = "", $StagedIsManagement = $false, $StagedPublicKeyPath = "") {
    if ([string]::IsNullOrWhiteSpace($ClearRootPasswordAlias)) {
        return $null
    }

    $snapshotRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.operator-backup-snapshot." + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $snapshotRoot | Out-Null

    $resolvedOperatorDir = (Resolve-Path -LiteralPath $OperatorDir).Path
    $operatorLeaf = Split-Path -Leaf $resolvedOperatorDir
    Copy-Item -LiteralPath $resolvedOperatorDir -Destination $snapshotRoot -Recurse -Force

    $snapshotOperatorDir = Join-Path $snapshotRoot $operatorLeaf
    $snapshotNodesFile = Join-Path $snapshotOperatorDir (Split-Path -Leaf $NodesFile)
    $snapshotStateFile = Join-Path $snapshotOperatorDir (Split-Path -Leaf $StateFile)

    Copy-Item -LiteralPath $NodesFile -Destination $snapshotNodesFile -Force
    Copy-Item -LiteralPath $StateFile -Destination $snapshotStateFile -Force
    Copy-StagedBootstrapKeysToSnapshot $snapshotOperatorDir $StagedAlias $StagedKeyRoot $StagedIsManagement $StagedPublicKeyPath
    Clear-RootPasswordForAlias $snapshotNodesFile $ClearRootPasswordAlias

    return [PSCustomObject]@{
        Root = $snapshotRoot
        OperatorDir = $snapshotOperatorDir
        NodesFile = $snapshotNodesFile
        StateFile = $snapshotStateFile
    }
}

function Invoke-OperatorBackupIfNeeded($Reason, $ClearRootPasswordAlias = "", $StagedAlias = "", $StagedKeyRoot = "", $StagedIsManagement = $false, $StagedPublicKeyPath = "") {
    if ($SkipOperatorBackup) {
        Write-Warning "Operator backup skipped before local mutation: $Reason"
        return
    }

    Require-File $OperatorBackupScript "OperatorBackupScript"
    Write-Host "Operator backup before local mutation: $Reason"
    $snapshot = $null
    try {
        $backupNodesFile = $NodesFile
        $backupStateFile = $StateFile
        $backupOperatorDir = $OperatorDir

        if (-not [string]::IsNullOrWhiteSpace($ClearRootPasswordAlias)) {
            Write-Host "Using sanitized operator backup snapshot with root_password cleared for $ClearRootPasswordAlias"
            $snapshot = New-OperatorBackupSnapshot $ClearRootPasswordAlias $StagedAlias $StagedKeyRoot $StagedIsManagement $StagedPublicKeyPath
            $backupNodesFile = $snapshot.NodesFile
            $backupStateFile = $snapshot.StateFile
            $backupOperatorDir = $snapshot.OperatorDir
        }

        $args = @(
            "-NodesFile", $backupNodesFile,
            "-StateFile", $backupStateFile,
            "-OperatorDir", $backupOperatorDir,
            "-LocalBackupDir", $OperatorBackupDir,
            "-RemoteBackupDir", $OperatorBackupRemoteDir,
            "-KeepLatest", $OperatorBackupKeepLatest
        )
        if ($AutoAcceptHostKey) { $args += "-AutoAcceptHostKey" }
        & powershell -NoProfile -ExecutionPolicy Bypass -File $OperatorBackupScript @args
        if ($LASTEXITCODE -ne 0) {
            Fail "operator backup failed before local mutation: $Reason"
        }
    } finally {
        if ($snapshot -and $snapshot.Root -and (Test-Path -LiteralPath $snapshot.Root -PathType Container)) {
            Remove-Item -LiteralPath $snapshot.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Save-BootstrapKeys($Lines, $AliasToSave, $IsManagement, $BaseOperatorDir, $PublicKeyPath, $AllowOverwrite, $KeepExisting) {
    $aliasDir = Join-Path $BaseOperatorDir $AliasToSave
    New-Item -ItemType Directory -Force -Path $aliasDir | Out-Null

    $deployKey = Get-MarkedBlock $Lines "--- BEGIN SSH_KEY ---" "--- END SSH_KEY ---" "deploy private key"
    $adminKey = Get-MarkedBlock $Lines "--- BEGIN ADMIN KEY ---" "--- END ADMIN KEY ---" "admin private key"

    $deployKeyPath = Join-Path $aliasDir "deploy_key"
    $adminKeyPath = Join-Path $aliasDir "admin_key"
    Save-TextFile $deployKeyPath $deployKey $AllowOverwrite $KeepExisting
    Ensure-OpenSshPrivateKeyAcl $deployKeyPath
    Save-TextFile $adminKeyPath $adminKey $AllowOverwrite $KeepExisting
    Ensure-OpenSshPrivateKeyAcl $adminKeyPath
    Write-Host "Saved bootstrap keys: $aliasDir"

    if ($IsManagement) {
        $ansibleKey = Get-MarkedBlock $Lines "--- BEGIN ANSIBLE CONTROL KEY ---" "--- END ANSIBLE CONTROL KEY ---" "Ansible control private key"
        $publicKey = Get-MarkedBlock $Lines $PublicKeyBeginMarker $PublicKeyEndMarker "Ansible control public key"
        if ($publicKey.Count -ne 1) {
            Fail "Could not capture exactly one Ansible control public key from remote bootstrap output."
        }

        $ansibleKeyPath = Join-Path $aliasDir "ansible_control_key"
        Save-TextFile $ansibleKeyPath $ansibleKey $AllowOverwrite $KeepExisting
        Ensure-OpenSshPrivateKeyAcl $ansibleKeyPath
        Save-TextFile (Join-Path $aliasDir "ansible_control.managed_nodes.pub") $publicKey $AllowOverwrite $KeepExisting
        if (-not [string]::IsNullOrWhiteSpace($PublicKeyPath)) {
            Save-TextFile $PublicKeyPath $publicKey $AllowOverwrite $KeepExisting
            Write-Host "Saved Ansible control public key: $PublicKeyPath"
        }
    }
}

function Save-BootstrapKeysToStaging($Lines, $AliasToSave, $IsManagement, $StagingRoot) {
    Save-BootstrapKeys $Lines $AliasToSave $IsManagement $StagingRoot $null $true $false
}

function Install-StagedBootstrapKeys($AliasToSave, $IsManagement, $StagingRoot, $BaseOperatorDir, $PublicKeyPath, $AllowOverwrite) {
    $sourceAliasDir = Join-Path $StagingRoot $AliasToSave
    $targetAliasDir = Join-Path $BaseOperatorDir $AliasToSave
    New-Item -ItemType Directory -Force -Path $targetAliasDir | Out-Null

    foreach ($name in @("deploy_key", "admin_key")) {
        $source = Join-Path $sourceAliasDir $name
        $target = Join-Path $targetAliasDir $name
        Save-TextFile $target (Get-Content -LiteralPath $source) $AllowOverwrite $false
        Ensure-OpenSshPrivateKeyAcl $target
    }

    if ($IsManagement) {
        foreach ($name in @("ansible_control_key", "ansible_control.managed_nodes.pub")) {
            $source = Join-Path $sourceAliasDir $name
            $target = Join-Path $targetAliasDir $name
            Save-TextFile $target (Get-Content -LiteralPath $source) $AllowOverwrite $false
            if ($name -eq "ansible_control_key") {
                Ensure-OpenSshPrivateKeyAcl $target
            }
        }
        $sourcePublicKey = Join-Path $sourceAliasDir "ansible_control.managed_nodes.pub"
        Save-TextFile $PublicKeyPath (Get-Content -LiteralPath $sourcePublicKey) $AllowOverwrite $false
    }
}

function Get-PuttyHostKeyFingerprint($Remote, $Password, $Port) {
    if (-not $AutoAcceptHostKey) {
        return ""
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $script:ErrorActionPreference = "Continue"
        $output = & plink -batch -no-antispoof -P $Port -pw $Password $Remote exit 2>&1
    } finally {
        $script:ErrorActionPreference = $previousErrorActionPreference
    }

    $outputText = ($output | ForEach-Object { [string]$_ }) -join "`n"
    $match = [regex]::Match($outputText, "SHA256:[A-Za-z0-9+/=]+")
    if (-not $match.Success) {
        Fail "Could not detect SSH host key fingerprint for $Remote. PuTTY output:`n$outputText"
    }

    Write-Host "Detected SSH host key fingerprint for $Remote`: $($match.Value)"
    return $match.Value
}

function Invoke-PlinkCommand($Remote, $Password, $Port, $Command, $LogPath, $HostKeyFingerprint) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $script:ErrorActionPreference = "Continue"
        $plinkArgs = @("-batch", "-no-antispoof", "-P", $Port, "-pw", $Password, $Remote, $Command)
        if ($HostKeyFingerprint) {
            $plinkArgs = @("-hostkey", $HostKeyFingerprint) + $plinkArgs
        }
        & plink @plinkArgs 2>&1 | ForEach-Object {
            $line = [string]$_
            Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
            Write-Host $line
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $script:ErrorActionPreference = $previousErrorActionPreference
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
    }
}

function Invoke-PscpPassword($Password, $Port, $Source, $Target, $Label, $HostKeyFingerprint, $AliasToBootstrap, $Endpoint) {
    $pscpArgs = @("-batch", "-P", $Port, "-pw", $Password, $Source, $Target)
    if ($HostKeyFingerprint) {
        $pscpArgs = @("-hostkey", $HostKeyFingerprint) + $pscpArgs
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $script:ErrorActionPreference = "Continue"
        $output = & pscp @pscpArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $script:ErrorActionPreference = $previousErrorActionPreference
    }

    $outputLines = @($output | ForEach-Object { [string]$_ })
    foreach ($line in $outputLines) {
        Write-Host $line
    }
    if ($exitCode -ne 0) {
        $outputText = $outputLines -join "`n"
        if ($outputText -match "Configured password was not accepted|Access denied") {
            Fail "Root password rejected for $AliasToBootstrap at ${Endpoint}:$Port while $Label. Check operator/nodes.csv root_password or provider root SSH password/auth state."
        }
        Fail "$Label failed with exit code $exitCode"
    }
}

function Quote-BashArg($Value) {
    $text = [string]$Value
    return "'" + ($text -replace "'", "'\''") + "'"
}

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
        $args += @("-o", "StrictHostKeyChecking=accept-new")
    }
    return $args
}

function Get-OpenSshKnownHostTarget($Endpoint, $Port) {
    if ([string]$Port -eq "22") {
        return $Endpoint
    }
    return "[$Endpoint]:$Port"
}

function Clear-OpenSshHostKeyCache($Endpoint, $Port) {
    if (-not $AutoAcceptHostKey) {
        return
    }
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        Write-Warning "ssh-keygen not found; cannot remove stale OpenSSH known_hosts entry for ${Endpoint}:$Port"
        return
    }

    $targets = New-Object System.Collections.Generic.List[string]
    $targets.Add((Get-OpenSshKnownHostTarget $Endpoint $Port))
    if ([string]$Port -ne "22" -and -not $targets.Contains($Endpoint)) {
        $targets.Add($Endpoint)
    }

    foreach ($target in $targets) {
        & ssh-keygen -F $target *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "No existing OpenSSH known_hosts entry for $target; continuing."
            continue
        }
        Write-Host "Removing old OpenSSH known_hosts entry for $target"
        & ssh-keygen -R $target | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Fail "ssh-keygen -R failed for $target"
        }
    }
}

function Invoke-SshKey($KeyFile, $Port, $Remote, $Command, $Label, $LogPath = "") {
    $sshArgs = @("-n", "-T", "-p", $Port) + @(Get-OpenSshCommonArgs $KeyFile) + @("-o", "RequestTTY=no", $Remote, $Command)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $script:ErrorActionPreference = "Continue"
        if ($LogPath) {
            & ssh @sshArgs 2>&1 | ForEach-Object {
                $line = [string]$_
                Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
                Write-Host $line
            }
        } else {
            & ssh @sshArgs
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $script:ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        Fail "$Label failed with exit code $exitCode"
    }
}

function Invoke-ScpKey($KeyFile, $Port, $Source, $Target, $Label) {
    $scpArgs = @("-B", "-P", $Port) + @(Get-OpenSshCommonArgs $KeyFile) + @($Source, $Target)
    & scp @scpArgs
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label failed"
    }
}

function Invoke-RemoteSshHardening($KeyFile, $Port, $Remote) {
    Invoke-ScpKey $KeyFile $Port $SetupScript "${Remote}:/tmp/setup_vps.sh" "scp setup_vps.sh for SSH hardening"
    try {
        Invoke-SshKey $KeyFile $Port $Remote "sudo -n bash /tmp/setup_vps.sh --ssh-hardening-only" "remote SSH hardening"
    } finally {
        $cleanupArgs = @("-n", "-T", "-p", $Port) + @(Get-OpenSshCommonArgs $KeyFile) + @("-o", "RequestTTY=no", $Remote, "rm -f /tmp/setup_vps.sh")
        & ssh @cleanupArgs 2>$null | Out-Null
    }
}

function Test-AdminKeyBootstrapPreflight($KeyFile, $Port, $Remote, $IsManagement) {
    $managementCheck = "true"
    if ($IsManagement) {
        $managementCheck = @'
for pkg in git ansible; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
        candidate="$(apt-cache policy "$pkg" | awk '/Candidate:/ {print $2; exit}')"
        if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
            echo "[WARN] package $pkg is not currently available through apt; bootstrap will try apt update and Ubuntu universe before installing it." >&2
        fi
    fi
done
'@
    }

    $preflight = @"
set -e
sudo -n true || { echo "[ERROR] $AdminUser passwordless sudo is not available. Reinstall OS or run fresh bootstrap with root access." >&2; exit 1; }
for cmd in bash sudo install mkdir rm chmod chown id getent ssh-keygen apt-get apt-cache awk mktemp; do
    command -v "`$cmd" >/dev/null 2>&1 || { echo "[ERROR] required command missing: `$cmd. Reinstall OS or run fresh bootstrap with root access." >&2; exit 1; }
done
tmp="`$(mktemp /tmp/ai-service-platform.bootstrap-preflight.XXXXXX)"
rm -f "`$tmp"
. /etc/os-release
if [ "`${ID:-}" != "ubuntu" ]; then
    echo "[ERROR] unsupported OS for admin-key re-bootstrap: `${ID:-unknown}. Reinstall with supported Ubuntu image or run fresh bootstrap." >&2
    exit 1
fi
$managementCheck
echo "[OK] admin-key bootstrap preflight passed"
"@

    $localPreflight = New-TemporaryFile
    $remotePreflight = "/tmp/ai-service-platform.bootstrap-preflight.$([guid]::NewGuid().ToString('N')).sh"
    try {
        $preflightLf = $preflight -replace "`r`n", "`n" -replace "`r", "`n"
        [System.IO.File]::WriteAllText($localPreflight.FullName, $preflightLf, [System.Text.ASCIIEncoding]::new())
        Invoke-ScpKey $KeyFile $Port $localPreflight.FullName "${Remote}:$remotePreflight" "scp admin-key bootstrap preflight"
        Invoke-SshKey $KeyFile $Port $Remote "sudo -n bash $remotePreflight" "admin-key bootstrap preflight"
    } finally {
        Remove-Item -LiteralPath $localPreflight -Force -ErrorAction SilentlyContinue
        $cleanupArgs = @("-n", "-T", "-p", $Port) + @(Get-OpenSshCommonArgs $KeyFile) + @("-o", "RequestTTY=no", $Remote, "rm -f $remotePreflight")
        & ssh @cleanupArgs 2>$null | Out-Null
    }
}

function Clear-PuttyHostKeyCache($Endpoint, $Port) {
    if (-not $AutoAcceptHostKey) {
        return
    }

    $registryPath = "HKCU:\Software\SimonTatham\PuTTY\SshHostKeys"
    if (-not (Test-Path -LiteralPath $registryPath)) {
        return
    }

    $keyItem = Get-Item -LiteralPath $registryPath
    foreach ($property in $keyItem.GetValueNames()) {
        if ($property -like "*@$Port`:$Endpoint") {
            Remove-ItemProperty -LiteralPath $registryPath -Name $property -ErrorAction SilentlyContinue
            Write-Host "Removed PuTTY cached host key: $property"
        }
    }
}

Require-File $NodesFile "NodesFile"
if ($StateFile) {
    Require-File $StateFile "StateFile"
}
Require-File $SetupScript "SetupScript"
if ($AnsibleAuthorizedKeyFile) {
    Require-File $AnsibleAuthorizedKeyFile "AnsibleAuthorizedKeyFile"
}

$firstLine = Get-Content -LiteralPath $NodesFile -TotalCount 1
if ($firstLine -ne $ExpectedHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedHeader"
}
$stateRows = @()
if (-not $StateFile) {
    Fail "-StateFile is required. nodes.csv is only an address book; bootstrap behavior is selected from state.csv."
}
$stateFirstLine = Get-Content -LiteralPath $StateFile -TotalCount 1
if ($stateFirstLine -ne $ExpectedStateHeader) {
    Fail "state.csv header must be exactly: $ExpectedStateHeader"
}
$stateRows = Import-Csv -LiteralPath $StateFile

$rows = Import-Csv -LiteralPath $NodesFile
$row = $rows | Where-Object { $_.current_alias -eq $Alias } | Select-Object -First 1
if (-not $row) {
    Fail "Alias not found in nodes file: $Alias"
}
if ($row.connection -eq "local" -or $row.endpoint -eq "local") {
    Fail "Cannot bootstrap remote VPS with endpoint=local: $Alias. For first bootstrap from Windows, set endpoint to the VPS public DNS/IP and connection=ssh. Use local only later in the Orchestration inventory CSV if needed."
}
Assert-NoUtf8Bom $SetupScript "SetupScript"
$isManagementNode = Is-OrchestrationCapableNode $stateRows $Alias
$sshPort = Get-NodeSshPort $row
$useAdminKeyBootstrap = [string]::IsNullOrWhiteSpace([string]$row.root_password)
$keepExistingLocalKeys = (-not $useAdminKeyBootstrap)
$adminKeyFile = Join-Path (Join-Path $OperatorDir $Alias) "admin_key"
if (-not $isManagementNode -and -not $AnsibleAuthorizedKeyFile) {
    $activeOrchestrationAlias = Get-ActiveOrchestrationAlias $stateRows
    $activeOrchestrationPublicKeyFile = Join-Path (Join-Path $OperatorDir $activeOrchestrationAlias) "ansible_control.managed_nodes.pub"
    if (Test-Path -LiteralPath $activeOrchestrationPublicKeyFile -PathType Leaf) {
        $AnsibleAuthorizedKeyFile = $activeOrchestrationPublicKeyFile
    } else {
        $AnsibleAuthorizedKeyFile = Join-Path $OperatorDir "ansible_control.managed_nodes.pub"
    }
    Require-File $AnsibleAuthorizedKeyFile "AnsibleAuthorizedKeyFile"
}
if ($isManagementNode) {
    Assert-NoUtf8Bom $CreateInventoryScript "CreateInventoryScript"
    Assert-NoUtf8Bom $PrepareInventoryScript "PrepareInventoryScript"
    Assert-NoUtf8Bom $VerifyControlScript "VerifyControlScript"
}
if ($RegenerateRemoteKeys -and $isManagementNode -and -not $Force) {
    Fail "RegenerateRemoteKeys for a management node requires -Force so the local Ansible public key file is refreshed explicitly."
}
if ($useAdminKeyBootstrap) {
    if ([string]::IsNullOrWhiteSpace($AdminUser)) {
        Fail "AdminUser must not be empty for admin-key re-bootstrap."
    }
    Require-File $adminKeyFile "AdminKeyFile"
    Ensure-OpenSshPrivateKeyAcl $adminKeyFile
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        Fail "ssh not found in PATH. It is required for admin-key re-bootstrap."
    }
    if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
        Fail "scp not found in PATH. It is required for admin-key re-bootstrap."
    }
} else {
    if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
        Fail "plink not found in PATH"
    }
    if (-not (Get-Command pscp -ErrorAction SilentlyContinue)) {
        Fail "pscp not found in PATH"
    }
}
Assert-BootstrapKeyPathsAvailable $Alias $isManagementNode $OperatorDir $OutputAnsibleAuthorizedKeyFile $Force ($useAdminKeyBootstrap -or $keepExistingLocalKeys)

$sanitized = $null
$remoteLog = New-TemporaryFile
$stagedKeyRoot = ""
try {
    $sanitized = New-SanitizedNodesFileFromRows $rows

    if ($useAdminKeyBootstrap) {
        $remote = "$AdminUser@$($row.endpoint)"
        Write-Host "Re-bootstrapping $Alias at $($row.endpoint):$sshPort through admin key"
        Clear-OpenSshHostKeyCache $row.endpoint $sshPort
        Test-AdminKeyBootstrapPreflight $adminKeyFile $sshPort $remote $isManagementNode
    } else {
        $remote = "root@$($row.endpoint)"
        Write-Host "Bootstrapping $Alias at $($row.endpoint):$sshPort through root password"
        Clear-PuttyHostKeyCache $row.endpoint $sshPort
        $hostKeyFingerprint = Get-PuttyHostKeyFingerprint $remote $row.root_password $sshPort
    }

    Write-Host "Step 1/4: copy setup_vps.sh"
    if ($useAdminKeyBootstrap) {
        Invoke-ScpKey $adminKeyFile $sshPort $SetupScript "${remote}:/tmp/setup_vps.sh" "scp setup_vps.sh"
    } else {
        Invoke-PscpPassword $row.root_password $sshPort $SetupScript "${remote}:/tmp/setup_vps.sh" "pscp setup_vps.sh" $hostKeyFingerprint $Alias $row.endpoint
    }

    Write-Host "Step 2/4: copy sanitized nodes.csv"
    if ($useAdminKeyBootstrap) {
        Invoke-ScpKey $adminKeyFile $sshPort $sanitized "${remote}:/tmp/nodes.csv" "scp sanitized nodes.csv"
    } else {
        Invoke-PscpPassword $row.root_password $sshPort $sanitized "${remote}:/tmp/nodes.csv" "pscp sanitized nodes.csv" $hostKeyFingerprint $Alias $row.endpoint
    }

    if ($StateFile) {
        Write-Host "Step 2a/4: copy state.csv"
        if ($useAdminKeyBootstrap) {
            Invoke-ScpKey $adminKeyFile $sshPort $StateFile "${remote}:/tmp/state.csv" "scp state.csv"
        } else {
            Invoke-PscpPassword $row.root_password $sshPort $StateFile "${remote}:/tmp/state.csv" "pscp state.csv" $hostKeyFingerprint $Alias $row.endpoint
        }
    }

    if ($isManagementNode) {
        Write-Host "Step 2b/4: copy control inventory helpers"
        if ($useAdminKeyBootstrap) {
            Invoke-ScpKey $adminKeyFile $sshPort $CreateInventoryScript "${remote}:/tmp/create_inventory.sh" "scp create_inventory.sh"
            Invoke-ScpKey $adminKeyFile $sshPort $PrepareInventoryScript "${remote}:/tmp/prepare_orchestration_inventory.sh" "scp prepare_orchestration_inventory.sh"
            Invoke-ScpKey $adminKeyFile $sshPort $VerifyControlScript "${remote}:/tmp/verify_control_node.sh" "scp verify_control_node.sh"
        } else {
            Invoke-PscpPassword $row.root_password $sshPort $CreateInventoryScript "${remote}:/tmp/create_inventory.sh" "pscp create_inventory.sh" $hostKeyFingerprint $Alias $row.endpoint
            Invoke-PscpPassword $row.root_password $sshPort $PrepareInventoryScript "${remote}:/tmp/prepare_orchestration_inventory.sh" "pscp prepare_orchestration_inventory.sh" $hostKeyFingerprint $Alias $row.endpoint
            Invoke-PscpPassword $row.root_password $sshPort $VerifyControlScript "${remote}:/tmp/verify_control_node.sh" "pscp verify_control_node.sh" $hostKeyFingerprint $Alias $row.endpoint
        }
    }

    if ($AnsibleAuthorizedKeyFile) {
        Write-Host "Step 2c/4: copy Ansible control public key"
        if ($useAdminKeyBootstrap) {
            Invoke-ScpKey $adminKeyFile $sshPort $AnsibleAuthorizedKeyFile "${remote}:/tmp/ansible_control.managed_nodes.pub" "scp Ansible public key"
        } else {
            Invoke-PscpPassword $row.root_password $sshPort $AnsibleAuthorizedKeyFile "${remote}:/tmp/ansible_control.managed_nodes.pub" "pscp Ansible public key" $hostKeyFingerprint $Alias $row.endpoint
        }
    }

    if ($AnsibleAuthorizedKeyFile) {
        $setupCommand = "ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash /tmp/setup_vps.sh --nodes-file /tmp/nodes.csv --state-file /tmp/state.csv --alias '$Alias'"
    } else {
        $setupCommand = "bash /tmp/setup_vps.sh --nodes-file /tmp/nodes.csv --state-file /tmp/state.csv --alias '$Alias'"
    }
    if (-not $useAdminKeyBootstrap) {
        $setupCommand = "APPLY_SSH_HARDENING=0 $setupCommand"
    }
    if ($RegenerateRemoteKeys) {
        $setupCommand = "FORCE_REGENERATE_KEYS=1 $setupCommand"
    }

    if ($isManagementNode) {
        if ($StateFile) {
            $stateArg = "--source-state-file /tmp/state.csv"
        } else {
            $stateArg = ""
        }
        $prepareInventoryCommand = "if [ `$rc -eq 0 ]; then mkdir -p /opt/ai-service-platform/tools/bootstrap; install -m 700 /tmp/create_inventory.sh /opt/ai-service-platform/tools/bootstrap/create_inventory.sh; install -m 700 /tmp/prepare_orchestration_inventory.sh /opt/ai-service-platform/tools/bootstrap/prepare_orchestration_inventory.sh; install -m 700 /tmp/verify_control_node.sh /opt/ai-service-platform/tools/bootstrap/verify_control_node.sh; bash /opt/ai-service-platform/tools/bootstrap/prepare_orchestration_inventory.sh --source-nodes-file /tmp/nodes.csv $stateArg --skip-check; fi"
        $emitKeyCommand = "if [ `$rc -eq 0 ]; then echo $PublicKeyBeginMarker; cat /home/ansible/.ssh/ansible_control.managed_nodes.pub; echo $PublicKeyEndMarker; fi"
    } else {
        $prepareInventoryCommand = ":"
        $emitKeyCommand = ":"
    }
    if ($useAdminKeyBootstrap) {
        $remoteScript = "set +e; $setupCommand; rc=`$?; $prepareInventoryCommand; $emitKeyCommand; rm -f /tmp/setup_vps.sh /tmp/nodes.csv /tmp/state.csv /tmp/ansible_control.managed_nodes.pub /tmp/create_inventory.sh /tmp/prepare_orchestration_inventory.sh /tmp/verify_control_node.sh; exit `$rc"
        $remoteCommand = "sudo -n bash -lc $(Quote-BashArg $remoteScript)"
    } else {
        $remoteCommand = "set +e; $setupCommand; rc=`$?; $prepareInventoryCommand; $emitKeyCommand; rm -f /tmp/setup_vps.sh /tmp/nodes.csv /tmp/state.csv /tmp/ansible_control.managed_nodes.pub /tmp/create_inventory.sh /tmp/prepare_orchestration_inventory.sh /tmp/verify_control_node.sh; exit `$rc"
    }

    Write-Host "Step 3/4: run remote bootstrap"
    Write-Host "Expected next output: AI Service Platform VPS bootstrap"
    Write-Host "If this step stays silent for a long time, check PuTTY/plink host key cache, SSH banner prompts, and root password auth."
    if ($useAdminKeyBootstrap) {
        Invoke-SshKey $adminKeyFile $sshPort $remote $remoteCommand "remote setup_vps.sh" $remoteLog
        $remoteExitCode = 0
    } else {
        $plinkResult = Invoke-PlinkCommand $remote $row.root_password $sshPort $remoteCommand $remoteLog $hostKeyFingerprint
        $remoteExitCode = $plinkResult.ExitCode
    }
    $remoteOutput = Get-Content -LiteralPath $remoteLog -ErrorAction SilentlyContinue
    if ($remoteExitCode -ne 0) { Fail "remote setup_vps.sh failed" }

    if (-not $useAdminKeyBootstrap) {
        $stagedKeyRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.bootstrap-keys." + [guid]::NewGuid().ToString("N"))
        Save-BootstrapKeysToStaging $remoteOutput $Alias $isManagementNode $stagedKeyRoot
    }

    if (Test-BootstrapLocalMutationExpected $Alias $isManagementNode $OperatorDir $OutputAnsibleAuthorizedKeyFile $Force ($useAdminKeyBootstrap -or $keepExistingLocalKeys) (-not $useAdminKeyBootstrap)) {
        $sanitizeRootPasswordAlias = ""
        $backupStagedAlias = ""
        $backupStagedKeyRoot = ""
        $backupStagedIsManagement = $false
        $backupStagedPublicKeyPath = ""
        if (-not $useAdminKeyBootstrap) {
            $sanitizeRootPasswordAlias = $Alias
            if ($isManagementNode) {
                $backupStagedAlias = $Alias
                $backupStagedKeyRoot = $stagedKeyRoot
                $backupStagedIsManagement = $true
                $backupStagedPublicKeyPath = $OutputAnsibleAuthorizedKeyFile
            }
        }
        Invoke-OperatorBackupIfNeeded "save bootstrap keys or clear root_password for $Alias" $sanitizeRootPasswordAlias $backupStagedAlias $backupStagedKeyRoot $backupStagedIsManagement $backupStagedPublicKeyPath
    }

    Write-Host "Step 4/4: save bootstrap keys"
    if ($useAdminKeyBootstrap) {
        Save-BootstrapKeys $remoteOutput $Alias $isManagementNode $OperatorDir $OutputAnsibleAuthorizedKeyFile $Force $useAdminKeyBootstrap
    } else {
        Save-BootstrapKeys $remoteOutput $Alias $isManagementNode $OperatorDir $OutputAnsibleAuthorizedKeyFile $Force $keepExistingLocalKeys
    }

    if (-not $useAdminKeyBootstrap) {
        if ([string]::IsNullOrWhiteSpace($AdminUser)) {
            Fail "AdminUser must not be empty before fresh bootstrap SSH hardening."
        }
        $freshAdminRemote = "$AdminUser@$($row.endpoint)"
        Write-Host "Step 4b/4: verify fresh admin key login"
        Clear-OpenSshHostKeyCache $row.endpoint $sshPort
        Invoke-SshKey $adminKeyFile $sshPort $freshAdminRemote "sudo -n true" "fresh admin key verification"
        Write-Host "Step 4c/4: apply SSH hardening"
        Invoke-RemoteSshHardening $adminKeyFile $sshPort $freshAdminRemote
        Clear-RootPasswordForAlias $NodesFile $Alias
    }
    Write-Host "Bootstrap completed for $Alias"
} finally {
    if ($sanitized) {
        Remove-Item -LiteralPath $sanitized -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $remoteLog -Force -ErrorAction SilentlyContinue
    if ($stagedKeyRoot -and (Test-Path -LiteralPath $stagedKeyRoot -PathType Container)) {
        Remove-Item -LiteralPath $stagedKeyRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
