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

    [string]$OutputAnsibleAuthorizedKeyFile = ".\operator\ansible_control.managed_nodes.pub",

    [switch]$Force,

    [switch]$AutoAcceptHostKey,

    [switch]$RegenerateRemoteKeys
)

$ErrorActionPreference = "Stop"
$ExpectedHeader = "current_alias,endpoint,connection,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$PublicKeyBeginMarker = "__ANSIBLE_CONTROL_PUBLIC_KEY_BEGIN__"
$PublicKeyEndMarker = "__ANSIBLE_CONTROL_PUBLIC_KEY_END__"

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

        $fields = $line -split ",", 5
        if ($fields.Count -ne 4) {
            Fail "nodes.csv row has invalid column count: $line"
        }

        if ($fields[0] -eq $AliasToClear) {
            $fields[3] = ""
            $foundAlias = $true
        }
        $updated.Add(($fields -join ","))
    }

    if (-not $foundAlias) {
        Fail "Alias not found while clearing root_password: $AliasToClear"
    }

    Set-Content -LiteralPath $Path -Value $updated -Encoding ascii
    Write-Host "Cleared root_password in local nodes.csv for $AliasToClear"
}

function Split-AliasList($Value) {
    if (-not $Value) { return @() }
    return @($Value -split "\+" | Where-Object { $_ })
}

function Is-ActiveOrchestrationNode($StateRows, $AliasToCheck) {
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
    return ($activeAliases[0] -eq $AliasToCheck)
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

function Save-TextFile($Path, $Lines, $AllowOverwrite) {
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $AllowOverwrite) {
        Fail "Output key file already exists: $Path. Use -Force to overwrite it."
    }

    $outputDir = Split-Path -Parent $Path
    if ($outputDir) {
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    }
    Set-Content -LiteralPath $Path -Value $Lines -Encoding ascii
}

function Assert-OutputKeyPathAvailable($Path, $AllowOverwrite) {
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $AllowOverwrite) {
        Fail "Output key file already exists: $Path. Use -Force to overwrite it."
    }
}

function Assert-BootstrapKeyPathsAvailable($AliasToSave, $IsManagement, $BaseOperatorDir, $PublicKeyPath, $AllowOverwrite) {
    $aliasDir = Join-Path $BaseOperatorDir $AliasToSave

    Assert-OutputKeyPathAvailable (Join-Path $aliasDir "deploy_key") $AllowOverwrite
    Assert-OutputKeyPathAvailable (Join-Path $aliasDir "admin_key") $AllowOverwrite

    if ($IsManagement) {
        Assert-OutputKeyPathAvailable (Join-Path $aliasDir "ansible_control_key") $AllowOverwrite
        Assert-OutputKeyPathAvailable (Join-Path $aliasDir "ansible_control.managed_nodes.pub") $AllowOverwrite
        Assert-OutputKeyPathAvailable $PublicKeyPath $AllowOverwrite
    }
}

function Save-BootstrapKeys($Lines, $AliasToSave, $IsManagement, $BaseOperatorDir, $PublicKeyPath, $AllowOverwrite) {
    $aliasDir = Join-Path $BaseOperatorDir $AliasToSave
    New-Item -ItemType Directory -Force -Path $aliasDir | Out-Null

    $deployKey = Get-MarkedBlock $Lines "--- BEGIN SSH_KEY ---" "--- END SSH_KEY ---" "deploy private key"
    $adminKey = Get-MarkedBlock $Lines "--- BEGIN ADMIN KEY ---" "--- END ADMIN KEY ---" "admin private key"

    Save-TextFile (Join-Path $aliasDir "deploy_key") $deployKey $AllowOverwrite
    Save-TextFile (Join-Path $aliasDir "admin_key") $adminKey $AllowOverwrite
    Write-Host "Saved bootstrap keys: $aliasDir"

    if ($IsManagement) {
        $ansibleKey = Get-MarkedBlock $Lines "--- BEGIN ANSIBLE CONTROL KEY ---" "--- END ANSIBLE CONTROL KEY ---" "Ansible control private key"
        $publicKey = Get-MarkedBlock $Lines $PublicKeyBeginMarker $PublicKeyEndMarker "Ansible control public key"
        if ($publicKey.Count -ne 1) {
            Fail "Could not capture exactly one Ansible control public key from remote bootstrap output."
        }

        Save-TextFile (Join-Path $aliasDir "ansible_control_key") $ansibleKey $AllowOverwrite
        Save-TextFile (Join-Path $aliasDir "ansible_control.managed_nodes.pub") $publicKey $AllowOverwrite
        Save-TextFile $PublicKeyPath $publicKey $AllowOverwrite
        Write-Host "Saved Ansible control public key: $PublicKeyPath"
    }
}

function Get-PuttyHostKeyFingerprint($Remote, $Password) {
    if (-not $AutoAcceptHostKey) {
        return ""
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $script:ErrorActionPreference = "Continue"
        $output = & plink -batch -no-antispoof -pw $Password $Remote exit 2>&1
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

function Invoke-PlinkCommand($Remote, $Password, $Command, $LogPath, $HostKeyFingerprint) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $script:ErrorActionPreference = "Continue"
        $plinkArgs = @("-batch", "-no-antispoof", "-pw", $Password, $Remote, $Command)
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

function Invoke-PscpPassword($Password, $Source, $Target, $Label, $HostKeyFingerprint) {
    $pscpArgs = @("-pw", $Password, $Source, $Target)
    if ($HostKeyFingerprint) {
        $pscpArgs = @("-hostkey", $HostKeyFingerprint) + $pscpArgs
    }
    & pscp @pscpArgs
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label failed"
    }
}

function Clear-PuttyHostKeyCache($Endpoint) {
    if (-not $AutoAcceptHostKey) {
        return
    }

    $registryPath = "HKCU:\Software\SimonTatham\PuTTY\SshHostKeys"
    if (-not (Test-Path -LiteralPath $registryPath)) {
        return
    }

    $keyItem = Get-Item -LiteralPath $registryPath
    foreach ($property in $keyItem.GetValueNames()) {
        if ($property -like "*@*:$Endpoint") {
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

if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
    Fail "plink not found in PATH"
}
if (-not (Get-Command pscp -ErrorAction SilentlyContinue)) {
    Fail "pscp not found in PATH"
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
if (-not $row.root_password) {
    Fail "root_password is required for first remote bootstrap from Windows runner: $Alias"
}
Assert-NoUtf8Bom $SetupScript "SetupScript"
$isManagementNode = Is-ActiveOrchestrationNode $stateRows $Alias
if (-not $isManagementNode -and -not $AnsibleAuthorizedKeyFile) {
    $AnsibleAuthorizedKeyFile = Join-Path $OperatorDir "ansible_control.managed_nodes.pub"
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
Assert-BootstrapKeyPathsAvailable $Alias $isManagementNode $OperatorDir $OutputAnsibleAuthorizedKeyFile $Force

$sanitized = New-TemporaryFile
$remoteLog = New-TemporaryFile
try {
    Set-Content -LiteralPath $sanitized -Value $ExpectedHeader -Encoding ascii
    foreach ($item in $rows) {
        Add-Content -LiteralPath $sanitized -Value ("{0},{1},{2}," -f $item.current_alias,$item.endpoint,$item.connection) -Encoding ascii
    }

    $remote = "root@$($row.endpoint)"
    Write-Host "Bootstrapping $Alias at $($row.endpoint)"
    Clear-PuttyHostKeyCache $row.endpoint
    $hostKeyFingerprint = Get-PuttyHostKeyFingerprint $remote $row.root_password

    Write-Host "Step 1/4: copy setup_vps.sh"
    Invoke-PscpPassword $row.root_password $SetupScript "${remote}:/tmp/setup_vps.sh" "pscp setup_vps.sh" $hostKeyFingerprint

    Write-Host "Step 2/4: copy sanitized nodes.csv"
    Invoke-PscpPassword $row.root_password $sanitized "${remote}:/tmp/nodes.csv" "pscp sanitized nodes.csv" $hostKeyFingerprint

    if ($StateFile) {
        Write-Host "Step 2a/4: copy state.csv"
        Invoke-PscpPassword $row.root_password $StateFile "${remote}:/tmp/state.csv" "pscp state.csv" $hostKeyFingerprint
    }

    if ($isManagementNode) {
        Write-Host "Step 2b/4: copy control inventory helpers"
        Invoke-PscpPassword $row.root_password $CreateInventoryScript "${remote}:/tmp/create_inventory.sh" "pscp create_inventory.sh" $hostKeyFingerprint
        Invoke-PscpPassword $row.root_password $PrepareInventoryScript "${remote}:/tmp/prepare_orchestration_inventory.sh" "pscp prepare_orchestration_inventory.sh" $hostKeyFingerprint
        Invoke-PscpPassword $row.root_password $VerifyControlScript "${remote}:/tmp/verify_control_node.sh" "pscp verify_control_node.sh" $hostKeyFingerprint
    }

    if ($AnsibleAuthorizedKeyFile) {
        Write-Host "Step 2c/4: copy Ansible control public key"
        Invoke-PscpPassword $row.root_password $AnsibleAuthorizedKeyFile "${remote}:/tmp/ansible_control.managed_nodes.pub" "pscp Ansible public key" $hostKeyFingerprint
    }

    if ($AnsibleAuthorizedKeyFile) {
        $setupCommand = "ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash /tmp/setup_vps.sh --nodes-file /tmp/nodes.csv --state-file /tmp/state.csv --alias '$Alias'"
    } else {
        $setupCommand = "bash /tmp/setup_vps.sh --nodes-file /tmp/nodes.csv --state-file /tmp/state.csv --alias '$Alias'"
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
    $remoteCommand = "set +e; $setupCommand; rc=`$?; $prepareInventoryCommand; $emitKeyCommand; rm -f /tmp/setup_vps.sh /tmp/nodes.csv /tmp/state.csv /tmp/ansible_control.managed_nodes.pub /tmp/create_inventory.sh /tmp/prepare_orchestration_inventory.sh /tmp/verify_control_node.sh; exit `$rc"

    Write-Host "Step 3/4: run remote bootstrap"
    Write-Host "Expected next output: AI Service Platform VPS bootstrap"
    Write-Host "If this step stays silent for a long time, check PuTTY/plink host key cache, SSH banner prompts, and root password auth."
    $plinkResult = Invoke-PlinkCommand $remote $row.root_password $remoteCommand $remoteLog $hostKeyFingerprint
    $remoteOutput = Get-Content -LiteralPath $remoteLog -ErrorAction SilentlyContinue
    $remoteExitCode = $plinkResult.ExitCode
    if ($remoteExitCode -ne 0) { Fail "remote setup_vps.sh failed" }

    Write-Host "Step 4/4: save bootstrap keys"
    Save-BootstrapKeys $remoteOutput $Alias $isManagementNode $OperatorDir $OutputAnsibleAuthorizedKeyFile $Force

    Clear-RootPasswordForAlias $NodesFile $Alias
    Write-Host "Bootstrap completed for $Alias"
} finally {
    Remove-Item -LiteralPath $sanitized -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $remoteLog -Force -ErrorAction SilentlyContinue
}
