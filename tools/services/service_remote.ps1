param(
    [Parameter(Position=0)]
    [string]$Service,

    [Parameter(Position=1)]
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

    [string]$PolicyRouterDockerDir = "infra/docker/policy-router",

    [string]$PolicyGatewayDockerDir = "infra/docker/policy-gateway",

    [string]$EgressPolicyToolsDir = "tools/egress_policy",

    [string]$Limit = "",

    [string]$PolicyRouterImageRef = "",

    [switch]$BuildPolicyRouterImage,

    [string]$BatchPlanFile = "",

    [switch]$Check,

    [switch]$ConfirmPurge,

    [switch]$DetachedRemoteJob,

    [switch]$AutoAcceptHostKey = $true,

    [int]$RemoteJobPollSeconds = 2,

    [int]$RemoteJobReconnectAttempts = 30,

    [int]$RemoteJobHeartbeatSeconds = 10,

    [int]$RemoteTransferAttempts = 6,

    [int]$RemoteTransferRetryDelaySeconds = 5
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

function New-TarGzBundle($ServiceRunnerScript, $AnsibleDir, $PolicyRouterDockerDir, $PolicyGatewayDockerDir, $EgressPolicyToolsDir) {
    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        Fail "tar not found in PATH. It is required to upload service bundles as a single archive."
    }

    $stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.service-remote." + [guid]::NewGuid().ToString("N"))
    $archivePath = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.service-remote." + [guid]::NewGuid().ToString("N") + ".tar.gz")
    New-Item -ItemType Directory -Path $stagingDir | Out-Null
    try {
        Copy-Item -LiteralPath $ServiceRunnerScript -Destination (Join-Path $stagingDir "service.sh")
        Copy-Item -LiteralPath $AnsibleDir -Destination (Join-Path $stagingDir "ansible") -Recurse
        $dockerStagingDir = Join-Path (Join-Path $stagingDir "docker") "policy-router"
        New-Item -ItemType Directory -Path (Split-Path -Parent $dockerStagingDir) | Out-Null
        Copy-Item -LiteralPath $PolicyRouterDockerDir -Destination $dockerStagingDir -Recurse
        $gatewayDockerStagingDir = Join-Path (Join-Path $stagingDir "docker") "policy-gateway"
        Copy-Item -LiteralPath $PolicyGatewayDockerDir -Destination $gatewayDockerStagingDir -Recurse
        $toolsStagingDir = Join-Path (Join-Path $stagingDir "tools") "egress_policy"
        New-Item -ItemType Directory -Path (Split-Path -Parent $toolsStagingDir) | Out-Null
        Copy-Item -LiteralPath $EgressPolicyToolsDir -Destination $toolsStagingDir -Recurse
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

function Invoke-ExternalRetrySshTransport($FilePath, $Arguments, $Label, $Attempts, $RetryDelaySeconds) {
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        & $FilePath @Arguments
        if ($LASTEXITCODE -eq 0) {
            return
        }
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 255 -or $attempt -eq $Attempts) {
            Fail "$Label failed with exit code $exitCode"
        }
        Write-Host "$Label hit SSH transport error (exit 255), retrying $attempt/$Attempts..."
        Start-Sleep -Seconds $RetryDelaySeconds
    }
}

function Invoke-CleanupSsh($Arguments, $Label) {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & ssh @Arguments *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "$Label failed with exit code $LASTEXITCODE; continuing because cleanup is best-effort"
        }
    } catch {
        Write-Warning "$Label failed: $($_.Exception.Message); continuing because cleanup is best-effort"
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Invoke-RemoteTempCleanup($SshArgs, $Remote) {
    $cleanupCommand = @(
        "find /tmp -maxdepth 1 -mindepth 1 -type d \( -name 'ai-service-platform.service-job.*' -o -name 'ai-service-platform.service-remote.*' \) -mmin +1440 -exec rm -rf -- {} +",
        "find /tmp -maxdepth 1 -mindepth 1 -type f -name 'ai-service-platform.service-remote.*.tar.gz' -mmin +1440 -delete"
    ) -join "; "
    Invoke-CleanupSsh ($SshArgs + @($Remote, $cleanupCommand)) "remote old service temp cleanup"
}

function Invoke-CaptureExternal($FilePath, $Arguments) {
    function Quote-ProcessArgument($Value) {
        $text = [string]$Value
        if ($text -eq "") {
            return '""'
        }
        if ($text -notmatch '[\s"]') {
            return $text
        }
        return '"' + (($text -replace '\\', '\\') -replace '"', '\"') + '"'
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo.FileName = $FilePath
    $process.StartInfo.Arguments = (@($Arguments) | ForEach-Object { Quote-ProcessArgument $_ }) -join " "
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $output = @()
        if ($stdout) { $output += @($stdout -split "`r?`n" | Where-Object { $_ -ne "" }) }
        if ($stderr) { $output += @($stderr -split "`r?`n" | Where-Object { $_ -ne "" }) }
        return @{ ExitCode = $process.ExitCode; Output = @($output) }
    } catch {
        return @{ ExitCode = 255; Output = @([string]$_) }
    } finally {
        $process.Dispose()
    }
}

function Write-LfScript($Path, $Lines) {
    $content = (@($Lines) -join "`n") + "`n"
    [System.IO.File]::WriteAllText($Path, $content, [System.Text.Encoding]::ASCII)
}

function Format-Elapsed($StartedAt) {
    $elapsed = [DateTime]::UtcNow - $StartedAt
    return "{0:00}:{1:00}:{2:00}" -f [int]$elapsed.TotalHours, $elapsed.Minutes, $elapsed.Seconds
}

function ConvertTo-StepArray($Value) {
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return @($Value) }
    return @($Value)
}

function Read-BatchPlan($Path) {
    try {
        $data = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    } catch {
        Fail "BatchPlanFile is not valid JSON: $Path"
    }

    $steps = @(ConvertTo-StepArray $data)
    if ($steps.Count -eq 0) {
        Fail "BatchPlanFile must contain at least one step"
    }

    $validated = New-Object System.Collections.ArrayList
    $index = 0
    foreach ($step in $steps) {
        $index++
        if (-not $step.service -or -not $step.action) {
            Fail "BatchPlanFile step $index must include service and action"
        }
        if ($step.service -notin @("edge_haproxy", "vpn_edge", "vpn_cascade", "policy_gateway", "edge_candidate_collector")) {
            Fail "BatchPlanFile step $index has unsupported service: $($step.service)"
        }
        if ($step.action -notin @("plan", "apply", "absent", "purge", "reseed")) {
            Fail "BatchPlanFile step $index has unsupported action: $($step.action)"
        }
        $label = [string]$step.label
        if (-not $label) {
            $label = "$($step.service) $($step.action)"
            if ($step.limit) { $label += " for $($step.limit)" }
        }
        $validated.Add([pscustomobject]@{
            Service = [string]$step.service
            Action = [string]$step.action
            Limit = [string]$step.limit
            Check = [bool]$step.check
            ConfirmPurge = [bool]$step.confirm_purge
            Label = $label
        }) | Out-Null
    }
    return @($validated.ToArray())
}

function New-ServiceCommand($Step, $RemoteRepoDir, $RemoteNodesFile, $RemoteStateFile, $RemoteInventory) {
    $args = @(
        (Quote-BashArg $Step.Service),
        (Quote-BashArg $Step.Action),
        "--nodes-file", (Quote-BashArg $RemoteNodesFile),
        "--state-file", (Quote-BashArg $RemoteStateFile),
        "--inventory", (Quote-BashArg $RemoteInventory)
    )
    if ($Step.Limit) { $args += @("--limit", (Quote-BashArg $Step.Limit)) }
    if ($Step.PolicyRouterImageRef) { $args += @("--policy-router-image-ref", (Quote-BashArg $Step.PolicyRouterImageRef)) }
    if ($Step.BuildPolicyRouterImage) { $args += "--build-policy-router-image" }
    if ($Step.Check) { $args += "--check" }
    if ($Step.ConfirmPurge) { $args += "--confirm-purge" }

    return @(
        "set -e",
        "cd $(Quote-BashArg $RemoteRepoDir)",
        "if command -v stdbuf >/dev/null 2>&1; then stdbuf -oL -eL bash tools/services/service.sh $($args -join ' '); else bash tools/services/service.sh $($args -join ' '); fi"
    ) -join "; "
}

function Wait-RemoteServiceJob([string[]]$SshArgs, [string]$Remote, [string]$RemoteLog, [string]$RemoteDone, [string]$RemoteExitCode, [string]$RemotePid, [int]$PollSeconds, [int]$ReconnectAttempts, [int]$HeartbeatSeconds) {
    $printedLines = 0
    $transportFailures = 0
    $startedAt = [DateTime]::UtcNow
    $lastHeartbeatAt = $startedAt
    $currentStep = "remote job"
    $lastTask = ""

    while ($true) {
        $pollCommand = @(
            "if [ -f $(Quote-BashArg $RemoteLog) ]; then tail -n +$($printedLines + 1) $(Quote-BashArg $RemoteLog); fi",
            "if [ -f $(Quote-BashArg $RemoteDone) ]; then echo __SERVICE_JOB_DONE__; cat $(Quote-BashArg $RemoteExitCode); elif [ -f $(Quote-BashArg $RemotePid) ] && ! kill -0 ""`$(cat $(Quote-BashArg $RemotePid))"" 2>/dev/null; then echo __SERVICE_JOB_DEAD__; fi"
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
                        if ($line -match "^\[batch\] Step \d+/\d+: (.+)$") {
                            $currentStep = $Matches[1]
                        } elseif ($line -match "^TASK \[(.+)\]") {
                            $lastTask = $Matches[1]
                        }
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

        $deadIndex = [Array]::IndexOf($result.Output, "__SERVICE_JOB_DEAD__")
        if ($deadIndex -ge 0) {
            if ($deadIndex -gt 0) {
                foreach ($line in @($result.Output[0..($deadIndex - 1)])) {
                    if ($line -ne "__SERVICE_JOB_DEAD__") {
                        Write-Host $line
                        $printedLines++
                    }
                }
            }
            Fail "remote service job process exited without writing done/exit_code; log: $RemoteLog"
        }

        $printedThisPoll = 0
        foreach ($line in $result.Output) {
            if ($line) {
                Write-Host $line
                if ($line -match "^\[batch\] Step \d+/\d+: (.+)$") {
                    $currentStep = $Matches[1]
                } elseif ($line -match "^TASK \[(.+)\]") {
                    $lastTask = $Matches[1]
                } elseif ($line -match "^\[remote-job\].*running service command: (.+)$") {
                    $currentStep = $Matches[1]
                }
                $printedThisPoll++
            } else {
                Write-Host ""
            }
            $printedLines++
        }

        $now = [DateTime]::UtcNow
        if ($printedThisPoll -eq 0 -and $HeartbeatSeconds -gt 0 -and (($now - $lastHeartbeatAt).TotalSeconds -ge $HeartbeatSeconds)) {
            $taskText = if ($lastTask) { "; last task: $lastTask" } else { "" }
            Write-Host ("[WAIT] {0} is still running{1}; remote log: {2}" -f $currentStep, $taskText, $RemoteLog)
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
if ($PolicyRouterImageRef -and $Service -ne "vpn_cascade") {
    Fail "-PolicyRouterImageRef is supported only for service vpn_cascade"
}
if ($BuildPolicyRouterImage -and $Service -ne "vpn_cascade") {
    Fail "-BuildPolicyRouterImage is supported only for service vpn_cascade"
}
if ($BuildPolicyRouterImage -and $PolicyRouterImageRef) {
    Fail "-BuildPolicyRouterImage and -PolicyRouterImageRef are mutually exclusive"
}
if ($PolicyRouterImageRef -and $BatchPlanFile) {
    Fail "-PolicyRouterImageRef is supported only for a single vpn_cascade command, not BatchPlanFile"
}
if ($BuildPolicyRouterImage -and $BatchPlanFile) {
    Fail "-BuildPolicyRouterImage is supported only for a single vpn_cascade command, not BatchPlanFile"
}

if ($BatchPlanFile) {
    Require-File $BatchPlanFile "BatchPlanFile"
} elseif (-not $Service -or -not $Action) {
    Fail "Service and Action are required unless -BatchPlanFile is provided."
}
if ($RemoteTransferAttempts -lt 1) {
    Fail "RemoteTransferAttempts must be greater than zero"
}
if ($RemoteTransferRetryDelaySeconds -lt 1) {
    Fail "RemoteTransferRetryDelaySeconds must be greater than zero"
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
if (-not (Test-Path -LiteralPath $PolicyRouterDockerDir -PathType Container)) {
    Fail "PolicyRouterDockerDir not found: $PolicyRouterDockerDir"
}
if (-not (Test-Path -LiteralPath $PolicyGatewayDockerDir -PathType Container)) {
    Fail "PolicyGatewayDockerDir not found: $PolicyGatewayDockerDir"
}
if (-not (Test-Path -LiteralPath $EgressPolicyToolsDir -PathType Container)) {
    Fail "EgressPolicyToolsDir not found: $EgressPolicyToolsDir"
}

$remote = "$SshUser@$($controlNode.endpoint)"
$remoteBundleDir = "/tmp/ai-service-platform.service-remote.$([guid]::NewGuid().ToString('N'))"
$remoteBundleArchive = "$remoteBundleDir.tar.gz"
$remoteServiceRunnerTemp = "$remoteBundleDir/service.sh"
$remoteAnsibleTemp = "$remoteBundleDir/ansible"
$remotePolicyRouterDockerTemp = "$remoteBundleDir/docker/policy-router"
$remotePolicyGatewayDockerTemp = "$remoteBundleDir/docker/policy-gateway"
$remoteEgressPolicyToolsTemp = "$remoteBundleDir/tools/egress_policy"
$remoteJobDir = "/tmp/ai-service-platform.service-job.$([guid]::NewGuid().ToString('N'))"
$remoteJobScript = "$remoteJobDir/run.sh"
$remoteJobLog = "$remoteJobDir/output.log"
$remoteJobPid = "$remoteJobDir/pid"
$remoteJobExitCode = "$remoteJobDir/exit_code"
$remoteJobDone = "$remoteJobDir/done"
$isBatch = [bool]$BatchPlanFile
$batchSteps = @()
if ($isBatch) {
    $batchSteps = @(Read-BatchPlan $BatchPlanFile)
} else {
    $singleStep = [pscustomobject]@{
        Service = $Service
        Action = $Action
        Limit = $Limit
        Check = [bool]$Check
        ConfirmPurge = [bool]$ConfirmPurge
        PolicyRouterImageRef = $PolicyRouterImageRef
        BuildPolicyRouterImage = [bool]$BuildPolicyRouterImage
        Label = if ($Limit) { "$Service $Action for $Limit" } else { "$Service $Action" }
    }
    $serviceCommand = New-ServiceCommand $singleStep $RemoteRepoDir $RemoteNodesFile $RemoteStateFile $RemoteInventory
}
$useDetachedRemoteJob = ([bool]$DetachedRemoteJob) -or $isBatch
$installCommands = ""
if (-not $isBatch) {
    $installCommands = @(
        "set -e",
        "sudo mkdir -p $(Quote-BashArg "$RemoteRepoDir/tools/services") $(Quote-BashArg "$RemoteRepoDir/tools") $(Quote-BashArg "$RemoteRepoDir/infra") $(Quote-BashArg "$RemoteRepoDir/infra/docker")",
        "sudo install -m 700 $(Quote-BashArg $remoteServiceRunnerTemp) $(Quote-BashArg "$RemoteRepoDir/tools/services/service.sh")",
        "sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/tools/egress_policy")",
        "sudo cp -a $(Quote-BashArg $remoteEgressPolicyToolsTemp) $(Quote-BashArg "$RemoteRepoDir/tools/egress_policy")",
        "sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/infra/ansible")",
        "sudo cp -a $(Quote-BashArg $remoteAnsibleTemp) $(Quote-BashArg "$RemoteRepoDir/infra/ansible")",
        "sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/infra/docker/policy-router")",
        "sudo cp -a $(Quote-BashArg $remotePolicyRouterDockerTemp) $(Quote-BashArg "$RemoteRepoDir/infra/docker/policy-router")",
        "sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/infra/docker/policy-gateway")",
        "sudo cp -a $(Quote-BashArg $remotePolicyGatewayDockerTemp) $(Quote-BashArg "$RemoteRepoDir/infra/docker/policy-gateway")",
        "sudo bash -lc $(Quote-BashArg $serviceCommand)"
    ) -join "; "
}

Write-Host "Control node: $($controlNode.current_alias) via role '$ControlRole'"
Write-Host "Remote:       $remote"
if ($isBatch) {
    Write-Host "Batch:        $BatchPlanFile"
    Write-Host "Steps:        $($batchSteps.Count)"
} else {
    Write-Host "Service:      $Service"
    Write-Host "Action:       $Action"
    if ($Limit) {
        Write-Host "Limit:        $Limit"
    }
    if ($Check) {
        Write-Host "Check:        true"
    }
    if ($PolicyRouterImageRef) {
        Write-Host "Policy image: $PolicyRouterImageRef"
    }
    if ($BuildPolicyRouterImage) {
        Write-Host "Build policy image: true"
    }
}
if ($useDetachedRemoteJob) {
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
    "-o", "KbdInteractiveAuthentication=no",
    "-o", "PasswordAuthentication=no",
    "-o", "PreferredAuthentications=publickey",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=2"
)
if ($AutoAcceptHostKey) {
    $sshCommonArgs += @("-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR")
}
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
if ($AutoAcceptHostKey) {
    $scpCommonArgs += @("-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR")
}
$runScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.service-job." + [guid]::NewGuid().ToString("N") + ".sh")
$remoteJobCompletedSuccessfully = $false
$remoteServiceDisplay = if ($isBatch) { "batch plan: $($batchSteps.Count) steps" } else {
    $remoteServiceDisplayArgs = @($Service, $Action)
    if ($Limit) { $remoteServiceDisplayArgs += @("--limit", $Limit) }
    if ($PolicyRouterImageRef) { $remoteServiceDisplayArgs += @("--policy-router-image-ref", $PolicyRouterImageRef) }
    if ($BuildPolicyRouterImage) { $remoteServiceDisplayArgs += "--build-policy-router-image" }
    if ($Check) { $remoteServiceDisplayArgs += "--check" }
    if ($ConfirmPurge) { $remoteServiceDisplayArgs += "--confirm-purge" }
    $remoteServiceDisplayArgs -join " "
}
$runScriptLines = New-Object System.Collections.Generic.List[string]
foreach ($line in @(
    "#!/usr/bin/env bash",
    "set +e",
    "export PYTHONUNBUFFERED=1",
    "export ANSIBLE_FORCE_COLOR=0",
    "export ANSIBLE_DISPLAY_SKIPPED_HOSTS=true",
    "exec > $(Quote-BashArg $remoteJobLog) 2>&1",
    "SUMMARY_FILE=$(Quote-BashArg "$remoteJobDir/summary.jsonl")",
    "printf '' > ""`$SUMMARY_FILE""",
    "log_stage() { printf '[remote-job] %s %s\n' ""`$(date -u '+%H:%M:%S')"" ""`$*""; }",
    "run_stage() { label=""`$1""; shift; log_stage ""`$label""; ""`$@""; rc=""`$?""; if [ ""`$rc"" -ne 0 ]; then log_stage ""failed: `$label (rc=`$rc)""; return ""`$rc""; fi; }",
    "run_stage $(Quote-BashArg "prepare repo directories") sudo mkdir -p $(Quote-BashArg "$RemoteRepoDir/tools/services") $(Quote-BashArg "$RemoteRepoDir/tools") $(Quote-BashArg "$RemoteRepoDir/infra") $(Quote-BashArg "$RemoteRepoDir/infra/docker")",
    "run_stage $(Quote-BashArg "install service runner") sudo install -m 700 $(Quote-BashArg $remoteServiceRunnerTemp) $(Quote-BashArg "$RemoteRepoDir/tools/services/service.sh")",
    "run_stage $(Quote-BashArg "remove previous egress policy tools") sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/tools/egress_policy")",
    "run_stage $(Quote-BashArg "install egress policy tools") sudo cp -a $(Quote-BashArg $remoteEgressPolicyToolsTemp) $(Quote-BashArg "$RemoteRepoDir/tools/egress_policy")",
    "run_stage $(Quote-BashArg "remove previous Ansible bundle") sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/infra/ansible")",
    "run_stage $(Quote-BashArg "install Ansible bundle") sudo cp -a $(Quote-BashArg $remoteAnsibleTemp) $(Quote-BashArg "$RemoteRepoDir/infra/ansible")",
    "run_stage $(Quote-BashArg "remove previous policy-router Docker context") sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/infra/docker/policy-router")",
    "run_stage $(Quote-BashArg "install policy-router Docker context") sudo cp -a $(Quote-BashArg $remotePolicyRouterDockerTemp) $(Quote-BashArg "$RemoteRepoDir/infra/docker/policy-router")",
    "run_stage $(Quote-BashArg "remove previous policy-gateway Docker context") sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/infra/docker/policy-gateway")",
    "run_stage $(Quote-BashArg "install policy-gateway Docker context") sudo cp -a $(Quote-BashArg $remotePolicyGatewayDockerTemp) $(Quote-BashArg "$RemoteRepoDir/infra/docker/policy-gateway")"
)) { $runScriptLines.Add($line) | Out-Null }

if ($isBatch) {
    $stepCount = $batchSteps.Count
    $stepNumber = 0
    foreach ($step in $batchSteps) {
        $stepNumber++
        $stepCommand = New-ServiceCommand $step $RemoteRepoDir $RemoteNodesFile $RemoteStateFile $RemoteInventory
        $stepLabel = "Step ${stepNumber}/${stepCount}: $($step.Label)"
        foreach ($line in @(
            "STEP_LABEL=$(Quote-BashArg $stepLabel)",
            "STEP_SERVICE=$(Quote-BashArg $step.Service)",
            "STEP_ACTION=$(Quote-BashArg $step.Action)",
            "STEP_LIMIT=$(Quote-BashArg $step.Limit)",
            "STEP_STARTED=`$(date +%s)",
            "printf '[batch] %s\n' ""`$STEP_LABEL""",
            "sudo bash -lc $(Quote-BashArg $stepCommand)",
            "rc=`$?",
            "STEP_FINISHED=`$(date +%s)",
            "STEP_DURATION=`$((STEP_FINISHED - STEP_STARTED))",
            "if [ ""`$rc"" -eq 0 ]; then printf '[OK] %s completed in %ss\n' ""`$STEP_LABEL"" ""`$STEP_DURATION""; else printf '[FAIL] %s failed with rc=%s after %ss\n' ""`$STEP_LABEL"" ""`$rc"" ""`$STEP_DURATION""; fi",
            "printf '%s|%s|%s|%s|%s|%s\n' ""`$STEP_LABEL"" ""`$STEP_SERVICE"" ""`$STEP_ACTION"" ""`$STEP_LIMIT"" ""`$rc"" ""`$STEP_DURATION"" >> ""`$SUMMARY_FILE""",
            "if [ ""`$rc"" -ne 0 ]; then printf '%s\n' ""`$rc"" > $(Quote-BashArg $remoteJobExitCode); touch $(Quote-BashArg $remoteJobDone); exit ""`$rc""; fi"
        )) { $runScriptLines.Add($line) | Out-Null }
    }
    foreach ($line in @(
        "printf '\n[batch] Summary\n'",
        "cat ""`$SUMMARY_FILE""",
        "rc=0",
        "printf '%s\n' `$rc > $(Quote-BashArg $remoteJobExitCode)",
        "touch $(Quote-BashArg $remoteJobDone)",
        "exit `$rc"
    )) { $runScriptLines.Add($line) | Out-Null }
} else {
    foreach ($line in @(
        "log_stage $(Quote-BashArg "running service command: $remoteServiceDisplay")",
        "sudo bash -lc $(Quote-BashArg $serviceCommand)",
        "rc=`$?",
        "log_stage ""service command finished with rc=`$rc""",
        "printf '%s\n' `$rc > $(Quote-BashArg $remoteJobExitCode)",
        "touch $(Quote-BashArg $remoteJobDone)",
        "exit `$rc"
    )) { $runScriptLines.Add($line) | Out-Null }
}

try {
    Write-Host "Preparing local service bundle..."
    $bundle = New-TarGzBundle $ServiceRunnerScript $AnsibleDir $PolicyRouterDockerDir $PolicyGatewayDockerDir $EgressPolicyToolsDir
    if ($useDetachedRemoteJob) {
        Write-LfScript $runScriptPath $runScriptLines
    }

    Invoke-RemoteTempCleanup $sshCommonArgs $remote

    if ($useDetachedRemoteJob) {
        Write-Host "Creating remote temporary bundle and job directories..."
        $mkdirCommand = "mkdir -p $(Quote-BashArg $remoteBundleDir) $(Quote-BashArg $remoteJobDir)"
    } else {
        Write-Host "Creating remote temporary bundle directory..."
        $mkdirCommand = "mkdir -p $(Quote-BashArg $remoteBundleDir)"
    }
    Invoke-ExternalRetryTransport "ssh" ($sshCommonArgs + @(
        $remote,
        $mkdirCommand
    )) "remote service bundle directory creation" $RemoteTransferAttempts

    Write-Host "Uploading service bundle archive..."
    Invoke-ExternalRetrySshTransport "scp" ($scpCommonArgs + @(
        $bundle.ArchivePath,
        "${remote}:$remoteBundleArchive"
    )) "service bundle upload" $RemoteTransferAttempts $RemoteTransferRetryDelaySeconds

    if ($useDetachedRemoteJob) {
        Write-Host "Uploading remote job runner..."
        Invoke-ExternalRetrySshTransport "scp" ($scpCommonArgs + @(
            $runScriptPath,
            "${remote}:$remoteJobScript"
        )) "remote job runner upload" $RemoteTransferAttempts $RemoteTransferRetryDelaySeconds
    }

    $extractCommand = @(
        "set -e",
        "rm -rf $(Quote-BashArg $remoteBundleDir)",
        "mkdir -p $(Quote-BashArg $remoteBundleDir)",
        "tar -xzf $(Quote-BashArg $remoteBundleArchive) -C $(Quote-BashArg $remoteBundleDir)",
        "test -f $(Quote-BashArg $remoteServiceRunnerTemp)",
        "test -d $(Quote-BashArg $remoteEgressPolicyToolsTemp)",
        "test -d $(Quote-BashArg $remoteAnsibleTemp)",
        "test -d $(Quote-BashArg $remotePolicyRouterDockerTemp)",
        "test -d $(Quote-BashArg $remotePolicyGatewayDockerTemp)"
    ) -join "; "

    Write-Host "Extracting service bundle on orchestration node..."
    Invoke-ExternalRetryTransport "ssh" ($sshCommonArgs + @(
        $remote,
        $extractCommand
    )) "remote service bundle extract" $RemoteTransferAttempts

    if ($useDetachedRemoteJob) {
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
        )) "remote service job start" $RemoteTransferAttempts

        Write-Host "Following remote service job log..."
        Wait-RemoteServiceJob -SshArgs ([string[]]$sshCommonArgs) -Remote $remote -RemoteLog $remoteJobLog -RemoteDone $remoteJobDone -RemoteExitCode $remoteJobExitCode -RemotePid $remoteJobPid -PollSeconds $RemoteJobPollSeconds -ReconnectAttempts $RemoteJobReconnectAttempts -HeartbeatSeconds $RemoteJobHeartbeatSeconds
        $remoteJobCompletedSuccessfully = $true
    } else {
        Write-Host "Installing service bundle and running remote service command..."
        Invoke-ExternalRetrySshTransport "ssh" ($sshCommonArgs + @(
            $remote,
            $installCommands
        )) "remote service command" $RemoteTransferAttempts $RemoteTransferRetryDelaySeconds
    }
} finally {
    if ($bundle) {
        Remove-Item -LiteralPath $bundle.ArchivePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $bundle.StagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $runScriptPath -Force -ErrorAction SilentlyContinue
    if ($useDetachedRemoteJob -and $remoteJobCompletedSuccessfully) {
        Write-Host "Cleaning remote temporary service bundle and job..."
        $cleanupTarget = "rm -rf $(Quote-BashArg $remoteBundleDir) $(Quote-BashArg $remoteBundleArchive) $(Quote-BashArg $remoteJobDir)"
    } elseif ($useDetachedRemoteJob) {
        Write-Host "Cleaning remote temporary service bundle; preserving failed job log: $remoteJobLog"
        $cleanupTarget = "rm -rf $(Quote-BashArg $remoteBundleDir) $(Quote-BashArg $remoteBundleArchive)"
    } else {
        Write-Host "Cleaning remote temporary service bundle..."
        $cleanupTarget = "rm -rf $(Quote-BashArg $remoteBundleDir) $(Quote-BashArg $remoteBundleArchive) $(Quote-BashArg $remoteJobDir)"
    }
    if ($remote -and $remoteBundleDir -and $remoteBundleArchive -and $remoteJobDir -and $sshCommonArgs) {
        Invoke-CleanupSsh ($sshCommonArgs + @(
            $remote,
            $cleanupTarget
        )) "remote service bundle and job cleanup"
    }
}
