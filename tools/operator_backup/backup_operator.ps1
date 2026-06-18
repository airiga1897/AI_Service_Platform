param(
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$StateFile = ".\operator\state.csv",
    [string]$OperatorDir = ".\operator",
    [string]$ControlRole = "orchestration",
    [string]$OperatorBackupEnvFile = "D:\Projects\Ai_SP\Secure\operator-backup.env",
    [string]$LocalBackupDir = "D:\Backup\Projects\AI_SP\operator",
    [string]$RemoteBackupDir = "/opt/backups/ai-service-platform/operator",
    [string]$AdminUser = "useradmin",
    [int]$KeepLatest = 30,
    [switch]$AutoAcceptHostKey = $true
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,connection,root_password"
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

function Require-Dir($Path, $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Fail "$Label not found: $Path"
    }
}

function Split-AliasList($Value) {
    if (-not $Value) {
        return @()
    }
    return @($Value -split "\+" | Where-Object { $_ })
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

function Invoke-SshKey($KeyFile, $Remote, $Command, $Label) {
    $sshArgs = @("-n", "-T") + @(Get-OpenSshCommonArgs $KeyFile) + @("-o", "RequestTTY=no", $Remote, $Command)
    $previousErrorActionPreference = $ErrorActionPreference
    $exitCode = 0
    try {
        $script:ErrorActionPreference = "Continue"
        & ssh @sshArgs
        $exitCode = $LASTEXITCODE
    } finally {
        $script:ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        Fail "$Label failed with exit code $exitCode"
    }
}

function Invoke-ScpKey($KeyFile, $Source, $Target, $Label) {
    $scpArgs = @("-B") + @(Get-OpenSshCommonArgs $KeyFile) + @($Source, $Target)
    $previousErrorActionPreference = $ErrorActionPreference
    $exitCode = 0
    try {
        $script:ErrorActionPreference = "Continue"
        & scp @scpArgs
        $exitCode = $LASTEXITCODE
    } finally {
        $script:ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        Fail "$Label failed with exit code $exitCode"
    }
}

function Invoke-LocalBackupRotation($BackupDir, $Keep) {
    if ($Keep -le 0) {
        return
    }

    $archives = @(Get-ChildItem -LiteralPath $BackupDir -File -Filter "operator-backup-*.tar.gz.age" |
        Sort-Object Name -Descending)
    if ($archives.Count -le $Keep) {
        return
    }

    foreach ($archive in @($archives | Select-Object -Skip $Keep)) {
        $checksum = "$($archive.FullName).sha256"
        Write-Host "Rotating old local operator backup: $($archive.Name)"
        Remove-Item -LiteralPath $archive.FullName -Force
        Remove-Item -LiteralPath $checksum -Force -ErrorAction SilentlyContinue
    }
}

function New-RemoteBackupRotationCommand($BackupDir, $Keep) {
    if ($Keep -le 0) {
        return ""
    }

    $quotedDir = Quote-BashArg $BackupDir
    $quotedKeep = Quote-BashArg ([string]$Keep)
    return @(
        "backup_dir=$quotedDir",
        "keep_latest=$quotedKeep",
        "if [ -d ""`$backup_dir"" ]; then old_files=`$(find ""`$backup_dir"" -maxdepth 1 -type f -name 'operator-backup-*.tar.gz.age' -printf '%f\n' | sort -r | tail -n +`$((keep_latest + 1)))",
        "for old_file in `$old_files; do sudo rm -f -- ""`$backup_dir/`$old_file"" ""`$backup_dir/`$old_file.sha256""",
        "done",
        "fi"
    ) -join "; "
}

function Get-StandbyOrchestrationAliases($Rows, $Role) {
    $roleRows = @($Rows | Where-Object { ($_.kind -eq "platform_role" -or $_.kind -eq "role") -and $_.name -eq $Role -and $_.state -eq "present" })
    if ($roleRows.Count -eq 0) {
        Fail "state.csv has no present platform_role '$Role'"
    }
    if ($roleRows.Count -gt 1) {
        Fail "state.csv has multiple present platform_role '$Role' rows; keep exactly one"
    }

    $aliases = @(Split-AliasList $roleRows[0].candidate_aliases)
    if ($aliases.Count -eq 0) {
        Fail "state.csv has no standby orchestration candidate aliases for platform_role '$Role'. Use -SkipOperatorBackup only for emergency/manual override in the parent script."
    }
    return $aliases
}

function Import-OperatorBackupEnvFile($Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    Write-Host "Loading operator backup env as key-value text: $Path"
    foreach ($rawLine in (Get-Content -LiteralPath $Path)) {
        $line = ([string]$rawLine).Trim()
        if (-not $line -or $line.StartsWith("#")) {
            continue
        }

        $match = [regex]::Match(
            $line,
            '^(?:\$env:)?AI_SP_OPERATOR_BACKUP_AGE_RECIPIENT\s*=\s*(?<value>.*)$'
        )
        if (-not $match.Success) {
            continue
        }

        $value = $match.Groups["value"].Value.Trim()
        if (
            ($value.Length -ge 2) -and
            (
                ($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))
            )
        ) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        if ($value -match '^AGE-SECRET-KEY-') {
            Fail "Operator backup env file contains a private age identity, not a public recipient: $Path"
        }
        $env:AI_SP_OPERATOR_BACKUP_AGE_RECIPIENT = $value
        return
    }
}

if ([string]::IsNullOrWhiteSpace($env:AI_SP_OPERATOR_BACKUP_AGE_RECIPIENT)) {
    Import-OperatorBackupEnvFile $OperatorBackupEnvFile
    if ([string]::IsNullOrWhiteSpace($env:AI_SP_OPERATOR_BACKUP_AGE_RECIPIENT)) {
        Fail "AI_SP_OPERATOR_BACKUP_AGE_RECIPIENT is not set. Expected operator backup env file: $OperatorBackupEnvFile. The env file is parsed as key-value text, not executed; create it with AI_SP_OPERATOR_BACKUP_AGE_RECIPIENT=age1... or pass -OperatorBackupEnvFile."
    }
}
if ($env:AI_SP_OPERATOR_BACKUP_AGE_RECIPIENT -match '^AGE-SECRET-KEY-') {
    Fail "AI_SP_OPERATOR_BACKUP_AGE_RECIPIENT must be a public age recipient (age1...), not a private age identity."
}
if ($env:AI_SP_OPERATOR_BACKUP_AGE_RECIPIENT -notmatch '^age1') {
    Fail "AI_SP_OPERATOR_BACKUP_AGE_RECIPIENT must look like a public age recipient starting with age1."
}
if ($KeepLatest -lt 0) {
    Fail "KeepLatest must be 0 or greater"
}

if (-not (Get-Command age -ErrorAction SilentlyContinue)) {
    Fail "age not found in PATH"
}
if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    Fail "tar not found in PATH"
}
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Fail "ssh not found in PATH"
}
if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
    Fail "scp not found in PATH"
}

Require-File $NodesFile "NodesFile"
Require-File $StateFile "StateFile"
Require-Dir $OperatorDir "OperatorDir"

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
$standbyAliases = @(Get-StandbyOrchestrationAliases $stateRows $ControlRole)

$operatorPath = (Resolve-Path -LiteralPath $OperatorDir).Path
$operatorParent = Split-Path -Parent $operatorPath
$operatorLeaf = Split-Path -Leaf $operatorPath
$timestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$artifactBase = "operator-backup-$timestamp.tar.gz"
$rawArchive = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.$artifactBase")
$encryptedName = "$artifactBase.age"
$checksumName = "$encryptedName.sha256"
$localEncrypted = Join-Path $LocalBackupDir $encryptedName
$localChecksum = Join-Path $LocalBackupDir $checksumName

try {
    New-Item -ItemType Directory -Force -Path $LocalBackupDir | Out-Null

    Write-Host "Creating temporary operator archive: $rawArchive"
    & tar -czf $rawArchive -C $operatorParent $operatorLeaf
    if ($LASTEXITCODE -ne 0) {
        Fail "tar failed with exit code $LASTEXITCODE"
    }

    Write-Host "Encrypting operator backup: $localEncrypted"
    & age -r $env:AI_SP_OPERATOR_BACKUP_AGE_RECIPIENT -o $localEncrypted $rawArchive
    if ($LASTEXITCODE -ne 0) {
        Fail "age encryption failed with exit code $LASTEXITCODE"
    }

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $localEncrypted).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $localChecksum -Value ("$hash  $encryptedName") -Encoding ascii
    Write-Host "Wrote checksum: $localChecksum"

    foreach ($alias in $standbyAliases) {
        $node = $nodeRows | Where-Object { $_.current_alias -eq $alias } | Select-Object -First 1
        if (-not $node) {
            Fail "Standby orchestration alias not found in nodes.csv: $alias"
        }
        if ($node.connection -ne "ssh" -or $node.endpoint -eq "local") {
            Fail "Standby orchestration alias $alias must use connection=ssh and a real endpoint."
        }
        $adminKey = Join-Path (Join-Path $OperatorDir $alias) "admin_key"
        Require-File $adminKey "Admin key for standby orchestration alias $alias"

        $remote = "$AdminUser@$($node.endpoint)"
        $remoteTempDir = "/tmp/ai-service-platform.operator-backup.$([guid]::NewGuid().ToString('N'))"
        Write-Host "Uploading encrypted operator backup to standby orchestration alias ${alias}: $RemoteBackupDir"
        Invoke-SshKey $adminKey $remote ("mkdir -p " + (Quote-BashArg $remoteTempDir)) "remote temp backup dir create"
        try {
            Invoke-ScpKey $adminKey $localEncrypted "${remote}:$remoteTempDir/$encryptedName" "scp encrypted operator backup"
            Invoke-ScpKey $adminKey $localChecksum "${remote}:$remoteTempDir/$checksumName" "scp encrypted operator backup checksum"
            $installParts = @(
                "set -e",
                ("sudo mkdir -p " + (Quote-BashArg $RemoteBackupDir)),
                ("sudo install -m 600 " + (Quote-BashArg "$remoteTempDir/$encryptedName") + " " + (Quote-BashArg "$RemoteBackupDir/$encryptedName")),
                ("sudo install -m 600 " + (Quote-BashArg "$remoteTempDir/$checksumName") + " " + (Quote-BashArg "$RemoteBackupDir/$checksumName"))
            )
            $remoteRotationCommand = New-RemoteBackupRotationCommand $RemoteBackupDir $KeepLatest
            if ($remoteRotationCommand) {
                $installParts += $remoteRotationCommand
            }
            $installCommand = $installParts -join "; "
            Invoke-SshKey $adminKey $remote $installCommand "remote encrypted operator backup install"
        } finally {
            $cleanupCommand = "rm -rf " + (Quote-BashArg $remoteTempDir)
            & ssh @(@("-n", "-T") + @(Get-OpenSshCommonArgs $adminKey) + @("-o", "RequestTTY=no", $remote, $cleanupCommand)) 2>$null | Out-Null
        }
    }

    Invoke-LocalBackupRotation $LocalBackupDir $KeepLatest
    Write-Host "[OK] Encrypted operator backup completed: $localEncrypted"
} finally {
    Remove-Item -LiteralPath $rawArchive -Force -ErrorAction SilentlyContinue
}
