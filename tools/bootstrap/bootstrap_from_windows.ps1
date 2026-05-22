param(
    [Parameter(Mandatory=$true)]
    [string]$NodesFile,

    [string]$StateFile = "",

    [Parameter(Mandatory=$true)]
    [string]$Alias,

    [string]$SetupScript = "tools/bootstrap/setup_vps.sh",

    [string]$CreateInventoryScript = "tools/bootstrap/create_inventory.sh",

    [string]$PrepareInventoryScript = "tools/bootstrap/prepare_vps3_inventory.sh",

    [string]$AnsibleAuthorizedKeyFile,

    [string]$OperatorDir = ".\operator",

    [string]$OutputAnsibleAuthorizedKeyFile = ".\operator\ansible_control.managed_nodes.pub",

    [switch]$Force,

    [switch]$RegenerateRemoteKeys
)

$ErrorActionPreference = "Stop"
$ExpectedHeader = "current_alias,endpoint,connection,ansible_group,roles,root_password"
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

function Has-Role($Roles, $Role) {
    return ("+$Roles+").Contains("+$Role+")
}

function Is-ManagementNode($Roles) {
    return (Has-Role $Roles "management") -or (Has-Role $Roles "orchestration")
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

        $fields = $line -split ",", 6
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

    Set-Content -LiteralPath $Path -Value $updated -Encoding ascii
    Write-Host "Cleared root_password in local nodes.csv for $AliasToClear"
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

function Invoke-PlinkCommand($Remote, $Password, $Command, $LogPath) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $script:ErrorActionPreference = "Continue"
        & plink -batch -pw $Password $Remote $Command 2>&1 | ForEach-Object {
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

$rows = Import-Csv -LiteralPath $NodesFile
$row = $rows | Where-Object { $_.current_alias -eq $Alias } | Select-Object -First 1
if (-not $row) {
    Fail "Alias not found in nodes file: $Alias"
}
if ($row.connection -eq "local" -or $row.endpoint -eq "local") {
    Fail "Cannot bootstrap remote VPS with endpoint=local: $Alias. For first bootstrap from Windows, set endpoint to the VPS public DNS/IP and connection=ssh. Use local only later in the VPS3 inventory CSV if needed."
}
if (-not $row.root_password) {
    Fail "root_password is required for first remote bootstrap from Windows runner: $Alias"
}
if (-not (Has-Role $row.roles "management") -and -not (Has-Role $row.roles "orchestration") -and -not $AnsibleAuthorizedKeyFile) {
    Fail "Managed node $Alias requires -AnsibleAuthorizedKeyFile"
}

$isManagementNode = Is-ManagementNode $row.roles
if ($isManagementNode) {
    Require-File $CreateInventoryScript "CreateInventoryScript"
    Require-File $PrepareInventoryScript "PrepareInventoryScript"
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
        Add-Content -LiteralPath $sanitized -Value ("{0},{1},{2},{3},{4}," -f $item.current_alias,$item.endpoint,$item.connection,$item.ansible_group,$item.roles) -Encoding ascii
    }

    $remote = "root@$($row.endpoint)"
    Write-Host "Bootstrapping $Alias at $($row.endpoint)"

    Write-Host "Step 1/4: copy setup_vps.sh"
    & pscp -pw $row.root_password $SetupScript "${remote}:/tmp/setup_vps.sh"
    if ($LASTEXITCODE -ne 0) { Fail "pscp setup_vps.sh failed" }

    Write-Host "Step 2/4: copy sanitized nodes.csv"
    & pscp -pw $row.root_password $sanitized "${remote}:/tmp/nodes.csv"
    if ($LASTEXITCODE -ne 0) { Fail "pscp sanitized nodes.csv failed" }

    if ($StateFile) {
        Write-Host "Step 2a/4: copy state.csv"
        & pscp -pw $row.root_password $StateFile "${remote}:/tmp/state.csv"
        if ($LASTEXITCODE -ne 0) { Fail "pscp state.csv failed" }
    }

    if ($isManagementNode) {
        Write-Host "Step 2b/4: copy control inventory helpers"
        & pscp -pw $row.root_password $CreateInventoryScript "${remote}:/tmp/create_inventory.sh"
        if ($LASTEXITCODE -ne 0) { Fail "pscp create_inventory.sh failed" }
        & pscp -pw $row.root_password $PrepareInventoryScript "${remote}:/tmp/prepare_vps3_inventory.sh"
        if ($LASTEXITCODE -ne 0) { Fail "pscp prepare_vps3_inventory.sh failed" }
    }

    if ($AnsibleAuthorizedKeyFile) {
        Write-Host "Step 2c/4: copy Ansible control public key"
        & pscp -pw $row.root_password $AnsibleAuthorizedKeyFile "${remote}:/tmp/ansible_control.managed_nodes.pub"
        if ($LASTEXITCODE -ne 0) { Fail "pscp Ansible public key failed" }
    }

    if ($AnsibleAuthorizedKeyFile) {
        $setupCommand = "ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash /tmp/setup_vps.sh --nodes-file /tmp/nodes.csv --alias '$Alias'"
    } else {
        $setupCommand = "bash /tmp/setup_vps.sh --nodes-file /tmp/nodes.csv --alias '$Alias'"
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
        $prepareInventoryCommand = "if [ `$rc -eq 0 ]; then mkdir -p /opt/ai-service-platform/tools/bootstrap; install -m 700 /tmp/create_inventory.sh /opt/ai-service-platform/tools/bootstrap/create_inventory.sh; install -m 700 /tmp/prepare_vps3_inventory.sh /opt/ai-service-platform/tools/bootstrap/prepare_vps3_inventory.sh; bash /opt/ai-service-platform/tools/bootstrap/prepare_vps3_inventory.sh --source-nodes-file /tmp/nodes.csv $stateArg --skip-check; fi"
        $emitKeyCommand = "if [ `$rc -eq 0 ]; then echo $PublicKeyBeginMarker; cat /home/ansible/.ssh/ansible_control.managed_nodes.pub; echo $PublicKeyEndMarker; fi"
    } else {
        $prepareInventoryCommand = ":"
        $emitKeyCommand = ":"
    }
    $remoteCommand = "set +e; $setupCommand; rc=`$?; $prepareInventoryCommand; $emitKeyCommand; rm -f /tmp/setup_vps.sh /tmp/nodes.csv /tmp/state.csv /tmp/ansible_control.managed_nodes.pub /tmp/create_inventory.sh /tmp/prepare_vps3_inventory.sh; exit `$rc"

    Write-Host "Step 3/4: run remote bootstrap"
    Write-Host "Expected next output: AI Service Platform VPS bootstrap"
    Write-Host "If this step stays silent for a long time, check PuTTY/plink host key cache, SSH banner prompts, and root password auth."
    $plinkResult = Invoke-PlinkCommand $remote $row.root_password $remoteCommand $remoteLog
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
