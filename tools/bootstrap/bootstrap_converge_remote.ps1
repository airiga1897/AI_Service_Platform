param(
    [string]$NodesFile = ".\operator\nodes.csv",

    [string]$StateFile = ".\operator\state.csv",

    [string]$ControlRole = "orchestration",

    [string]$ControlAlias = "",

    [string]$OperatorDir = ".\operator",

    [string]$SshUser = "useradmin",

    [string]$SshKeyFile = "",

    [string]$RemoteRepoDir = "/opt/ai-service-platform",

    [string]$RemoteInventory = "/opt/ai-service-platform/inventory.ini",

    [string]$AnsibleDir = "infra/ansible",

    [string]$Playbook = "infra/ansible/bootstrap_converge.yml",

    [Parameter(Mandatory=$true)]
    [string]$Limit,

    [Parameter(Mandatory=$true)]
    [string]$AnsibleAuthorizedKeyFile,

    [int]$RemoteJobPollSeconds = 2,

    [int]$RemoteJobReconnectAttempts = 30,

    [int]$RemoteJobHeartbeatSeconds = 10
)

$ErrorActionPreference = "Stop"
$ExpectedHeader = "current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
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
    if ($activeAliases.Count -ne 1) {
        Fail "Control role '$Role' must have exactly one active alias in state.csv."
    }

    $node = $NodeRows | Where-Object { $_.current_alias -eq $activeAliases[0] } | Select-Object -First 1
    if (-not $node) {
        Fail "Control alias from state.csv not found in nodes.csv: $($activeAliases[0])"
    }
    if ($node.connection -ne "ssh" -or $node.endpoint -eq "local") {
        Fail "Control node $($node.current_alias) must use connection=ssh and a real endpoint for bootstrap converge."
    }
    return $node
}

function New-BootstrapConvergeBundle($AnsibleDir, $AuthorizedKeyFile) {
    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        Fail "tar not found in PATH. It is required to upload bootstrap converge bundles."
    }

    $stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.bootstrap-converge." + [guid]::NewGuid().ToString("N"))
    $archivePath = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.bootstrap-converge." + [guid]::NewGuid().ToString("N") + ".tar.gz")
    New-Item -ItemType Directory -Path $stagingDir | Out-Null
    try {
        Copy-Item -LiteralPath $AnsibleDir -Destination (Join-Path $stagingDir "ansible") -Recurse
        Copy-Item -LiteralPath $AuthorizedKeyFile -Destination (Join-Path $stagingDir "ansible_authorized_keys.pub")
        & tar -czf $archivePath -C $stagingDir .
        if ($LASTEXITCODE -ne 0) {
            Fail "Failed to create bootstrap converge bundle archive"
        }
        return @{ ArchivePath = $archivePath; StagingDir = $stagingDir }
    } catch {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Invoke-External($FilePath, $Arguments, $Label) {
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label failed with exit code $LASTEXITCODE"
    }
}

function Invoke-ExternalRetryTransport($FilePath, $Arguments, $Label, $Attempts = 3) {
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        & $FilePath @Arguments
        if ($LASTEXITCODE -eq 0) {
            return
        }
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 255 -or $attempt -eq $Attempts) {
            Fail "$Label failed with exit code $exitCode"
        }
        Write-Host "$Label hit SSH transport reset (exit 255), retrying $attempt/$Attempts..."
        Start-Sleep -Seconds 2
    }
}

function Invoke-CleanupSsh($Arguments, $Label) {
    & ssh @Arguments 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "$Label failed with exit code $LASTEXITCODE; continuing because cleanup is best-effort"
    }
}

function Invoke-RemoteTempCleanup($SshArgs, $Remote) {
    $cleanupCommand = @(
        "find /tmp -maxdepth 1 -mindepth 1 -type d -name 'ai-service-platform.bootstrap-converge.*' -mmin +1440 -exec rm -rf -- {} +",
        "find /tmp -maxdepth 1 -mindepth 1 -type f -name 'ai-service-platform.bootstrap-converge.*.tar.gz' -mmin +1440 -delete"
    ) -join "; "
    Invoke-CleanupSsh ($SshArgs + @($Remote, $cleanupCommand)) "remote old bootstrap temp cleanup"
}

function Invoke-CaptureExternal($FilePath, $Arguments) {
    $output = & $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ }
    return @{ ExitCode = $LASTEXITCODE; Output = @($output) }
}

function Write-LfScript($Path, $Lines) {
    $content = (@($Lines) -join "`n") + "`n"
    [System.IO.File]::WriteAllText($Path, $content, [System.Text.Encoding]::ASCII)
}

function Wait-RemoteBootstrapJob([string[]]$SshArgs, [string]$Remote, [string]$RemoteLog, [string]$RemoteDone, [string]$RemoteExitCode, [string]$RemotePid, [int]$PollSeconds, [int]$ReconnectAttempts, [int]$HeartbeatSeconds) {
    $printedLines = 0
    $transportFailures = 0
    $lastHeartbeatAt = [DateTime]::UtcNow
    $currentStep = "bootstrap converge"
    $lastTask = ""

    while ($true) {
        $pollCommand = @(
            "set +e",
            "if [ -f $(Quote-BashArg $RemoteLog) ]; then tail -n +$($printedLines + 1) $(Quote-BashArg $RemoteLog); fi",
            "if [ -f $(Quote-BashArg $RemoteDone) ]; then echo __BOOTSTRAP_JOB_DONE__; cat $(Quote-BashArg $RemoteExitCode); elif [ -f $(Quote-BashArg $RemotePid) ] && ! kill -0 ""`$(cat $(Quote-BashArg $RemotePid))"" 2>/dev/null; then echo __BOOTSTRAP_JOB_DEAD__; fi"
        ) -join "; "

        $result = Invoke-CaptureExternal "ssh" ($SshArgs + @($Remote, $pollCommand))
        if ($result.ExitCode -eq 255) {
            $transportFailures++
            if ($transportFailures -gt $ReconnectAttempts) {
                Fail "remote bootstrap job polling failed after $ReconnectAttempts reconnect attempts"
            }
            Write-Host "remote bootstrap job polling hit SSH transport reset (exit 255), reconnecting $transportFailures/$ReconnectAttempts..."
            Start-Sleep -Seconds $PollSeconds
            continue
        }
        if ($result.ExitCode -ne 0) {
            Fail "remote bootstrap job polling failed with exit code $($result.ExitCode)"
        }
        $transportFailures = 0

        $doneIndex = [array]::IndexOf($result.Output, "__BOOTSTRAP_JOB_DONE__")
        if ($doneIndex -ge 0) {
            if ($doneIndex -gt 0) {
                foreach ($line in @($result.Output[0..($doneIndex - 1)])) {
                    if ($line -ne "__BOOTSTRAP_JOB_DONE__") {
                        Write-Host $line
                        $printedLines++
                    }
                }
            }
            $remoteExitCode = 1
            if ($result.Output.Count -gt ($doneIndex + 1)) {
                [void][int]::TryParse($result.Output[$doneIndex + 1], [ref]$remoteExitCode)
            }
            if ($remoteExitCode -ne 0) {
                Fail "remote bootstrap converge failed with exit code $remoteExitCode; log: $RemoteLog"
            }
            return
        }

        $deadIndex = [array]::IndexOf($result.Output, "__BOOTSTRAP_JOB_DEAD__")
        if ($deadIndex -ge 0) {
            if ($deadIndex -gt 0) {
                foreach ($line in @($result.Output[0..($deadIndex - 1)])) {
                    if ($line -ne "__BOOTSTRAP_JOB_DEAD__") {
                        Write-Host $line
                        $printedLines++
                    }
                }
            }
            Fail "remote bootstrap converge process exited without writing done/exit_code; log: $RemoteLog"
        }

        $printedThisPoll = 0
        foreach ($line in $result.Output) {
            if ($line) {
                Write-Host $line
                if ($line -match "^TASK \[(.+)\]") {
                    $lastTask = $Matches[1]
                } elseif ($line -match "^\[bootstrap\] (.+)$") {
                    $currentStep = $Matches[1]
                }
                $printedThisPoll++
            } else {
                Write-Host ""
                $printedThisPoll++
            }
        }
        $printedLines += $printedThisPoll

        $now = [DateTime]::UtcNow
        if ($printedThisPoll -eq 0 -and $HeartbeatSeconds -gt 0 -and (($now - $lastHeartbeatAt).TotalSeconds -ge $HeartbeatSeconds)) {
            $taskText = if ($lastTask) { "; last task: $lastTask" } else { "" }
            Write-Host ("[WAIT] {0} is still running{1}; remote log: {2}" -f $currentStep, $taskText, $RemoteLog)
            $lastHeartbeatAt = $now
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

Require-File $NodesFile "NodesFile"
Require-File $StateFile "StateFile"
Require-File $AnsibleAuthorizedKeyFile "AnsibleAuthorizedKeyFile"
if (-not (Test-Path -LiteralPath $AnsibleDir -PathType Container)) {
    Fail "AnsibleDir not found: $AnsibleDir"
}
Require-File $Playbook "Playbook"

$nodesHeader = Get-Content -LiteralPath $NodesFile -TotalCount 1
if ($nodesHeader -ne $ExpectedHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedHeader"
}
$stateHeader = Get-Content -LiteralPath $StateFile -TotalCount 1
if ($stateHeader -ne $ExpectedStateHeader) {
    Fail "state.csv header must be exactly: $ExpectedStateHeader"
}

$nodes = Import-Csv -LiteralPath $NodesFile
$stateRows = Import-Csv -LiteralPath $StateFile
$controlNode = Resolve-ControlNodeFromState $nodes $stateRows $ControlRole $ControlAlias

if (-not $SshKeyFile) {
    $SshKeyFile = Join-Path (Join-Path $OperatorDir $controlNode.current_alias) "admin_key"
}
Require-File $SshKeyFile "SshKeyFile"
Ensure-OpenSshPrivateKeyAcl $SshKeyFile

$remote = "$SshUser@$($controlNode.endpoint)"
$remoteBundleDir = "/tmp/ai-service-platform.bootstrap-converge.$([guid]::NewGuid().ToString('N'))"
$remoteBundleArchive = "$remoteBundleDir.tar.gz"
$remoteAnsibleTemp = "$remoteBundleDir/ansible"
$remoteAuthorizedKeyFile = "$remoteBundleDir/ansible_authorized_keys.pub"
$remoteJobId = "bootstrap-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$([guid]::NewGuid().ToString('N'))"
$remoteJobLogDir = "/var/log/ai-service-platform/jobs"
$remoteJobStateRoot = "/var/lib/ai-service-platform/jobs"
$remoteJobDir = "$remoteJobStateRoot/$remoteJobId"
$remoteJobScript = "$remoteJobDir/run.sh"
$remoteJobLog = "$remoteJobLogDir/$remoteJobId.log"
$remoteJobPid = "$remoteJobDir/pid"
$remoteJobExitCode = "$remoteJobDir/exit_code"
$remoteJobDone = "$remoteJobDir/done"

Write-Host "Control node: $($controlNode.current_alias) via role '$ControlRole'"
Write-Host "Remote:       $remote"
Write-Host "Limit:        $Limit"
Write-Host "Mode:         detached remote bootstrap converge job"
Write-Host "Job id:       $remoteJobId"
Write-Host "Remote log:   $remoteJobLog"

$sshCommonArgs = @(
    "-n",
    "-T",
    "-i", $SshKeyFile,
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "IdentitiesOnly=yes",
    "-o", "RequestTTY=no",
    "-o", "KbdInteractiveAuthentication=no",
    "-o", "PasswordAuthentication=no",
    "-o", "PreferredAuthentications=publickey",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=2"
)
$scpCommonArgs = @(
    "-B",
    "-i", $SshKeyFile,
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "IdentitiesOnly=yes",
    "-o", "KbdInteractiveAuthentication=no",
    "-o", "PasswordAuthentication=no",
    "-o", "PreferredAuthentications=publickey",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=2"
)

$runScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.bootstrap-job." + [guid]::NewGuid().ToString("N") + ".sh")
$remoteJobCompletedSuccessfully = $false
$playbookPath = "$RemoteRepoDir/$($Playbook.Replace('\', '/'))"
$remoteAnsiblePath = "$RemoteRepoDir/infra/ansible"
$ansibleSshCommonArgs = "-o BatchMode=yes -o KbdInteractiveAuthentication=no -o PasswordAuthentication=no -o PreferredAuthentications=publickey -o RequestTTY=no"
$ansibleCommand = "sudo -u ansible env ANSIBLE_TIMEOUT=20 ANSIBLE_SSH_COMMON_ARGS=$(Quote-BashArg $ansibleSshCommonArgs) ansible-playbook -i $(Quote-BashArg $RemoteInventory) $(Quote-BashArg $playbookPath) --limit $(Quote-BashArg $Limit) -e bootstrap_converge_authorized_keys_file=$(Quote-BashArg $remoteAuthorizedKeyFile)"
$runScriptLines = @(
    "#!/usr/bin/env bash",
    "set +e",
    "export PYTHONUNBUFFERED=1",
    "export ANSIBLE_FORCE_COLOR=0",
    "export ANSIBLE_DISPLAY_SKIPPED_HOSTS=true",
    "export ANSIBLE_TIMEOUT=20",
    "export ANSIBLE_SSH_COMMON_ARGS='-o BatchMode=yes -o KbdInteractiveAuthentication=no -o PasswordAuthentication=no -o PreferredAuthentications=publickey -o RequestTTY=no'",
    "exec > $(Quote-BashArg $remoteJobLog) 2>&1",
    "printf '[bootstrap] install Ansible bundle\n'",
    "sudo mkdir -p $(Quote-BashArg "$RemoteRepoDir/infra")",
    "sudo rm -rf $(Quote-BashArg $remoteAnsiblePath)",
    "sudo cp -a $(Quote-BashArg $remoteAnsibleTemp) $(Quote-BashArg $remoteAnsiblePath)",
    "printf '[bootstrap] run bootstrap converge for $(Quote-BashArg $Limit)\n'",
    "cd $(Quote-BashArg $RemoteRepoDir)",
    $ansibleCommand,
    "rc=`$?",
    "printf '[bootstrap] converge finished with rc=%s\n' ""`$rc""",
    "printf '%s\n' ""`$rc"" > $(Quote-BashArg $remoteJobExitCode)",
    "touch $(Quote-BashArg $remoteJobDone)",
    "exit ""`$rc"""
)

try {
    Write-Host "Preparing local bootstrap converge bundle..."
    $bundle = New-BootstrapConvergeBundle $AnsibleDir $AnsibleAuthorizedKeyFile
    Write-LfScript $runScriptPath $runScriptLines

    Invoke-RemoteTempCleanup $sshCommonArgs $remote

    Write-Host "Creating remote temporary bundle and durable job directories..."
    $mkdirCommand = @(
        "set -e",
        "mkdir -p $(Quote-BashArg $remoteBundleDir)",
        "sudo mkdir -p $(Quote-BashArg $remoteJobLogDir) $(Quote-BashArg $remoteJobDir)",
        "sudo chown ""`$(id -u):`$(id -g)"" $(Quote-BashArg $remoteJobLogDir) $(Quote-BashArg $remoteJobDir)",
        "chmod 750 $(Quote-BashArg $remoteJobDir)"
    ) -join "; "
    Invoke-ExternalRetryTransport "ssh" ($sshCommonArgs + @(
        $remote,
        $mkdirCommand
    )) "remote bootstrap converge directory creation"

    Write-Host "Uploading bootstrap converge bundle archive..."
    Invoke-External "scp" ($scpCommonArgs + @(
        $bundle.ArchivePath,
        "${remote}:$remoteBundleArchive"
    )) "bootstrap converge bundle upload"

    Write-Host "Uploading remote bootstrap job runner..."
    Invoke-External "scp" ($scpCommonArgs + @(
        $runScriptPath,
        "${remote}:$remoteJobScript"
    )) "remote bootstrap job runner upload"

    Write-Host "Extracting bootstrap converge bundle on orchestration node..."
    $extractCommand = @(
        "set -e",
        "rm -rf $(Quote-BashArg $remoteBundleDir)",
        "mkdir -p $(Quote-BashArg $remoteBundleDir)",
        "tar -xzf $(Quote-BashArg $remoteBundleArchive) -C $(Quote-BashArg $remoteBundleDir)",
        "test -d $(Quote-BashArg $remoteAnsibleTemp)",
        "test -f $(Quote-BashArg $remoteAuthorizedKeyFile)"
    ) -join "; "
    Invoke-ExternalRetryTransport "ssh" ($sshCommonArgs + @($remote, $extractCommand)) "remote bootstrap converge bundle extract"

    Write-Host "Starting remote bootstrap converge job..."
    $startJobCommand = @(
        "set -e",
        "chmod 700 $(Quote-BashArg $remoteJobScript)",
        "rm -f $(Quote-BashArg $remoteJobLog) $(Quote-BashArg $remoteJobExitCode) $(Quote-BashArg $remoteJobDone) $(Quote-BashArg $remoteJobPid)",
        "nohup bash $(Quote-BashArg $remoteJobScript) </dev/null >/dev/null 2>&1 & echo `$! > $(Quote-BashArg $remoteJobPid)"
    ) -join "; "
    Invoke-ExternalRetryTransport "ssh" ($sshCommonArgs + @($remote, $startJobCommand)) "remote bootstrap converge job start"

    Write-Host "Following remote bootstrap converge log..."
    Wait-RemoteBootstrapJob -SshArgs ([string[]]$sshCommonArgs) -Remote $remote -RemoteLog $remoteJobLog -RemoteDone $remoteJobDone -RemoteExitCode $remoteJobExitCode -RemotePid $remoteJobPid -PollSeconds $RemoteJobPollSeconds -ReconnectAttempts $RemoteJobReconnectAttempts -HeartbeatSeconds $RemoteJobHeartbeatSeconds
    $remoteJobCompletedSuccessfully = $true
} finally {
    if ($bundle) {
        Remove-Item -LiteralPath $bundle.ArchivePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $bundle.StagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $runScriptPath -Force -ErrorAction SilentlyContinue
    if ($remoteJobCompletedSuccessfully) {
        Write-Host "Cleaning remote bootstrap converge bundle and completed job state; preserving rotated job log: $remoteJobLog"
        $cleanupTarget = "rm -rf $(Quote-BashArg $remoteBundleDir) $(Quote-BashArg $remoteBundleArchive); sudo rm -rf $(Quote-BashArg $remoteJobDir)"
    } else {
        Write-Host "Cleaning remote bootstrap converge bundle; preserving failed job state: $remoteJobDir and log: $remoteJobLog"
        $cleanupTarget = "rm -rf $(Quote-BashArg $remoteBundleDir) $(Quote-BashArg $remoteBundleArchive)"
    }
    if ($remote -and $remoteBundleDir -and $remoteBundleArchive -and $remoteJobDir -and $sshCommonArgs) {
        Invoke-CleanupSsh ($sshCommonArgs + @($remote, $cleanupTarget)) "remote bootstrap converge cleanup"
    }
}
