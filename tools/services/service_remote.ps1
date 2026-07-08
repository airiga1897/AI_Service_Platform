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

    [string]$KnownHostsFile = "",

    [string]$SshUser = "useradmin",

    [string]$SshKeyFile = "",

    [string]$RemoteRepoDir = "/opt/ai-service-platform",

    [string]$RemoteNodesFile = "/opt/ai-service-platform/operator/nodes.csv",

    [string]$RemoteStateFile = "/opt/ai-service-platform/operator/state.csv",

    [string]$RemoteInventory = "/opt/ai-service-platform/inventory.ini",

    [string]$ServiceRunnerScript = "tools/services/service.sh",

    [string]$CreateInventoryScript = "tools/bootstrap/create_inventory.sh",

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

    [switch]$ReinitStandby,

    [switch]$DetachedRemoteJob,

    [switch]$AutoAcceptHostKey = $true,

    [int]$RemoteJobPollSeconds = 2,

    [int]$RemoteJobReconnectAttempts = 30,

    [int]$RemoteJobMaxWaitSeconds = 0,

    [int]$RemoteJobStatusOutageMaxSeconds = 900,

    [int]$RemoteJobHeartbeatSeconds = 10,

    [int]$RemoteTransferAttempts = 6,

    [int]$RemoteTransferRetryDelaySeconds = 5,

    [int]$CleanupAttempts = 3,

    [int]$CleanupRetryDelaySeconds = 2
)

$ErrorActionPreference = "Stop"
$ExpectedHeader = "current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$ExpectedNetworksHeader = "alias,policy_subnet,edge_ip,cascade_ip,cascade_router_ip,policy_gateway_ip"
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

function Quote-BashArg($Value) {
    $text = [string]$Value
    return "'" + ($text -replace "'", "'\''") + "'"
}

function Split-RemoteParentPath($Path) {
    $text = ([string]$Path).TrimEnd("/")
    $index = $text.LastIndexOf("/")
    if ($index -le 0) {
        return "."
    }
    return $text.Substring(0, $index)
}

function New-TarGzBundle($ServiceRunnerScript, $CreateInventoryScript, $AnsibleDir, $PolicyRouterDockerDir, $PolicyGatewayDockerDir, $EgressPolicyToolsDir, $NodesFile, $StateFile, $NetworksFile) {
    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        Fail "tar not found in PATH. It is required to upload service bundles as a single archive."
    }

    $stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.service-remote." + [guid]::NewGuid().ToString("N"))
    $archivePath = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.service-remote." + [guid]::NewGuid().ToString("N") + ".tar.gz")
    New-Item -ItemType Directory -Path $stagingDir | Out-Null
    try {
        Copy-Item -LiteralPath $ServiceRunnerScript -Destination (Join-Path $stagingDir "service.sh")
        $bootstrapStagingDir = Join-Path (Join-Path $stagingDir "tools") "bootstrap"
        New-Item -ItemType Directory -Path $bootstrapStagingDir -Force | Out-Null
        Copy-Item -LiteralPath $CreateInventoryScript -Destination (Join-Path $bootstrapStagingDir "create_inventory.sh")
        Copy-Item -LiteralPath $AnsibleDir -Destination (Join-Path $stagingDir "ansible") -Recurse
        $dockerStagingDir = Join-Path (Join-Path $stagingDir "docker") "policy-router"
        New-Item -ItemType Directory -Path (Split-Path -Parent $dockerStagingDir) -Force | Out-Null
        Copy-Item -LiteralPath $PolicyRouterDockerDir -Destination $dockerStagingDir -Recurse
        $gatewayDockerStagingDir = Join-Path (Join-Path $stagingDir "docker") "policy-gateway"
        Copy-Item -LiteralPath $PolicyGatewayDockerDir -Destination $gatewayDockerStagingDir -Recurse
        $toolsStagingDir = Join-Path (Join-Path $stagingDir "tools") "egress_policy"
        New-Item -ItemType Directory -Path (Split-Path -Parent $toolsStagingDir) -Force | Out-Null
        Copy-Item -LiteralPath $EgressPolicyToolsDir -Destination $toolsStagingDir -Recurse
        $operatorStagingDir = Join-Path $stagingDir "operator"
        New-Item -ItemType Directory -Path $operatorStagingDir | Out-Null
        Copy-Item -LiteralPath $NodesFile -Destination (Join-Path $operatorStagingDir "nodes.csv")
        Copy-Item -LiteralPath $StateFile -Destination (Join-Path $operatorStagingDir "state.csv")
        Copy-Item -LiteralPath $NetworksFile -Destination (Join-Path $operatorStagingDir "networks.csv")
        $operatorSourceDir = Split-Path -Parent (Resolve-Path -LiteralPath $NodesFile).Path
        foreach ($operatorSubdir in @("haproxy", "softether", "edge_banlist", "postgres", "platform_networks", "platform_router")) {
            $sourceSubdir = Join-Path $operatorSourceDir $operatorSubdir
            if (Test-Path -LiteralPath $sourceSubdir -PathType Container) {
                Copy-Item -LiteralPath $sourceSubdir -Destination (Join-Path $operatorStagingDir $operatorSubdir) -Recurse
            }
        }
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
        for ($attempt = 1; $attempt -le $CleanupAttempts; $attempt++) {
            & $script:SshExecutablePath @Arguments *> $null
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) {
                return
            }
            if ($exitCode -ne 255) {
                Write-Warning "$Label failed with exit code $exitCode; cleanup is non-fatal"
                return
            }
            if ($attempt -lt $CleanupAttempts) {
                Start-Sleep -Seconds $CleanupRetryDelaySeconds
                continue
            }
            Write-Warning "cleanup SSH transport failed; skipped $Label; non-fatal"
        }
    } catch {
        Write-Warning "$Label failed: $($_.Exception.Message); cleanup is non-fatal"
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function New-BackgroundCleanupCommand($Command) {
    return "nohup sh -c $(Quote-BashArg $Command) >/dev/null 2>&1 &"
}

function Invoke-RemoteTempCleanup($SshArgs, $Remote) {
    $cleanupCommand = @(
        "find /tmp -maxdepth 1 -mindepth 1 -type d -name 'ai-service-platform.service-remote.*' -mmin +1440 -exec rm -rf -- {} +",
        "find /tmp -maxdepth 1 -mindepth 1 -type f -name 'ai-service-platform.service-remote.*.tar.gz' -mmin +1440 -delete"
    ) -join "; "
    Invoke-CleanupSsh ($SshArgs + @($Remote, (New-BackgroundCleanupCommand $cleanupCommand))) "remote old service temp cleanup"
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

function Format-ExternalFailureReason($Result) {
    $lines = @($Result.Output | Where-Object { $_ })
    if ($lines.Count -eq 0) {
        return "no stderr/stdout from ssh"
    }
    $reason = ($lines | Select-Object -First 3) -join " | "
    if ($reason.Length -gt 300) {
        return $reason.Substring(0, 300) + "..."
    }
    return $reason
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
    if ($LASTEXITCODE -ne 0 -and -not $version) {
        Fail "Failed to run ssh -V at $sshPath"
    }
    if ($version -notmatch "OpenSSH") {
        Fail "Resolved ssh is not OpenSSH: $sshPath. Output:`n$version"
    }
    return $sshPath
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
        if ($step.service -notin @("edge_haproxy", "vpn_edge", "vpn_cascade", "policy_gateway", "edge_candidate_collector", "edge_banlist", "postgres_runtime", "softether_l3_vps", "platform_networks", "platform_router")) {
            Fail "BatchPlanFile step $index has unsupported service: $($step.service)"
        }
        if ($step.action -notin @("plan", "apply", "absent", "purge", "reseed")) {
            Fail "BatchPlanFile step $index has unsupported action: $($step.action)"
        }
        if ([bool]$step.reinit_standby) {
            if ($step.service -ne "postgres_runtime") {
                Fail "BatchPlanFile step $index uses reinit_standby outside postgres_runtime"
            }
            if ($step.action -ne "apply") {
                Fail "BatchPlanFile step $index uses reinit_standby without action=apply"
            }
            if (-not $step.limit) {
                Fail "BatchPlanFile step $index uses reinit_standby without limit"
            }
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
            ReinitStandby = [bool]$step.reinit_standby
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
    if ($Step.ReinitStandby) { $args += "--reinit-standby" }

    return @(
        "set -e",
        "cd $(Quote-BashArg $RemoteRepoDir)",
        "if command -v stdbuf >/dev/null 2>&1; then stdbuf -oL -eL bash tools/services/service.sh $($args -join ' '); else bash tools/services/service.sh $($args -join ' '); fi"
    ) -join "; "
}

function New-RefreshAnsibleKnownHostsCommand($RemoteNodesFile, $ControlAlias) {
    $script = @"
set -e
nodes_file=$(Quote-BashArg $RemoteNodesFile)
control_alias=$(Quote-BashArg $ControlAlias)
ssh_dir=/home/ansible/.ssh
known_hosts="`$ssh_dir/known_hosts"
command -v ssh-keygen >/dev/null 2>&1
command -v ssh-keyscan >/dev/null 2>&1
id ansible >/dev/null 2>&1
install -d -m 700 -o ansible -g ansible "`$ssh_dir"
touch "`$known_hosts"
chown ansible:ansible "`$known_hosts"
chmod 600 "`$known_hosts"
tail -n +2 "`$nodes_file" | while IFS=, read -r current_alias endpoint expected_ip connection ssh_port _root_password extra || [ -n "`${current_alias:-}" ]; do
    current_alias="`${current_alias%`$'\r'}"
    endpoint="`${endpoint%`$'\r'}"
    connection="`${connection%`$'\r'}"
    ssh_port="`${ssh_port%`$'\r'}"
    extra="`${extra%`$'\r'}"
    [ -n "`$current_alias" ] || continue
    [ "`$current_alias" != "`$control_alias" ] || continue
    [ -z "`$extra" ] || { echo "[ERROR] nodes.csv row for `$current_alias has too many columns" >&2; exit 1; }
    [ "`$connection" = "ssh" ] || continue
    [ "`$endpoint" != "local" ] || continue
    [ -n "`$ssh_port" ] || ssh_port=22
    known_host="`$endpoint"
    if [ "`$ssh_port" != "22" ]; then known_host="[`$endpoint]:`$ssh_port"; fi
    echo "Refreshing ansible known_hosts for `$current_alias: `$endpoint:`$ssh_port"
    sudo -u ansible ssh-keygen -R "`$known_host" -f "`$known_hosts" >/dev/null 2>&1 || true
    ssh-keyscan -T 10 -p "`$ssh_port" -H "`$endpoint" >> "`$known_hosts" 2>/dev/null || { echo "[ERROR] ssh-keyscan failed for `$current_alias endpoint: `$endpoint" >&2; exit 1; }
done
sort -u "`$known_hosts" -o "`$known_hosts"
chown ansible:ansible "`$known_hosts"
chmod 600 "`$known_hosts"
echo "[OK] ansible known_hosts refreshed"
"@
    return "sudo bash -lc $(Quote-BashArg $script)"
}

function Wait-RemoteServiceJob([string[]]$SshArgs, [string]$Remote, [string]$RemoteLog, [string]$RemoteDone, [string]$RemoteExitCode, [string]$RemotePid, [int]$PollSeconds, [int]$ReconnectAttempts, [int]$MaxWaitSeconds, [int]$StatusOutageMaxSeconds, [int]$HeartbeatSeconds) {
    $printedLines = 0
    $transportFailures = 0
    $startedAt = [DateTime]::UtcNow
    $lastHeartbeatAt = $startedAt
    $lastStatusAvailableAt = $startedAt
    $lastOutageWarningAt = [DateTime]::MinValue
    $currentStep = "remote job"
    $lastTask = ""
    $statusOnlyPolling = $false
    $logPollingReconnectAttempts = [Math]::Min(3, [Math]::Max(1, $ReconnectAttempts))

    while ($true) {
        $statusCommand = "if [ -f $(Quote-BashArg $RemoteDone) ]; then echo __SERVICE_JOB_DONE__; cat $(Quote-BashArg $RemoteExitCode); elif [ -f $(Quote-BashArg $RemotePid) ] && ! kill -0 ""`$(cat $(Quote-BashArg $RemotePid))"" 2>/dev/null; then echo __SERVICE_JOB_DEAD__; fi"
        if ($statusOnlyPolling) {
            $pollCommand = $statusCommand
        } else {
            $pollCommand = @(
                "if [ -f $(Quote-BashArg $RemoteLog) ]; then tail -n +$($printedLines + 1) $(Quote-BashArg $RemoteLog); fi",
                $statusCommand
            ) -join "; "
        }
        $result = Invoke-CaptureExternal $script:SshExecutablePath ($SshArgs + @($Remote, $pollCommand))

        if ($result.ExitCode -eq 255) {
            $transportFailures++
            $failureReason = Format-ExternalFailureReason $result
            $manualCheckCommand = "ssh <control-node> 'cat $(Quote-BashArg $RemoteDone) $(Quote-BashArg $RemoteExitCode) 2>/dev/null; tail -80 $(Quote-BashArg $RemoteLog)'"
            if ((-not $statusOnlyPolling) -and ($transportFailures -ge $logPollingReconnectAttempts)) {
                Write-Warning "remote log poll SSH failed after $transportFailures attempts: $failureReason; switching to status-only polling"
                $statusOnlyPolling = $true
                $transportFailures = 0
                Start-Sleep -Seconds $PollSeconds
                continue
            }
            $now = [DateTime]::UtcNow
            $outageSeconds = [int](($now - $lastStatusAvailableAt).TotalSeconds)
            if ($StatusOutageMaxSeconds -gt 0 -and $outageSeconds -ge $StatusOutageMaxSeconds) {
                Fail "remote status poll SSH failed for ${outageSeconds}s; job result is still unknown. Last SSH error: $failureReason. Check manually: $manualCheckCommand"
            }
            if ($HeartbeatSeconds -gt 0 -and ($lastOutageWarningAt -eq [DateTime]::MinValue -or (($now - $lastOutageWarningAt).TotalSeconds -ge $HeartbeatSeconds))) {
                Write-Warning "remote status poll SSH failed; job result is still unknown after ${outageSeconds}s. Last SSH error: $failureReason. Manual check: $manualCheckCommand"
                $lastOutageWarningAt = $now
            }
            Start-Sleep -Seconds $PollSeconds
            continue
        }
        if ($result.ExitCode -ne 0) {
            Fail "remote job status check failed with exit code $($result.ExitCode)"
        }

        $transportFailures = 0
        $lastStatusAvailableAt = [DateTime]::UtcNow
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
        if ($MaxWaitSeconds -gt 0 -and (($now - $startedAt).TotalSeconds -ge $MaxWaitSeconds)) {
            Fail "remote job still running after ${MaxWaitSeconds}s; last step: $currentStep; last task: $lastTask; log: $RemoteLog"
        }
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
if ($ReinitStandby) {
    if ($Service -ne "postgres_runtime") {
        Fail "-ReinitStandby is supported only for service postgres_runtime"
    }
    if ($Action -ne "apply") {
        Fail "-ReinitStandby requires action apply"
    }
    if (-not $Limit) {
        Fail "-ReinitStandby requires -Limit for the intended standby alias"
    }
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
$resolvedStateFile = (Resolve-Path -LiteralPath $StateFile).Path
$NetworksFile = Join-Path (Split-Path -Parent $resolvedStateFile) "networks.csv"
Require-File $NetworksFile "networks.csv next to StateFile"

$script:SshExecutablePath = Resolve-OpenSshClient
$script:ScpExecutablePath = Resolve-OpenSshExecutable "scp"

$nodesHeader = Get-Content -LiteralPath $NodesFile -TotalCount 1
if ($nodesHeader -ne $ExpectedHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedHeader"
}
$stateHeader = Get-Content -LiteralPath $StateFile -TotalCount 1
if ($stateHeader -ne $ExpectedStateHeader) {
    Fail "state.csv header must be exactly: $ExpectedStateHeader"
}
$networksHeader = Get-Content -LiteralPath $NetworksFile -TotalCount 1
if ($networksHeader -ne $ExpectedNetworksHeader) {
    Fail "networks.csv header must be exactly: $ExpectedNetworksHeader"
}

$nodes = Import-Csv -LiteralPath $NodesFile
$stateRows = Import-Csv -LiteralPath $StateFile
$controlNode = Resolve-ControlNodeFromState $nodes $stateRows $ControlRole $ControlAlias
$controlSshPort = Get-NodeSshPort $controlNode

if (-not $SshKeyFile) {
    $SshKeyFile = Join-Path (Join-Path $OperatorDir $controlNode.current_alias) "admin_key"
}
if (-not $KnownHostsFile) {
    $KnownHostsFile = Join-Path ([System.IO.Path]::GetTempPath()) "ai-service-platform.known_hosts"
}
Require-File $SshKeyFile "SshKeyFile"
$SshKeyFile = (Resolve-Path -LiteralPath $SshKeyFile).Path
$KnownHostsFile = [System.IO.Path]::GetFullPath($KnownHostsFile)
Ensure-OpenSshPrivateKeyAcl $SshKeyFile
Require-File $ServiceRunnerScript "ServiceRunnerScript"
Require-File $CreateInventoryScript "CreateInventoryScript"
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
$remoteCreateInventoryTemp = "$remoteBundleDir/tools/bootstrap/create_inventory.sh"
$remoteAnsibleTemp = "$remoteBundleDir/ansible"
$remotePolicyRouterDockerTemp = "$remoteBundleDir/docker/policy-router"
$remotePolicyGatewayDockerTemp = "$remoteBundleDir/docker/policy-gateway"
$remoteEgressPolicyToolsTemp = "$remoteBundleDir/tools/egress_policy"
$remoteOperatorCsvTemp = "$remoteBundleDir/operator"
$remoteNodesDir = Split-RemoteParentPath $RemoteNodesFile
$remoteOperatorDir = Split-RemoteParentPath $RemoteStateFile
$remoteNetworksFile = "$remoteOperatorDir/networks.csv"
$remoteJobId = "service-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$([guid]::NewGuid().ToString('N'))"
$remoteJobLogDir = "/var/log/ai-service-platform/jobs"
$remoteJobStateRoot = "/var/lib/ai-service-platform/jobs"
$remoteJobDir = "$remoteJobStateRoot/$remoteJobId"
$remoteJobScript = "$remoteJobDir/run.sh"
$remoteJobLog = "$remoteJobLogDir/$remoteJobId.log"
$remoteJobPid = "$remoteJobDir/pid"
$remoteJobExitCode = "$remoteJobDir/exit_code"
$remoteJobDone = "$remoteJobDir/done"
$refreshKnownHostsCommand = New-RefreshAnsibleKnownHostsCommand $RemoteNodesFile $controlNode.current_alias
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
        ReinitStandby = [bool]$ReinitStandby
        PolicyRouterImageRef = $PolicyRouterImageRef
        BuildPolicyRouterImage = [bool]$BuildPolicyRouterImage
        Label = if ($Limit) { "$Service $Action for $Limit" } else { "$Service $Action" }
    }
    $serviceCommand = New-ServiceCommand $singleStep $RemoteRepoDir $RemoteNodesFile $RemoteStateFile $RemoteInventory
}
$useDetachedRemoteJob = $true
$installCommands = ""
if (-not $isBatch) {
    $installCommands = @(
        "set -e",
        "sudo mkdir -p $(Quote-BashArg "$RemoteRepoDir/tools/services") $(Quote-BashArg "$RemoteRepoDir/tools/bootstrap") $(Quote-BashArg "$RemoteRepoDir/tools") $(Quote-BashArg "$RemoteRepoDir/infra") $(Quote-BashArg "$RemoteRepoDir/infra/docker")",
        "sudo install -m 700 $(Quote-BashArg $remoteServiceRunnerTemp) $(Quote-BashArg "$RemoteRepoDir/tools/services/service.sh")",
        "sudo install -m 700 $(Quote-BashArg $remoteCreateInventoryTemp) $(Quote-BashArg "$RemoteRepoDir/tools/bootstrap/create_inventory.sh")",
        "sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/tools/egress_policy")",
        "sudo cp -a $(Quote-BashArg $remoteEgressPolicyToolsTemp) $(Quote-BashArg "$RemoteRepoDir/tools/egress_policy")",
        "sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/infra/ansible")",
        "sudo cp -a $(Quote-BashArg $remoteAnsibleTemp) $(Quote-BashArg "$RemoteRepoDir/infra/ansible")",
        "sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/infra/docker/policy-router")",
        "sudo cp -a $(Quote-BashArg $remotePolicyRouterDockerTemp) $(Quote-BashArg "$RemoteRepoDir/infra/docker/policy-router")",
        "sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/infra/docker/policy-gateway")",
        "sudo cp -a $(Quote-BashArg $remotePolicyGatewayDockerTemp) $(Quote-BashArg "$RemoteRepoDir/infra/docker/policy-gateway")",
        "printf '%s\n' 'Syncing operator CSV intent to orchestration node'",
        "sudo mkdir -p $(Quote-BashArg $remoteNodesDir) $(Quote-BashArg $remoteOperatorDir)",
        "sudo install -o ansible -g ansible -m 600 $(Quote-BashArg "$remoteOperatorCsvTemp/nodes.csv") $(Quote-BashArg $RemoteNodesFile)",
        "sudo install -o ansible -g ansible -m 600 $(Quote-BashArg "$remoteOperatorCsvTemp/state.csv") $(Quote-BashArg $RemoteStateFile)",
        "sudo install -o ansible -g ansible -m 600 $(Quote-BashArg "$remoteOperatorCsvTemp/networks.csv") $(Quote-BashArg $remoteNetworksFile)",
        "printf '%s\n' 'Refreshing ansible known_hosts from operator nodes'",
        $refreshKnownHostsCommand,
        "printf '%s\n' 'Regenerating Ansible inventory from operator state'",
        "sudo bash $(Quote-BashArg "$RemoteRepoDir/tools/bootstrap/create_inventory.sh") --nodes-file $(Quote-BashArg $RemoteNodesFile) --state-file $(Quote-BashArg $RemoteStateFile) --output $(Quote-BashArg $RemoteInventory)",
        "if [ -d $(Quote-BashArg "$remoteOperatorCsvTemp/haproxy") ]; then sudo rm -rf $(Quote-BashArg "$remoteOperatorDir/haproxy"); sudo cp -a $(Quote-BashArg "$remoteOperatorCsvTemp/haproxy") $(Quote-BashArg "$remoteOperatorDir/haproxy"); sudo chown -R ansible:ansible $(Quote-BashArg "$remoteOperatorDir/haproxy"); fi",
        "if [ -d $(Quote-BashArg "$remoteOperatorCsvTemp/softether") ]; then sudo rm -rf $(Quote-BashArg "$remoteOperatorDir/softether"); sudo cp -a $(Quote-BashArg "$remoteOperatorCsvTemp/softether") $(Quote-BashArg "$remoteOperatorDir/softether"); sudo chown -R ansible:ansible $(Quote-BashArg "$remoteOperatorDir/softether"); fi",
        "if [ -d $(Quote-BashArg "$remoteOperatorCsvTemp/edge_banlist") ]; then sudo rm -rf $(Quote-BashArg "$remoteOperatorDir/edge_banlist"); sudo cp -a $(Quote-BashArg "$remoteOperatorCsvTemp/edge_banlist") $(Quote-BashArg "$remoteOperatorDir/edge_banlist"); sudo chown -R ansible:ansible $(Quote-BashArg "$remoteOperatorDir/edge_banlist"); fi",
        "if [ -d $(Quote-BashArg "$remoteOperatorCsvTemp/postgres") ]; then sudo rm -rf $(Quote-BashArg "$remoteOperatorDir/postgres"); sudo cp -a $(Quote-BashArg "$remoteOperatorCsvTemp/postgres") $(Quote-BashArg "$remoteOperatorDir/postgres"); sudo chown -R ansible:ansible $(Quote-BashArg "$remoteOperatorDir/postgres"); fi",
        "if [ -d $(Quote-BashArg "$remoteOperatorCsvTemp/platform_networks") ]; then sudo rm -rf $(Quote-BashArg "$remoteOperatorDir/platform_networks"); sudo cp -a $(Quote-BashArg "$remoteOperatorCsvTemp/platform_networks") $(Quote-BashArg "$remoteOperatorDir/platform_networks"); sudo chown -R ansible:ansible $(Quote-BashArg "$remoteOperatorDir/platform_networks"); fi",
        "if [ -d $(Quote-BashArg "$remoteOperatorCsvTemp/platform_router") ]; then sudo rm -rf $(Quote-BashArg "$remoteOperatorDir/platform_router"); sudo cp -a $(Quote-BashArg "$remoteOperatorCsvTemp/platform_router") $(Quote-BashArg "$remoteOperatorDir/platform_router"); sudo chown -R ansible:ansible $(Quote-BashArg "$remoteOperatorDir/platform_router"); fi",
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
        Write-Host "Policy image: $PolicyRouterImageRef (explicit pin)"
    }
    if ($BuildPolicyRouterImage) {
        Write-Host "Build policy image: forced"
    }
}
if ($useDetachedRemoteJob) {
    Write-Host "Mode:         detached remote job"
    Write-Host "Job id:       $remoteJobId"
    Write-Host "Remote log:   $remoteJobLog"
} else {
    Write-Host "Mode:         direct SSH stream"
}

$sshCommonArgs = @(
    "-n",
    "-T",
    "-p", $controlSshPort,
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
    $sshCommonArgs += @("-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=$KnownHostsFile", "-o", "LogLevel=ERROR")
}
$scpCommonArgs = @(
    "-B",
    "-P", $controlSshPort,
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
    $scpCommonArgs += @("-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=$KnownHostsFile", "-o", "LogLevel=ERROR")
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
    if ($ReinitStandby) { $remoteServiceDisplayArgs += "--reinit-standby" }
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
    "JOB_FINISHED=0",
    "finish_job() { rc=""`${1:-1}""; JOB_FINISHED=1; tmp=$(Quote-BashArg "$remoteJobExitCode.tmp"); printf '%s\n' ""`$rc"" > ""`$tmp""; mv -f ""`$tmp"" $(Quote-BashArg $remoteJobExitCode); touch $(Quote-BashArg $remoteJobDone); log_stage ""remote job markers written: exit_code=$(Quote-BashArg $remoteJobExitCode), done=$(Quote-BashArg $remoteJobDone), rc=`$rc""; exit ""`$rc""; }",
    "trap 'rc=""`$?""; if [ ""`$JOB_FINISHED"" != ""1"" ]; then log_stage ""remote job exiting via trap rc=`$rc""; finish_job ""`$rc""; fi' EXIT",
    "run_stage() { label=""`$1""; shift; log_stage ""`$label""; ""`$@""; rc=""`$?""; if [ ""`$rc"" -ne 0 ]; then log_stage ""failed: `$label (rc=`$rc)""; finish_job ""`$rc""; fi; }",
    "run_stage $(Quote-BashArg "prepare repo directories") sudo mkdir -p $(Quote-BashArg "$RemoteRepoDir/tools/services") $(Quote-BashArg "$RemoteRepoDir/tools/bootstrap") $(Quote-BashArg "$RemoteRepoDir/tools") $(Quote-BashArg "$RemoteRepoDir/infra") $(Quote-BashArg "$RemoteRepoDir/infra/docker")",
    "run_stage $(Quote-BashArg "install service runner") sudo install -m 700 $(Quote-BashArg $remoteServiceRunnerTemp) $(Quote-BashArg "$RemoteRepoDir/tools/services/service.sh")",
    "run_stage $(Quote-BashArg "install inventory generator") sudo install -m 700 $(Quote-BashArg $remoteCreateInventoryTemp) $(Quote-BashArg "$RemoteRepoDir/tools/bootstrap/create_inventory.sh")",
    "run_stage $(Quote-BashArg "remove previous egress policy tools") sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/tools/egress_policy")",
    "run_stage $(Quote-BashArg "install egress policy tools") sudo cp -a $(Quote-BashArg $remoteEgressPolicyToolsTemp) $(Quote-BashArg "$RemoteRepoDir/tools/egress_policy")",
    "run_stage $(Quote-BashArg "remove previous Ansible bundle") sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/infra/ansible")",
    "run_stage $(Quote-BashArg "install Ansible bundle") sudo cp -a $(Quote-BashArg $remoteAnsibleTemp) $(Quote-BashArg "$RemoteRepoDir/infra/ansible")",
    "run_stage $(Quote-BashArg "remove previous policy-router Docker context") sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/infra/docker/policy-router")",
    "run_stage $(Quote-BashArg "install policy-router Docker context") sudo cp -a $(Quote-BashArg $remotePolicyRouterDockerTemp) $(Quote-BashArg "$RemoteRepoDir/infra/docker/policy-router")",
    "run_stage $(Quote-BashArg "remove previous policy-gateway Docker context") sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/infra/docker/policy-gateway")",
    "run_stage $(Quote-BashArg "install policy-gateway Docker context") sudo cp -a $(Quote-BashArg $remotePolicyGatewayDockerTemp) $(Quote-BashArg "$RemoteRepoDir/infra/docker/policy-gateway")",
    "printf '%s\n' 'Syncing operator CSV intent to orchestration node'",
    "run_stage $(Quote-BashArg "prepare operator CSV directory") sudo mkdir -p $(Quote-BashArg $remoteNodesDir) $(Quote-BashArg $remoteOperatorDir)",
    "run_stage $(Quote-BashArg "install operator nodes.csv") sudo install -o ansible -g ansible -m 600 $(Quote-BashArg "$remoteOperatorCsvTemp/nodes.csv") $(Quote-BashArg $RemoteNodesFile)",
    "run_stage $(Quote-BashArg "install operator state.csv") sudo install -o ansible -g ansible -m 600 $(Quote-BashArg "$remoteOperatorCsvTemp/state.csv") $(Quote-BashArg $RemoteStateFile)",
    "run_stage $(Quote-BashArg "install operator networks.csv") sudo install -o ansible -g ansible -m 600 $(Quote-BashArg "$remoteOperatorCsvTemp/networks.csv") $(Quote-BashArg $remoteNetworksFile)",
    "run_stage $(Quote-BashArg "refresh ansible known_hosts") bash -lc $(Quote-BashArg $refreshKnownHostsCommand)",
    "run_stage $(Quote-BashArg "regenerate Ansible inventory") sudo bash $(Quote-BashArg "$RemoteRepoDir/tools/bootstrap/create_inventory.sh") --nodes-file $(Quote-BashArg $RemoteNodesFile) --state-file $(Quote-BashArg $RemoteStateFile) --output $(Quote-BashArg $RemoteInventory)",
    "if [ -d $(Quote-BashArg "$remoteOperatorCsvTemp/haproxy") ]; then run_stage $(Quote-BashArg "sync operator haproxy config") sudo bash -lc $(Quote-BashArg "rm -rf $(Quote-BashArg "$remoteOperatorDir/haproxy"); cp -a $(Quote-BashArg "$remoteOperatorCsvTemp/haproxy") $(Quote-BashArg "$remoteOperatorDir/haproxy"); chown -R ansible:ansible $(Quote-BashArg "$remoteOperatorDir/haproxy")"); fi",
    "if [ -d $(Quote-BashArg "$remoteOperatorCsvTemp/softether") ]; then run_stage $(Quote-BashArg "sync operator softether config") sudo bash -lc $(Quote-BashArg "rm -rf $(Quote-BashArg "$remoteOperatorDir/softether"); cp -a $(Quote-BashArg "$remoteOperatorCsvTemp/softether") $(Quote-BashArg "$remoteOperatorDir/softether"); chown -R ansible:ansible $(Quote-BashArg "$remoteOperatorDir/softether")"); fi",
    "if [ -d $(Quote-BashArg "$remoteOperatorCsvTemp/edge_banlist") ]; then run_stage $(Quote-BashArg "sync operator edge_banlist config") sudo bash -lc $(Quote-BashArg "rm -rf $(Quote-BashArg "$remoteOperatorDir/edge_banlist"); cp -a $(Quote-BashArg "$remoteOperatorCsvTemp/edge_banlist") $(Quote-BashArg "$remoteOperatorDir/edge_banlist"); chown -R ansible:ansible $(Quote-BashArg "$remoteOperatorDir/edge_banlist")"); fi",
    "if [ -d $(Quote-BashArg "$remoteOperatorCsvTemp/postgres") ]; then run_stage $(Quote-BashArg "sync operator postgres config") sudo bash -lc $(Quote-BashArg "rm -rf $(Quote-BashArg "$remoteOperatorDir/postgres"); cp -a $(Quote-BashArg "$remoteOperatorCsvTemp/postgres") $(Quote-BashArg "$remoteOperatorDir/postgres"); chown -R ansible:ansible $(Quote-BashArg "$remoteOperatorDir/postgres")"); fi",
    "if [ -d $(Quote-BashArg "$remoteOperatorCsvTemp/platform_networks") ]; then run_stage $(Quote-BashArg "sync operator platform_networks config") sudo bash -lc $(Quote-BashArg "rm -rf $(Quote-BashArg "$remoteOperatorDir/platform_networks"); cp -a $(Quote-BashArg "$remoteOperatorCsvTemp/platform_networks") $(Quote-BashArg "$remoteOperatorDir/platform_networks"); chown -R ansible:ansible $(Quote-BashArg "$remoteOperatorDir/platform_networks")"); fi",
    "if [ -d $(Quote-BashArg "$remoteOperatorCsvTemp/platform_router") ]; then run_stage $(Quote-BashArg "sync operator platform_router config") sudo bash -lc $(Quote-BashArg "rm -rf $(Quote-BashArg "$remoteOperatorDir/platform_router"); cp -a $(Quote-BashArg "$remoteOperatorCsvTemp/platform_router") $(Quote-BashArg "$remoteOperatorDir/platform_router"); chown -R ansible:ansible $(Quote-BashArg "$remoteOperatorDir/platform_router")"); fi"
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
            "if [ ""`$rc"" -ne 0 ]; then finish_job ""`$rc""; fi"
        )) { $runScriptLines.Add($line) | Out-Null }
    }
    foreach ($line in @(
        "printf '\n[batch] Summary\n'",
        "cat ""`$SUMMARY_FILE""",
        "rc=0",
        "finish_job ""`$rc"""
    )) { $runScriptLines.Add($line) | Out-Null }
} else {
    foreach ($line in @(
        "log_stage $(Quote-BashArg "running service command: $remoteServiceDisplay")",
        "sudo bash -lc $(Quote-BashArg $serviceCommand)",
        "rc=`$?",
        "log_stage ""service command finished with rc=`$rc""",
        "finish_job ""`$rc"""
    )) { $runScriptLines.Add($line) | Out-Null }
}

try {
    Write-Host "Preparing local service bundle..."
    $bundle = New-TarGzBundle $ServiceRunnerScript $CreateInventoryScript $AnsibleDir $PolicyRouterDockerDir $PolicyGatewayDockerDir $EgressPolicyToolsDir $NodesFile $StateFile $NetworksFile
    if ($useDetachedRemoteJob) {
        Write-LfScript $runScriptPath $runScriptLines
    }

    Invoke-RemoteTempCleanup $sshCommonArgs $remote

    if ($useDetachedRemoteJob) {
        Write-Host "Creating remote temporary bundle and durable job directories..."
        $mkdirCommand = @(
            "set -e",
            "mkdir -p $(Quote-BashArg $remoteBundleDir)",
            "sudo mkdir -p $(Quote-BashArg $remoteJobLogDir) $(Quote-BashArg $remoteJobDir)",
            "sudo chown ""`$(id -u):`$(id -g)"" $(Quote-BashArg $remoteJobLogDir) $(Quote-BashArg $remoteJobDir)",
            "chmod 750 $(Quote-BashArg $remoteJobDir)"
        ) -join "; "
    } else {
        Write-Host "Creating remote temporary bundle directory..."
        $mkdirCommand = "mkdir -p $(Quote-BashArg $remoteBundleDir)"
    }
    Invoke-ExternalRetryTransport $script:SshExecutablePath ($sshCommonArgs + @(
        $remote,
        $mkdirCommand
    )) "remote service bundle directory creation" $RemoteTransferAttempts

    Write-Host "Uploading service bundle archive..."
    Invoke-ExternalRetrySshTransport $script:ScpExecutablePath ($scpCommonArgs + @(
        $bundle.ArchivePath,
        "${remote}:$remoteBundleArchive"
    )) "service bundle upload" $RemoteTransferAttempts $RemoteTransferRetryDelaySeconds

    if ($useDetachedRemoteJob) {
        Write-Host "Uploading remote job runner..."
        Invoke-ExternalRetrySshTransport $script:ScpExecutablePath ($scpCommonArgs + @(
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
        "test -f $(Quote-BashArg $remoteCreateInventoryTemp)",
        "test -d $(Quote-BashArg $remoteEgressPolicyToolsTemp)",
        "test -d $(Quote-BashArg $remoteAnsibleTemp)",
        "test -d $(Quote-BashArg $remotePolicyRouterDockerTemp)",
        "test -d $(Quote-BashArg $remotePolicyGatewayDockerTemp)",
        "test -f $(Quote-BashArg "$remoteOperatorCsvTemp/nodes.csv")",
        "test -f $(Quote-BashArg "$remoteOperatorCsvTemp/state.csv")",
        "test -f $(Quote-BashArg "$remoteOperatorCsvTemp/networks.csv")"
    ) -join "; "

    Write-Host "Extracting service bundle on orchestration node..."
    Invoke-ExternalRetryTransport $script:SshExecutablePath ($sshCommonArgs + @(
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
        Invoke-ExternalRetryTransport $script:SshExecutablePath ($sshCommonArgs + @(
            $remote,
            $startJobCommand
        )) "remote service job start" $RemoteTransferAttempts

        Write-Host "Following remote service job log..."
        Wait-RemoteServiceJob -SshArgs ([string[]]$sshCommonArgs) -Remote $remote -RemoteLog $remoteJobLog -RemoteDone $remoteJobDone -RemoteExitCode $remoteJobExitCode -RemotePid $remoteJobPid -PollSeconds $RemoteJobPollSeconds -ReconnectAttempts $RemoteJobReconnectAttempts -MaxWaitSeconds $RemoteJobMaxWaitSeconds -StatusOutageMaxSeconds $RemoteJobStatusOutageMaxSeconds -HeartbeatSeconds $RemoteJobHeartbeatSeconds
        $remoteJobCompletedSuccessfully = $true
    } else {
        Write-Host "Installing service bundle and running remote service command..."
        Invoke-ExternalRetrySshTransport $script:SshExecutablePath ($sshCommonArgs + @(
            $remote,
            $installCommands
        )) "remote service command" $RemoteTransferAttempts $RemoteTransferRetryDelaySeconds
        Write-Host "remote service command completed successfully; cleanup is non-fatal best-effort"
    }
} finally {
    if ($bundle) {
        Remove-Item -LiteralPath $bundle.ArchivePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $bundle.StagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $runScriptPath -Force -ErrorAction SilentlyContinue
    if ($useDetachedRemoteJob -and $remoteJobCompletedSuccessfully) {
        Write-Host "Cleaning remote temporary service bundle and completed job state; preserving rotated job log: $remoteJobLog"
        $cleanupTarget = New-BackgroundCleanupCommand "rm -rf $(Quote-BashArg $remoteBundleDir) $(Quote-BashArg $remoteBundleArchive) $(Quote-BashArg $remoteJobDir)"
    } elseif ($useDetachedRemoteJob) {
        Write-Host "Cleaning remote temporary service bundle; preserving failed job state: $remoteJobDir and log: $remoteJobLog"
        $cleanupTarget = New-BackgroundCleanupCommand "rm -rf $(Quote-BashArg $remoteBundleDir) $(Quote-BashArg $remoteBundleArchive)"
    } else {
        Write-Host "Cleaning remote temporary service bundle..."
        $cleanupTarget = New-BackgroundCleanupCommand "rm -rf $(Quote-BashArg $remoteBundleDir) $(Quote-BashArg $remoteBundleArchive) $(Quote-BashArg $remoteJobDir)"
    }
    if ($remote -and $remoteBundleDir -and $remoteBundleArchive -and $remoteJobDir -and $sshCommonArgs) {
        Invoke-CleanupSsh ($sshCommonArgs + @(
            $remote,
            $cleanupTarget
        )) "remote service bundle and job cleanup"
        Write-Host "Remote cleanup scheduled; cleanup failures are non-fatal"
    }
}
