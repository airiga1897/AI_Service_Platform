param(
    [ValidateSet("probe", "readiness", "suggest", "report-probes", "report-proposals", "apply", "refresh", "reconcile", "default-egress", "collect")]
    [string]$Command,

    [Alias("Args")]
    [string]$CommandArgs = "",

    [string]$NodesFile = ".\operator\nodes.csv",

    [string]$StateFile = ".\operator\state.csv",

    [string]$OperatorDir = ".\operator",

    [string]$ControlRole = "orchestration",

    [string]$ControlAlias = "",

    [string]$KnownHostsFile = "",

    [string]$SshUser = "useradmin",

    [string]$SshKeyFile = "",

    [string]$RemoteRepoDir = "/opt/ai-service-platform",

    [string]$EgressPolicyToolsDir = ".\tools\egress_policy",

    [switch]$AutoAcceptHostKey = $true,

    [switch]$SkipDownload,

    [switch]$DirectSshStream,

    [switch]$AttachLast,

    [string]$AttachJobId = "",

    [switch]$KeepRemoteJob,

    [string]$LocalJobStateDir = ".\.tmp\egress_remote_jobs",

    [int]$RemoteJobPollSeconds = 2,

    [int]$RemoteJobReconnectAttempts = 30,

    [int]$RemoteJobHeartbeatSeconds = 10,

    [int]$RemoteTransferAttempts = 6,

    [int]$RemoteTransferRetryDelaySeconds = 5
)

$ErrorActionPreference = "Stop"
$ExpectedNodesHeader = "current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
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

function Invoke-External($FilePath, $Arguments, $Label) {
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label failed with exit code $LASTEXITCODE"
    }
}

function Invoke-CaptureExternal($FilePath, $Arguments) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $script:ErrorActionPreference = "Continue"
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $script:ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output | ForEach-Object { [string]$_ })
        Text = (@($output | ForEach-Object { [string]$_ }) -join "`n")
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

function Wait-RemoteEgressJob($SshPath, $SshArgs, $Remote, $LogPath, $DonePath, $ExitCodePath, $PollSeconds, $ReconnectAttempts, $HeartbeatSeconds) {
    $printedLines = 0
    $lastHeartbeat = Get-Date
    $transportFailures = 0
    while ($true) {
        $pollScript = @"
if [ -f $(Quote-BashArg $LogPath) ]; then tail -n +$($printedLines + 1) $(Quote-BashArg $LogPath); fi
printf '\n__AI_SP_EGRESS_LINES__='
if [ -f $(Quote-BashArg $LogPath) ]; then wc -l < $(Quote-BashArg $LogPath); else printf '0'; fi
printf '\n__AI_SP_EGRESS_DONE__='
if [ -f $(Quote-BashArg $DonePath) ]; then printf '1'; else printf '0'; fi
printf '\n__AI_SP_EGRESS_EXIT__='
if [ -f $(Quote-BashArg $ExitCodePath) ]; then cat $(Quote-BashArg $ExitCodePath); else printf ''; fi
printf '\n'
"@
        $result = Invoke-CaptureExternal $SshPath ($SshArgs + @($Remote, $pollScript))
        if ($result.ExitCode -eq 0) {
            $transportFailures = 0
            $linesValue = $printedLines
            $doneValue = "0"
            $exitValue = ""
            foreach ($line in $result.Output) {
                if ($line -like "__AI_SP_EGRESS_LINES__=*") {
                    [void][int]::TryParse(($line -replace "^__AI_SP_EGRESS_LINES__=", "").Trim(), [ref]$linesValue)
                    continue
                }
                if ($line -like "__AI_SP_EGRESS_DONE__=*") {
                    $doneValue = ($line -replace "^__AI_SP_EGRESS_DONE__=", "").Trim()
                    continue
                }
                if ($line -like "__AI_SP_EGRESS_EXIT__=*") {
                    $exitValue = ($line -replace "^__AI_SP_EGRESS_EXIT__=", "").Trim()
                    continue
                }
                if ($line -ne "") {
                    Write-Host $line
                }
            }
            $printedLines = $linesValue
            if ($doneValue -eq "1") {
                $exitCode = 1
                if (-not [int]::TryParse($exitValue, [ref]$exitCode)) {
                    $exitCode = 1
                }
                return [pscustomobject]@{ ExitCode = $exitCode; LogPath = $LogPath }
            }
        } else {
            $transportFailures++
            Write-Warning "Lost SSH connection while polling remote egress job ($transportFailures/$ReconnectAttempts). Remote log: $LogPath"
            if ($transportFailures -ge $ReconnectAttempts) {
                Fail "remote egress job polling failed after $ReconnectAttempts reconnect attempts. Remote log: $LogPath"
            }
        }

        $now = Get-Date
        if (($now - $lastHeartbeat).TotalSeconds -ge $HeartbeatSeconds) {
            Write-Host "[remote-egress] still running; streaming log from $LogPath"
            $lastHeartbeat = $now
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Get-LocalJobStatePath($JobId) {
    return (Join-Path $LocalJobStateDir "$JobId.json")
}

function Save-RemoteEgressJobState($State) {
    New-Item -ItemType Directory -Path $LocalJobStateDir -Force | Out-Null
    $path = Get-LocalJobStatePath $State.job_id
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
    Write-Host "[remote-egress] saved attach state: $path"
}

function Get-RemoteEgressJobState($JobId) {
    $path = Get-LocalJobStatePath $JobId
    Require-File $path "remote egress job state"
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Get-LastRemoteEgressJobState {
    if (-not (Test-Path -LiteralPath $LocalJobStateDir -PathType Container)) {
        Fail "No local egress job state directory found: $LocalJobStateDir"
    }
    $file = Get-ChildItem -LiteralPath $LocalJobStateDir -Filter "*.json" -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $file) {
        Fail "No local egress job state files found in: $LocalJobStateDir"
    }
    return Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
}

function Download-RemoteEgressArtifacts($RemoteResultArchivePath) {
    if ($SkipDownload) {
        return
    }
    Write-Host "[remote-egress] downloading result artifacts"
    Invoke-ExternalRetrySshTransport $script:ScpExecutablePath ($scpCommonArgs + @("${remote}:$RemoteResultArchivePath", $downloadArchivePath)) "download egress policy results" $RemoteTransferAttempts $RemoteTransferRetryDelaySeconds
    New-Item -ItemType Directory -Path $downloadExtractDir -Force | Out-Null
    & tar -xzf $downloadArchivePath -C $downloadExtractDir
    if ($LASTEXITCODE -ne 0) {
        Fail "failed to extract egress policy result archive"
    }
    Merge-DownloadedEgressArtifacts (Join-Path $downloadExtractDir "operator") (Join-Path $OperatorDir "egress_policy")
    Write-Host "[OK] Egress policy artifacts downloaded to $(Join-Path $OperatorDir "egress_policy")"
}

function Write-LfScript($Path, $Lines) {
    $content = (@($Lines) -join "`n") + "`n"
    [System.IO.File]::WriteAllText($Path, $content, [System.Text.Encoding]::ASCII)
}

function Copy-AdminKeyLf($Source, $Destination) {
    $resolvedSource = (Resolve-Path -LiteralPath $Source).Path
    $destinationDir = Split-Path -Parent $Destination
    if ($destinationDir) {
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    }

    $bytes = [System.IO.File]::ReadAllBytes($resolvedSource)
    $content = [System.Text.Encoding]::ASCII.GetString($bytes)
    $content = ($content -replace "`r`n", "`n") -replace "`r", "`n"
    if (-not $content.EndsWith("`n")) {
        $content += "`n"
    }
    [System.IO.File]::WriteAllText($Destination, $content, [System.Text.Encoding]::ASCII)
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
        Fail "Control node $($node.current_alias) must use connection=ssh and a real endpoint for egress policy remote execution."
    }
    return $node
}

function Get-OrchestrationAliasesFromState($StateRows, $Role) {
    $aliases = New-Object System.Collections.ArrayList
    foreach ($row in @($StateRows | Where-Object { ($_.kind -eq "platform_role" -or $_.kind -eq "role") -and $_.name -eq $Role -and $_.state -eq "present" })) {
        foreach ($field in @("active_aliases", "candidate_aliases")) {
            foreach ($aliasName in @(Split-AliasList $row.$field)) {
                if ($aliasName -and -not $aliases.Contains($aliasName)) {
                    [void]$aliases.Add($aliasName)
                }
            }
        }
    }
    return @($aliases.ToArray())
}

function Get-EgressScriptPath($Name) {
    $map = @{
        "probe"            = "probe_egress_policy.sh"
        "readiness"        = "check_selective_fallback_readiness.sh"
        "suggest"          = "suggest_egress_policy.sh"
        "report-probes"    = "report_egress_probes.ps1"
        "report-proposals" = "report_egress_proposals.ps1"
        "apply"            = "apply_selective_fallback_routes.sh"
        "refresh"          = "refresh_selective_fallback_dns_sets.ps1"
        "reconcile"        = "reconcile_selective_fallback.ps1"
        "default-egress"   = "apply_policy_gateway_default_egress.ps1"
        "collect"          = "collect_egress_candidates.ps1"
    }
    if (-not $map.ContainsKey($Name)) {
        Fail "Unsupported egress policy command: $Name"
    }
    return "./tools/egress_policy/$($map[$Name])"
}

function Copy-DirectoryIfExists($Source, $Destination) {
    if (Test-Path -LiteralPath $Source -PathType Container) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Destination -Recurse
    }
}

function New-EgressPolicyBundle($EgressPolicyToolsDir, $NodesFile, $StateFile, $NetworksFile, $OperatorDir, $NodeRows, $ExcludedManagedAliases) {
    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        Fail "tar not found in PATH. It is required to upload egress policy bundles as a single archive."
    }

    $stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.egress-policy-remote." + [guid]::NewGuid().ToString("N"))
    $archivePath = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.egress-policy-remote." + [guid]::NewGuid().ToString("N") + ".tar.gz")
    New-Item -ItemType Directory -Path $stagingDir | Out-Null
    try {
        $toolsTarget = Join-Path (Join-Path $stagingDir "tools") "egress_policy"
        New-Item -ItemType Directory -Path (Split-Path -Parent $toolsTarget) -Force | Out-Null
        Copy-Item -LiteralPath $EgressPolicyToolsDir -Destination $toolsTarget -Recurse

        $operatorStagingDir = Join-Path $stagingDir "operator"
        New-Item -ItemType Directory -Path $operatorStagingDir | Out-Null
        Copy-Item -LiteralPath $NodesFile -Destination (Join-Path $operatorStagingDir "nodes.csv")
        Copy-Item -LiteralPath $StateFile -Destination (Join-Path $operatorStagingDir "state.csv")
        Copy-Item -LiteralPath $NetworksFile -Destination (Join-Path $operatorStagingDir "networks.csv")

        foreach ($operatorSubdir in @("egress_policy", "softether")) {
            Copy-DirectoryIfExists (Join-Path $OperatorDir $operatorSubdir) (Join-Path $operatorStagingDir $operatorSubdir)
        }

        foreach ($node in $NodeRows) {
            if (-not $node.current_alias) {
                continue
            }
            if ($ExcludedManagedAliases -contains [string]$node.current_alias) {
                continue
            }
            $sourceAdminKey = Join-Path (Join-Path $OperatorDir $node.current_alias) "admin_key"
            if (Test-Path -LiteralPath $sourceAdminKey -PathType Leaf) {
                $aliasDir = Join-Path $operatorStagingDir $node.current_alias
                New-Item -ItemType Directory -Path $aliasDir -Force | Out-Null
                Copy-AdminKeyLf $sourceAdminKey (Join-Path $aliasDir "admin_key")
            }
        }

        & tar -czf $archivePath -C $stagingDir .
        if ($LASTEXITCODE -ne 0) {
            Fail "Failed to create egress policy bundle archive"
        }
        return @{ ArchivePath = $archivePath; StagingDir = $stagingDir }
    } catch {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Merge-DownloadedEgressArtifacts($ExtractedOperatorDir, $LocalEgressPolicyDir) {
    $remoteEgressDir = Join-Path $ExtractedOperatorDir "egress_policy"
    if (-not (Test-Path -LiteralPath $remoteEgressDir -PathType Container)) {
        return
    }
    New-Item -ItemType Directory -Path $LocalEgressPolicyDir -Force | Out-Null
    foreach ($name in @("history", "proposals", "applied_routes", "dns_sets", "default_egress", "candidates")) {
        $sourceDir = Join-Path $remoteEgressDir $name
        if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
            continue
        }
        $destinationDir = Join-Path $LocalEgressPolicyDir $name
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
        foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceDir -File)) {
            $destinationFile = Join-Path $destinationDir $sourceFile.Name
            try {
                if ((Test-Path -LiteralPath $destinationFile -PathType Leaf) -and ($sourceFile.LastWriteTimeUtc -le (Get-Item -LiteralPath $destinationFile).LastWriteTimeUtc)) {
                    continue
                }
                Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationFile -Force
            } catch {
                Write-Warning "Skipping downloaded egress artifact $($sourceFile.Name): $($_.Exception.Message)"
            }
        }
    }
}

if ($AttachLast -and $AttachJobId) {
    Fail "Use either -AttachLast or -AttachJobId, not both."
}
if (-not $Command -and -not $AttachLast -and -not $AttachJobId) {
    Fail "Command is required. Use one of: probe, readiness, suggest, report-probes, report-proposals, apply, refresh, reconcile, default-egress, collect."
}
if ($RemoteTransferAttempts -lt 1) {
    Fail "RemoteTransferAttempts must be greater than zero"
}
if ($RemoteTransferRetryDelaySeconds -lt 1) {
    Fail "RemoteTransferRetryDelaySeconds must be greater than zero"
}
if ($RemoteJobPollSeconds -lt 1) {
    Fail "RemoteJobPollSeconds must be greater than zero"
}
if ($RemoteJobReconnectAttempts -lt 1) {
    Fail "RemoteJobReconnectAttempts must be greater than zero"
}
if ($RemoteJobHeartbeatSeconds -lt 1) {
    Fail "RemoteJobHeartbeatSeconds must be greater than zero"
}

Require-File $NodesFile "NodesFile"
Require-File $StateFile "StateFile"
if (-not (Test-Path -LiteralPath $OperatorDir -PathType Container)) {
    Fail "OperatorDir not found: $OperatorDir"
}
if (-not (Test-Path -LiteralPath $EgressPolicyToolsDir -PathType Container)) {
    Fail "EgressPolicyToolsDir not found: $EgressPolicyToolsDir"
}

$resolvedStateFile = (Resolve-Path -LiteralPath $StateFile).Path
$NetworksFile = Join-Path (Split-Path -Parent $resolvedStateFile) "networks.csv"
Require-File $NetworksFile "networks.csv next to StateFile"

$nodesHeader = Get-Content -LiteralPath $NodesFile -TotalCount 1
if ($nodesHeader -ne $ExpectedNodesHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedNodesHeader"
}
$stateHeader = Get-Content -LiteralPath $StateFile -TotalCount 1
if ($stateHeader -ne $ExpectedStateHeader) {
    Fail "state.csv header must be exactly: $ExpectedStateHeader"
}
$networksHeader = Get-Content -LiteralPath $NetworksFile -TotalCount 1
if ($networksHeader -ne $ExpectedNetworksHeader) {
    Fail "networks.csv header must be exactly: $ExpectedNetworksHeader"
}

$script:SshExecutablePath = Resolve-OpenSshClient
$script:ScpExecutablePath = Resolve-OpenSshExecutable "scp"
$nodes = Import-Csv -LiteralPath $NodesFile
$stateRows = Import-Csv -LiteralPath $StateFile
$controlNode = Resolve-ControlNodeFromState $nodes $stateRows $ControlRole $ControlAlias
$controlSshPort = Get-NodeSshPort $controlNode
$orchestrationAliases = @(Get-OrchestrationAliasesFromState $stateRows $ControlRole)
if ($orchestrationAliases -notcontains [string]$controlNode.current_alias) {
    $orchestrationAliases += [string]$controlNode.current_alias
}

if (-not $SshKeyFile) {
    $SshKeyFile = Join-Path (Join-Path $OperatorDir $controlNode.current_alias) "admin_key"
}
if (-not $KnownHostsFile) {
    $KnownHostsFile = Join-Path ([System.IO.Path]::GetTempPath()) "ai-service-platform.known_hosts"
}
Require-File $SshKeyFile "SshKeyFile"
Ensure-OpenSshPrivateKeyAcl $SshKeyFile

$remote = "$SshUser@$($controlNode.endpoint)"
$remoteBundleDir = "/tmp/ai-service-platform.egress-policy-remote.$([guid]::NewGuid().ToString('N'))"
$remoteBundleArchive = "$remoteBundleDir.tar.gz"
$remoteRunScript = "$remoteBundleDir/run-egress-policy.sh"
$remoteResultArchive = "$remoteBundleDir.results.tar.gz"
$useDetachedRemoteJob = -not [bool]$DirectSshStream
$remoteJobId = [guid]::NewGuid().ToString("N")
$remoteJobDir = "/tmp/ai-service-platform.egress-job.$remoteJobId"
$remoteJobScript = "$remoteJobDir/run.sh"
$remoteJobLog = "$remoteJobDir/output.log"
$remoteJobPid = "$remoteJobDir/pid"
$remoteJobExitCode = "$remoteJobDir/exit_code"
$remoteJobDone = "$remoteJobDir/done"
$remoteEgressScript = ""
$remoteCommand = ""
$remoteDisplayCommand = ""
if ($Command) {
    $remoteEgressScript = Get-EgressScriptPath $Command
    $remoteCommand = "cd $(Quote-BashArg $RemoteRepoDir) && case $(Quote-BashArg $remoteEgressScript) in *.sh) sudo bash $(Quote-BashArg $remoteEgressScript) $CommandArgs ;; *) echo '[ERROR] this egress command has not been ported to Bash orchestration execution yet; run the .ps1 script locally only for diagnostics' >&2; exit 127 ;; esac"
    $remoteDisplayArgs = if ($CommandArgs) { " $CommandArgs" } else { "" }
    $remoteDisplayCommand = if ($remoteEgressScript -like "*.sh") {
        "cd $RemoteRepoDir; sudo bash $remoteEgressScript$remoteDisplayArgs"
    } else {
        "cd $RemoteRepoDir; $remoteEgressScript$remoteDisplayArgs"
    }
}
$resultPaths = "operator/egress_policy/history operator/egress_policy/proposals operator/egress_policy/applied_routes operator/egress_policy/dns_sets operator/egress_policy/default_egress operator/egress_policy/candidates"

$runScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.egress-policy-remote." + [guid]::NewGuid().ToString("N") + ".sh")
$downloadArchivePath = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.egress-policy-results." + [guid]::NewGuid().ToString("N") + ".tar.gz")
$downloadExtractDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.egress-policy-results." + [guid]::NewGuid().ToString("N"))
$bundle = $null

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

if ($AttachLast -or $AttachJobId) {
    $jobState = if ($AttachLast) { Get-LastRemoteEgressJobState } else { Get-RemoteEgressJobState $AttachJobId }
    Write-Host "Control node: $($controlNode.current_alias) via role '$ControlRole'"
    Write-Host "Control port: $controlSshPort"
    Write-Host "Remote:       $remote"
    Write-Host "Attach job:   $($jobState.job_id)"
    Write-Host "Command:      $($jobState.command)"
    Write-Host "Remote log:   $($jobState.remote_log)"
    $result = Wait-RemoteEgressJob $script:SshExecutablePath $sshCommonArgs $remote $jobState.remote_log $jobState.remote_done $jobState.remote_exit_code $RemoteJobPollSeconds $RemoteJobReconnectAttempts $RemoteJobHeartbeatSeconds
    if ($result.ExitCode -eq 0) {
        Download-RemoteEgressArtifacts $jobState.remote_result_archive
        if (-not $KeepRemoteJob) {
            $cleanupCommand = "rm -rf $(Quote-BashArg $jobState.remote_job_dir) $(Quote-BashArg $jobState.remote_bundle_dir) $(Quote-BashArg $jobState.remote_bundle_archive) $(Quote-BashArg $jobState.remote_result_archive)"
            & $script:SshExecutablePath @($sshCommonArgs + @($remote, $cleanupCommand)) *> $null
        }
        Write-Host "[OK] Remote egress policy command completed"
        exit 0
    }
    Fail "remote egress policy command failed with exit code $($result.ExitCode). Remote log preserved: $($jobState.remote_log)"
}

Write-Host "Control node: $($controlNode.current_alias) via role '$ControlRole'"
Write-Host "Control port: $controlSshPort"
Write-Host "Remote:       $remote"
Write-Host "Command:      $Command"
Write-Host "Args:         $CommandArgs"
Write-Host "Remote cwd:   $RemoteRepoDir"
Write-Host "Remote file:  $remoteEgressScript"
Write-Host "Remote exec:  $remoteDisplayCommand"
if ($useDetachedRemoteJob) {
    Write-Host "Mode:         detached remote job"
    Write-Host "Remote log:   $remoteJobLog"
} else {
    Write-Host "Mode:         direct SSH stream"
}

try {
    $bundle = New-EgressPolicyBundle $EgressPolicyToolsDir $NodesFile $StateFile $NetworksFile $OperatorDir $nodes $orchestrationAliases
    $detachedText = if ($useDetachedRemoteJob) { "true" } else { "false" }
    $runScriptLines = @(
        "#!/usr/bin/env bash",
        "set +e",
        "DETACHED_REMOTE_JOB=$(Quote-BashArg $detachedText)",
        "JOB_DIR=$(Quote-BashArg $remoteJobDir)",
        "JOB_LOG=$(Quote-BashArg $remoteJobLog)",
        "JOB_EXIT_CODE=$(Quote-BashArg $remoteJobExitCode)",
        "JOB_DONE=$(Quote-BashArg $remoteJobDone)",
        "if [ ""`$DETACHED_REMOTE_JOB"" = true ]; then mkdir -p ""`$JOB_DIR""; : > ""`$JOB_LOG""; exec >>""`$JOB_LOG"" 2>&1; fi",
        "finish_job() { rc=""`$1""; if [ ""`$DETACHED_REMOTE_JOB"" = true ]; then printf '%s\n' ""`$rc"" > ""`$JOB_EXIT_CODE""; touch ""`$JOB_DONE""; fi; exit ""`$rc""; }",
        "run_stage() { label=""`$1""; shift; printf '[remote-egress] %s\n' ""`$label""; ""`$@""; rc=""`$?""; if [ ""`$rc"" -ne 0 ]; then printf '[remote-egress] failed: %s (rc=%s)\n' ""`$label"" ""`$rc""; finish_job ""`$rc""; fi; }",
        "REMOTE_REPO=$(Quote-BashArg $RemoteRepoDir)",
        "BUNDLE_DIR=$(Quote-BashArg $remoteBundleDir)",
        "RESULT_ARCHIVE=$(Quote-BashArg $remoteResultArchive)",
        "printf '%s\n' '[remote-egress] preparing repository snapshot'",
        "run_stage 'prepare repo directories' sudo mkdir -p ""`$REMOTE_REPO/tools"" ""`$REMOTE_REPO/operator""",
        "run_stage 'remove previous egress policy tools' sudo rm -rf ""`$REMOTE_REPO/tools/egress_policy""",
        "run_stage 'install egress policy tools' sudo cp -a ""`$BUNDLE_DIR/tools/egress_policy"" ""`$REMOTE_REPO/tools/egress_policy""",
        "run_stage 'install operator nodes.csv' sudo install -m 600 ""`$BUNDLE_DIR/operator/nodes.csv"" ""`$REMOTE_REPO/operator/nodes.csv""",
        "run_stage 'install operator state.csv' sudo install -m 600 ""`$BUNDLE_DIR/operator/state.csv"" ""`$REMOTE_REPO/operator/state.csv""",
        "run_stage 'install operator networks.csv' sudo install -m 600 ""`$BUNDLE_DIR/operator/networks.csv"" ""`$REMOTE_REPO/operator/networks.csv""",
        "if [ -d ""`$BUNDLE_DIR/operator/egress_policy"" ]; then run_stage 'remove previous operator egress_policy artifacts' sudo rm -rf ""`$REMOTE_REPO/operator/egress_policy""; run_stage 'sync operator egress_policy artifacts' sudo cp -a ""`$BUNDLE_DIR/operator/egress_policy"" ""`$REMOTE_REPO/operator/egress_policy""; fi",
        "if [ -d ""`$BUNDLE_DIR/operator/softether"" ]; then run_stage 'remove previous operator softether config' sudo rm -rf ""`$REMOTE_REPO/operator/softether""; run_stage 'sync operator softether config' sudo cp -a ""`$BUNDLE_DIR/operator/softether"" ""`$REMOTE_REPO/operator/softether""; fi",
        "command -v ssh-keygen >/dev/null 2>&1 || { echo '[ERROR] ssh-keygen not found on orchestration node' >&2; finish_job 1; }",
        "for key in ""`$BUNDLE_DIR""/operator/*/admin_key; do",
        "  [ -f ""`$key"" ] || continue",
        "  alias_name=""`$(basename ""`$(dirname ""`$key"")"")""",
        "  chmod 600 ""`$key""",
        "  ssh-keygen -y -f ""`$key"" >/dev/null || { echo ""[ERROR] invalid admin_key for `$alias_name in remote egress bundle"" >&2; finish_job 1; }",
        "  run_stage ""prepare operator `$alias_name key directory"" sudo mkdir -p ""`$REMOTE_REPO/operator/`$alias_name""",
        "  run_stage ""install operator `$alias_name admin_key"" sudo install -m 600 ""`$key"" ""`$REMOTE_REPO/operator/`$alias_name/admin_key""",
        "done",
        "run_stage 'fix repository ownership' sudo chown -R root:root ""`$REMOTE_REPO/tools/egress_policy"" ""`$REMOTE_REPO/operator""",
        "run_stage 'fix PowerShell tool permissions' sudo find ""`$REMOTE_REPO/tools/egress_policy"" -type f -name '*.ps1' -exec chmod 700 {} +",
        "printf '%s\n' '[remote-egress] running command on orchestration node'",
        "printf '%s\n' $(Quote-BashArg "[remote-egress] exec: $remoteDisplayCommand")",
        "sudo bash -lc $(Quote-BashArg $remoteCommand)",
        "rc=`$?",
        "printf '%s\n' '[remote-egress] collecting egress policy artifacts'",
        "existing=()",
        "for path in $resultPaths; do sudo test -e ""`$REMOTE_REPO/`$path"" && existing+=(""`$path""); done",
        "if [ ""`${#existing[@]}"" -gt 0 ]; then sudo tar -czf ""`$RESULT_ARCHIVE"" -C ""`$REMOTE_REPO"" ""`${existing[@]}""; else sudo tar -czf ""`$RESULT_ARCHIVE"" --files-from /dev/null; fi",
        "archive_rc=`$?",
        "if [ ""`$archive_rc"" -ne 0 ]; then finish_job ""`$archive_rc""; fi",
        "sudo chown $(Quote-BashArg $SshUser) ""`$RESULT_ARCHIVE""",
        "finish_job ""`$rc"""
    )
    Write-LfScript $runScriptPath $runScriptLines

    Write-Host "[remote-egress] preparing temporary directory on orchestration node"
    $mkdirCommand = "mkdir -p $(Quote-BashArg $remoteBundleDir)"
    Invoke-ExternalRetrySshTransport $script:SshExecutablePath ($sshCommonArgs + @($remote, $mkdirCommand)) "prepare remote egress bundle directory" $RemoteTransferAttempts $RemoteTransferRetryDelaySeconds
    Write-Host "[remote-egress] uploading operator/tools bundle"
    Invoke-ExternalRetrySshTransport $script:ScpExecutablePath ($scpCommonArgs + @($bundle.ArchivePath, "${remote}:$remoteBundleArchive")) "upload egress policy bundle" $RemoteTransferAttempts $RemoteTransferRetryDelaySeconds
    Write-Host "[remote-egress] extracting operator/tools bundle"
    Invoke-ExternalRetrySshTransport $script:SshExecutablePath ($sshCommonArgs + @($remote, "tar -xzf $(Quote-BashArg $remoteBundleArchive) -C $(Quote-BashArg $remoteBundleDir)")) "extract remote egress policy bundle" $RemoteTransferAttempts $RemoteTransferRetryDelaySeconds
    $remoteRunnerPath = if ($useDetachedRemoteJob) { $remoteJobScript } else { $remoteRunScript }
    if ($useDetachedRemoteJob) {
        Write-Host "[remote-egress] preparing remote job directory"
        Invoke-ExternalRetrySshTransport $script:SshExecutablePath ($sshCommonArgs + @($remote, "mkdir -p $(Quote-BashArg $remoteJobDir)")) "prepare remote egress job directory" $RemoteTransferAttempts $RemoteTransferRetryDelaySeconds
    }
    Write-Host "[remote-egress] uploading remote runner"
    Invoke-ExternalRetrySshTransport $script:ScpExecutablePath ($scpCommonArgs + @($runScriptPath, "${remote}:$remoteRunnerPath")) "upload egress policy runner" $RemoteTransferAttempts $RemoteTransferRetryDelaySeconds
    Write-Host "[remote-egress] starting remote runner"
    if ($useDetachedRemoteJob) {
        Save-RemoteEgressJobState ([ordered]@{
            job_id = $remoteJobId
            created_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            control_alias = $controlNode.current_alias
            control_role = $ControlRole
            remote = $remote
            command = $Command
            command_args = $CommandArgs
            remote_repo_dir = $RemoteRepoDir
            remote_job_dir = $remoteJobDir
            remote_run_script = $remoteJobScript
            remote_log = $remoteJobLog
            remote_pid = $remoteJobPid
            remote_exit_code = $remoteJobExitCode
            remote_done = $remoteJobDone
            remote_bundle_dir = $remoteBundleDir
            remote_bundle_archive = $remoteBundleArchive
            remote_result_archive = $remoteResultArchive
        })
        $startCommand = "nohup bash $(Quote-BashArg $remoteJobScript) </dev/null >/dev/null 2>&1 & echo `$! > $(Quote-BashArg $remoteJobPid)"
        Invoke-ExternalRetrySshTransport $script:SshExecutablePath ($sshCommonArgs + @($remote, $startCommand)) "start detached egress policy runner" $RemoteTransferAttempts $RemoteTransferRetryDelaySeconds
        $jobResult = Wait-RemoteEgressJob $script:SshExecutablePath $sshCommonArgs $remote $remoteJobLog $remoteJobDone $remoteJobExitCode $RemoteJobPollSeconds $RemoteJobReconnectAttempts $RemoteJobHeartbeatSeconds
        $remoteExitCode = $jobResult.ExitCode
    } else {
        & $script:SshExecutablePath @($sshCommonArgs + @($remote, "bash $(Quote-BashArg $remoteRunScript)"))
        $remoteExitCode = $LASTEXITCODE
    }

    if ($remoteExitCode -ne 0) {
        if ($useDetachedRemoteJob) {
            Fail "remote egress policy command failed with exit code $remoteExitCode. Remote log preserved: $remoteJobLog"
        }
        Fail "remote egress policy command failed with exit code $remoteExitCode"
    }
    Download-RemoteEgressArtifacts $remoteResultArchive
    if ($useDetachedRemoteJob -and -not $KeepRemoteJob) {
        $cleanupJobCommand = "rm -rf $(Quote-BashArg $remoteJobDir)"
        & $script:SshExecutablePath @($sshCommonArgs + @($remote, $cleanupJobCommand)) *> $null
    }
    Write-Host "[OK] Remote egress policy command completed"
} finally {
    Remove-Item -LiteralPath $runScriptPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $downloadArchivePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $downloadExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($bundle) {
        Remove-Item -LiteralPath $bundle.ArchivePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $bundle.StagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($script:SshExecutablePath -and $remoteBundleDir -and $remote) {
        $cleanupCommand = "rm -rf $(Quote-BashArg $remoteBundleDir) $(Quote-BashArg $remoteBundleArchive) $(Quote-BashArg $remoteResultArchive)"
        & $script:SshExecutablePath @($sshCommonArgs + @($remote, $cleanupCommand)) *> $null
    }
}
