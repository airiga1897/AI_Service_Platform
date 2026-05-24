param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Service,

    [Parameter(Mandatory=$true, Position=1)]
    [ValidateSet("plan", "apply", "absent", "purge")]
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

    [switch]$ConfirmPurge
)

$ErrorActionPreference = "Stop"
$ExpectedHeader = "current_alias,endpoint,connection,root_password"
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
Require-File $ServiceRunnerScript "ServiceRunnerScript"
if (-not (Test-Path -LiteralPath $AnsibleDir -PathType Container)) {
    Fail "AnsibleDir not found: $AnsibleDir"
}

$remote = "$SshUser@$($controlNode.endpoint)"
$remoteBundleDir = "/tmp/ai-service-platform.service-remote.$([guid]::NewGuid().ToString('N'))"
$remoteBundleArchive = "$remoteBundleDir.tar.gz"
$remoteServiceRunnerTemp = "$remoteBundleDir/service.sh"
$remoteAnsibleTemp = "$remoteBundleDir/ansible"
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
    "bash tools/services/service.sh $($remoteArgs -join ' ')"
) -join "; "
$installAndRunCommand = @(
    "set -e",
    "sudo mkdir -p $(Quote-BashArg "$RemoteRepoDir/tools/services") $(Quote-BashArg "$RemoteRepoDir/infra")",
    "sudo install -m 700 $(Quote-BashArg $remoteServiceRunnerTemp) $(Quote-BashArg "$RemoteRepoDir/tools/services/service.sh")",
    "sudo rm -rf $(Quote-BashArg "$RemoteRepoDir/infra/ansible")",
    "sudo cp -a $(Quote-BashArg $remoteAnsibleTemp) $(Quote-BashArg "$RemoteRepoDir/infra/ansible")",
    "sudo bash -lc $(Quote-BashArg $serviceCommand)",
    "rm -rf $(Quote-BashArg $remoteBundleDir)"
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
$sshRunArgs = $sshCommonArgs + @(
    $remote,
    $installAndRunCommand
)

try {
    Write-Host "Preparing local service bundle..."
    $bundle = New-TarGzBundle $ServiceRunnerScript $AnsibleDir

    Write-Host "Creating remote temporary bundle directory..."
    Invoke-ExternalRetryTransport "ssh" ($sshCommonArgs + @(
        $remote,
        "mkdir -p $(Quote-BashArg $remoteBundleDir)"
    )) "remote service bundle directory creation"

    Write-Host "Uploading service bundle archive..."
    Invoke-External "scp" ($scpCommonArgs + @(
        $bundle.ArchivePath,
        "${remote}:$remoteBundleArchive"
    )) "service bundle upload"

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

    Write-Host "Installing service bundle and running remote service command..."
    Invoke-External "ssh" $sshRunArgs "remote service command"
} finally {
    if ($bundle) {
        Remove-Item -LiteralPath $bundle.ArchivePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $bundle.StagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Cleaning remote temporary service bundle..."
    if ($remote -and $remoteBundleDir -and $remoteBundleArchive -and $sshCommonArgs) {
        Invoke-CleanupSsh ($sshCommonArgs + @(
            $remote,
            "rm -rf $(Quote-BashArg $remoteBundleDir) $(Quote-BashArg $remoteBundleArchive)"
        )) "remote service bundle cleanup"
    }
}
