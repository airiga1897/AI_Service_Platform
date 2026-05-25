param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Service,

    [Parameter(Mandatory=$true, Position=1)]
    [ValidateSet("plan", "apply", "absent", "purge", "reseed")]
    [string]$Action,

    [string]$NodesFile = ".\operator\nodes.csv",

    [string]$StateFile = ".\operator\state.csv",

    [string]$ControlRole = "orchestration",

    [string]$ControlAlias = "",

    [string]$OperatorDir = ".\operator",

    [string]$SshUser = "useradmin",

    [string]$SshKeyFile = "",

    [string]$RemoteRepoDir = "/opt/ai-service-platform",

    [string]$RemoteNodesFile = "/opt/ai-service-platform/operator/nodes.csv",

    [string]$RemoteStateFile = "/opt/ai-service-platform/operator/state.csv",

    [string]$RemoteInventory = "/opt/ai-service-platform/inventory.ini",

    [string]$ServiceRunnerScript = "tools/services/service.sh",

    [string]$AnsibleDir = "infra/ansible",

    [string]$Limit = "",

    [switch]$Check,

    [switch]$ConfirmPurge,

    [switch]$DetachedRemoteJob,

    [int]$RemoteJobPollSeconds = 2,

    [int]$RemoteJobReconnectAttempts = 30,

    [int]$RemoteJobHeartbeatSeconds = 10
)

$ErrorActionPreference = "Stop"
$ExpectedHeader = "current_alias,endpoint,connection,root_password"
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

function New-TarGzBundle($ServiceRunnerScript, $AnsibleDir) {
    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        Fail "tar not found in PATH. It is required to upload service bundles as a single archive."
    }

    $stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.service-remote." + [guid]::NewGuid().ToString("N"))
    $archivePath = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.service-remote." + [guid]::NewGuid().ToString("N") + ".tar.gz")
    New-Item -ItemType Directory -Path $stagingDir | Out-Null
    try {
        Copy-Item -LiteralPath $ServiceRunnerScript -Destination (Join-Path $stagingDir "service.sh")
        Copy-Item -LiteralPath $AnsibleDir -Destination (Join-Path $stagingDir "ansible") -Recurse
        & tar -czf $archivePath -C $stagingDir .
        if ($LASTEXITCODE -ne 0) {
            Fail "Failed to create service bundle archive"
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

function Invoke-CaptureExternal($FilePath, $Arguments) {
    $output = & $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ }
    return @{ ExitCode = $LASTEXITCODE; Output = @($output) }
}

function Format-Elapsed($StartedAt) {
    $elapsed = [DateTime]::UtcNow - $StartedAt
    return "{0:00}:{1:00}:{2:00}" -f [int]$elapsed.TotalHours, $elapsed.Minutes, $elapsed.Seconds
}

function Wait-RemoteServiceJob($SshArgs, $Remote, $RemoteLog, $RemoteDone, $RemoteExitCode, $PollSeconds, $ReconnectAttempts, $HeartbeatSeconds) {
    $printedLines = 0
    $transportFailures = 0
    $startedAt = [DateTime]::UtcNow
    $lastHeartbeatAt = $startedAt

    while ($true) {
        $pollCommand = @(
            "if [ -f $(Quote-BashArg $RemoteLog) ]; then tail -n +$($printedLines + 1) $(Quote-BashArg $RemoteLog); fi",
            "if [ -f $(Quote-BashArg $RemoteDone) ]; then echo __SERVICE_JOB_DONE__; cat $(Quote-BashArg $RemoteExitCode); fi"
        ) -join "; "
        $result = Invoke-CaptureExternal "ssh" ($SshArgs + @($Remote, $pollCommand))

        if ($result.ExitCode -eq 255) {
            $transportFailures++
            if ($transportFailures -gt $ReconnectAttempts) {
                Fail "remote job status unavailable after $ReconnectAttempts reconnect attempts"
            }
            Write-Host "remote job polling hit SSH transport reset (exit 255), reconnecting $transportFailures/$ReconnectAttempts..."
            Start-Sleep -Seconds $PollSeconds
            continue
        }
        if ($result.ExitCode -ne 0) {
            Fail "remote job status check failed with exit code $($result.ExitCode)"
        }

        $transportFailures = 0
        $doneIndex = [Array]::IndexOf($result.Output, "__SERVICE_JOB_DONE__")
        if ($doneIndex -ge 0) {
            if ($doneIndex -gt 0) {
                foreach ($line in @($result.Output[0..($doneIndex - 1)])) {
                    if ($line -ne "__SERVICE_JOB_DONE__") {
                        Write-Host $line
                        $printedLines++
                    }
                }
            }
            $exitCodeText = "1"
            if ($result.Output.Count -gt ($doneIndex + 1)) {
                $exitCodeText = $result.Output[$doneIndex + 1]
            }
            $exitCode = 1
            if (-not [int]::TryParse($exitCodeText, [ref]$exitCode)) {
                Fail "remote job completed but exit_code is invalid: $exitCodeText"
            }
            if ($exitCode -ne 0) {
                Fail "remote service command failed with exit code $exitCode"
            }
            Write-Host ("remote job completed successfully after {0}" -f (Format-Elapsed $startedAt))
            return
        }

        $printedThisPoll = 0
        foreach ($line in $result.Output) {
            if ($line) {
                Write-Host $line
                $printedThisPoll++
            } else {
                Write-Host ""
            }
            $printedLines++
        }

        $now = [DateTime]::UtcNow
        if ($printedThisPoll -eq 0 -and $HeartbeatSeconds -gt 0 -and (($now - $lastHeartbeatAt).TotalSeconds -ge $HeartbeatSeconds)) {
            Write-Host ("remote job still running... elapsed {0}, polling every {1}s" -f (Format-Elapsed $startedAt), $PollSeconds)
            $lastHeartbeatAt = $now
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Resolve-ControlNodeFromState($NodeRows, $StateRows, $Role, $ExplicitAlias) {
    $roleRows = @($StateRows | Where-Object { ($_.kind -eq "platform_role" -or $_.kind -eq "role") -and $_.name -eq $Role -and $_.state -eq "present" })
    if ($roleRows.Count -eq 0) {
        Fail "No active orchestration role found in state.csv: kind=platform_role,name=$Role,state=present"
    }
    if ($roleRows.Count -gt 1) {
        Fail "Multiple state.csv rows found for role '$Role'. Keep exactly one row."
    }

    $activeAliases = @(Split-AliasList $roleRows[0].active_aliases)
    if ($ExplicitAlias) {
        if ($activeAliases -notcontains $ExplicitAlias) {
            Fail "Control alias $ExplicitAlias is not active for role '$Role' in state.csv."
        }
        $activeAliases = @($ExplicitAlias)
    }
    if ($activeAliases.Count -eq 0) {
        Fail "Control role '$Role' must have exactly one active alias in state.csv."
    }
    if ($activeAliases.Count -gt 1) {
        Fail "Control role '$Role' has multiple active aliases in state.csv: $($activeAliases -join ', '). Keep one active alias and put reserve nodes in candidate_aliases."
    }

    $node = $NodeRows | Where-Object { $_.current_alias -eq $activeAliases[0] } | Select-Object -First 1
    if (-not $node) {
        Fail "Control alias from state.csv not found in nodes.csv: $($activeAliases[0])"
    }
    if ($node.connection -ne "ssh" -or $node.endpoint -eq "local") {
        Fail "Control node $($node.current_alias) must use connection=ssh and a real endpoint for remote service execution."
    }

    return $node
}

if ($Service -eq "vpn") {
    Fail "Unsupported service 'vpn'. Use canonical service name: vpn_edge"
}
if ($Service -eq "vpn_cascade") {
    Fail "Service 'vpn_cascade' is reserved for future site-to-site/cascade rollout and is not implemented yet."
}

Require-File $NodesFile "NodesFile"
Require-File $StateFile "StateFile"

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Fail "ssh not found in PATH. Install Windows OpenSSH Client or fix PATH."
}
if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
    Fail "scp not found in PATH. Install Windows OpenSSH Client or fix PATH."
}

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
Require-File $ServiceRunnerScript "ServiceRunnerScript"
if (-not (Test-Path -LiteralPath $AnsibleDir -PathType Container)) {
    Fail "AnsibleDir not found: $AnsibleDir"
}

$remote = "$SshUser@$($controlNode.endpoint)"
$remoteBundleDir = "/tmp/ai-service-platform.service-remote.$([guid]::NewGuid().ToString('N'))"
$remoteBundleArchive = "$remoteBundleDir.tar.gz"
$remoteServiceRunnerTemp = "$remoteBundleDir/service.sh"
$remoteAnsibleTemp = "$remoteBundleDir/ansible"
$remoteJobDir = "/tmp/ai-service-platform.service-job.$([guid]::NewGuid().ToString('N'))"
$remoteJobScript = "$remoteJobDir/run.sh"
$remoteJobLog = "$remoteJobDir/output.log"
$remoteJobPid = "$remoteJobDir/pid"
$remoteJobExitCode = "$remoteJobDir/exit_code"
$remoteJobDone = "$remoteJobDir/done"
$remoteArgs = @(
    (Quote-BashArg $Service),
    (Quote-BashArg $Action),
    "--nodes-file", (Quote-BashArg $RemoteNodesFile),
    "--state-file", (Quote-BashArg $RemoteStateFile),
    "--inventory", (Quote-BashArg $RemoteInventory)
)
if ($Limit) {
    $remoteArgs += @("--limit", (Quote-BashArg $Limit))
}
if ($Check) {
    $remoteArgs += "--check"
}
if ($ConfirmPurge) {
    $remoteArgs += "--confirm-purge"
}

$serviceCommand = @(
    "set -e",
    "cd $(Quote-BashArg $RemoteRepoDir)",
    "if command -v stdbuf >/dev/null 2>&1; then stdbuf -oL -eL bash tools/services/service.sh $($remoteArgs -join ' '); else bash tools/services/service.sh $($remoteArgs -join ' '); fi"
) -join "; "
$installCommands = @(
    "set -e",
    "sudo mkdir -p $(Quote-BashArg "$RemoteRepoDir/tools/services") $(Quote-BashArg "$RemoteRepoDir/infra")",
    "sudo install -m 700 $(Quote-BashArg $remoteServiceRunnerTemp) $(Quote-BashArg "$RemoteRepoDir/tools/services/service.sh")",
    "sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/infra/ansible")",
    "sudo cp -a $(Quote-BashArg $remoteAnsibleTemp) $(Quote-BashArg "$RemoteRepoDir/infra/ansible")",
    "sudo bash -lc $(Quote-BashArg $serviceCommand)"
) -join "; "

Write-Host "Control node: $($controlNode.current_alias) via role '$ControlRole'"
Write-Host "Remote:       $remote"
Write-Host "Service:      $Service"
Write-Host "Action:       $Action"
if ($Limit) {
    Write-Host "Limit:        $Limit"
}
if ($Check) {
    Write-Host "Check:        true"
}
if ($DetachedRemoteJob) {
    Write-Host "Mode:         detached remote job"
} else {
    Write-Host "Mode:         direct SSH stream"
}

$sshCommonArgs = @(
    "-n",
    "-T",
    "-i", $SshKeyFile,
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "IdentitiesOnly=yes",
    "-o", "RequestTTY=no",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=2"
)
$scpCommonArgs = @(
    "-B",
    "-i", $SshKeyFile,
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "IdentitiesOnly=yes",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=2"
)
$runScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.service-job." + [guid]::NewGuid().ToString("N") + ".sh")
$remoteServiceDisplayArgs = @($Service, $Action)
if ($Limit) {
    $remoteServiceDisplayArgs += @("--limit", $Limit)
}
if ($Check) {
    $remoteServiceDisplayArgs += "--check"
}
if ($ConfirmPurge) {
    $remoteServiceDisplayArgs += "--confirm-purge"
}
$remoteServiceDisplay = $remoteServiceDisplayArgs -join " "
$runScriptLines = @(
    "#!/usr/bin/env bash",
    "set +e",
    "export PYTHONUNBUFFERED=1",
    "export ANSIBLE_FORCE_COLOR=0",
    "export ANSIBLE_DISPLAY_SKIPPED_HOSTS=true",
    "exec > $(Quote-BashArg $remoteJobLog) 2>&1",
    "log_stage() { printf '[remote-job] %s %s\n' ""`$(date -u '+%H:%M:%S')"" ""`$*""; }",
    "run_stage() { label=""`$1""; shift; log_stage ""`$label""; ""`$@""; rc=""`$?""; if [ ""`$rc"" -ne 0 ]; then log_stage ""failed: `$label (rc=`$rc)""; return ""`$rc""; fi; }",
    "run_stage $(Quote-BashArg "prepare repo directories") sudo mkdir -p $(Quote-BashArg "$RemoteRepoDir/tools/services") $(Quote-BashArg "$RemoteRepoDir/infra")",
    "run_stage $(Quote-BashArg "install service runner") sudo install -m 700 $(Quote-BashArg $remoteServiceRunnerTemp) $(Quote-BashArg "$RemoteRepoDir/tools/services/service.sh")",
    "run_stage $(Quote-BashArg "remove previous Ansible bundle") sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/infra/ansible")",
    "run_stage $(Quote-BashArg "install Ansible bundle") sudo cp -a $(Quote-BashArg $remoteAnsibleTemp) $(Quote-BashArg "$RemoteRepoDir/infra/ansible")",
    "log_stage $(Quote-BashArg "running service command: $remoteServiceDisplay")",
    "sudo bash -lc $(Quote-BashArg $serviceCommand)",
    "rc=`$?",
    "log_stage ""service command finished with rc=`$rc""",
    "printf '%s\n' `$rc > $(Quote-BashArg $remoteJobExitCode)",
    "touch $(Quote-BashArg $remoteJobDone)",
    "exit `$rc"
)

try {
    Write-Host "Preparing local service bundle..."
    $bundle = New-TarGzBundle $ServiceRunnerScript $AnsibleDir
    if ($DetachedRemoteJob) {
        Set-Content -LiteralPath $runScriptPath -Value $runScriptLines -Encoding ascii
    }

    if ($DetachedRemoteJob) {
        Write-Host "Creating remote temporary bundle and job directories..."
        $mkdirCommand = "mkdir -p $(Quote-BashArg $remoteBundleDir) $(Quote-BashArg $remoteJobDir)"
    } else {
        Write-Host "Creating remote temporary bundle directory..."
        $mkdirCommand = "mkdir -p $(Quote-BashArg $remoteBundleDir)"
    }
    Invoke-ExternalRetryTransport "ssh" ($sshCommonArgs + @(
        $remote,
        $mkdirCommand
    )) "remote service bundle directory creation"

    Write-Host "Uploading service bundle archive..."
    Invoke-External "scp" ($scpCommonArgs + @(
        $bundle.ArchivePath,
        "${remote}:$remoteBundleArchive"
    )) "service bundle upload"

    if ($DetachedRemoteJob) {
        Write-Host "Uploading remote job runner..."
        Invoke-External "scp" ($scpCommonArgs + @(
            $runScriptPath,
            "${remote}:$remoteJobScript"
        )) "remote job runner upload"
    }

    $extractCommand = @(
        "set -e",
        "rm -rf $(Quote-BashArg $remoteBundleDir)",
        "mkdir -p $(Quote-BashArg $remoteBundleDir)",
        "tar -xzf $(Quote-BashArg $remoteBundleArchive) -C $(Quote-BashArg $remoteBundleDir)",
        "test -f $(Quote-BashArg $remoteServiceRunnerTemp)",
        "test -d $(Quote-BashArg $remoteAnsibleTemp)"
    ) -join "; "

    Write-Host "Extracting service bundle on orchestration node..."
    Invoke-ExternalRetryTransport "ssh" ($sshCommonArgs + @(
        $remote,
        $extractCommand
    )) "remote service bundle extract"

    if ($DetachedRemoteJob) {
        $startJobCommand = @(
            "set -e",
            "chmod 700 $(Quote-BashArg $remoteJobScript)",
            "rm -f $(Quote-BashArg $remoteJobLog) $(Quote-BashArg $remoteJobExitCode) $(Quote-BashArg $remoteJobDone) $(Quote-BashArg $remoteJobPid)",
            "nohup bash $(Quote-BashArg $remoteJobScript) </dev/null >/dev/null 2>&1 & echo `$! > $(Quote-BashArg $remoteJobPid)"
        ) -join "; "

        Write-Host "Starting remote service job..."
        Invoke-ExternalRetryTransport "ssh" ($sshCommonArgs + @(
            $remote,
            $startJobCommand
        )) "remote service job start"

        Write-Host "Following remote service job log..."
        Wait-RemoteServiceJob -SshArgs $sshCommonArgs -Remote $remote -RemoteLog $remoteJobLog -RemoteDone $remoteJobDone -RemoteExitCode $remoteJobExitCode -PollSeconds $RemoteJobPollSeconds -ReconnectAttempts $RemoteJobReconnectAttempts -HeartbeatSeconds $RemoteJobHeartbeatSeconds
    } else {
        Write-Host "Installing service bundle and running remote service command..."
        Invoke-External "ssh" ($sshCommonArgs + @(
            $remote,
            $installCommands
        )) "remote service command"
    }
} finally {
    if ($bundle) {
        Remove-Item -LiteralPath $bundle.ArchivePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $bundle.StagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $runScriptPath -Force -ErrorAction SilentlyContinue
    if ($DetachedRemoteJob) {
        Write-Host "Cleaning remote temporary service bundle and job..."
    } else {
        Write-Host "Cleaning remote temporary service bundle..."
    }
    if ($remote -and $remoteBundleDir -and $remoteBundleArchive -and $remoteJobDir -and $sshCommonArgs) {
        Invoke-CleanupSsh ($sshCommonArgs + @(
            $remote,
            "rm -rf $(Quote-BashArg $remoteBundleDir) $(Quote-BashArg $remoteBundleArchive) $(Quote-BashArg $remoteJobDir)"
        )) "remote service bundle and job cleanup"
    }
}
