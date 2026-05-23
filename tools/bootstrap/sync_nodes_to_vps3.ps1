param(
    [string]$NodesFile = ".\operator\nodes.csv",

    [string]$StateFile = ".\operator\state.csv",

    [string]$ControlRole = "orchestration",

    [string]$ControlAlias = "",

    [string]$Vps3Alias = "",

    [string]$OperatorDir = ".\operator",

    [string]$SshUser = "useradmin",

    [string]$SshKeyFile = "",

    [string]$RemoteNodesFile = "/tmp/ai-service-platform.nodes.csv",

    [string]$SoftetherDir = ".\operator\softether",

    [string]$RemoteSoftetherDir = "/tmp/ai-service-platform.softether",

    [string]$RemotePrepareScript = "/opt/ai-service-platform/tools/bootstrap/prepare_vps3_inventory.sh",

    [string]$VerifyControlScript = "tools/bootstrap/verify_control_node.sh",

    [string]$RemoteVerifyScript = "/opt/ai-service-platform/tools/bootstrap/verify_control_node.sh",

    [string]$Include = "",

    [switch]$AutoAcceptHostKey,

    [switch]$FixKeyAcl,

    [switch]$SkipVerify
)

$ErrorActionPreference = "Stop"
$ExpectedHeader = "current_alias,endpoint,connection,ansible_group,roles,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$IsWindowsPlatform = ($PSVersionTable.PSEdition -eq "Desktop") -or ($PSVersionTable.ContainsKey("Platform") -and $PSVersionTable.Platform -eq "Win32NT") -or ($env:OS -eq "Windows_NT")

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Require-File($Path, $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Label not found: $Path"
    }
}

function New-SanitizedNodesFile($SourcePath) {
    $tempFile = (New-TemporaryFile).FullName
    Set-Content -LiteralPath $tempFile -Value $ExpectedHeader -Encoding ascii

    $lines = Get-Content -LiteralPath $SourcePath
    if (-not $lines -or $lines.Count -eq 0) {
        Fail "nodes.csv is empty: $SourcePath"
    }
    if ($lines[0] -ne $ExpectedHeader) {
        Fail "nodes.csv header must be exactly: $ExpectedHeader"
    }

    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        if (-not $line) {
            continue
        }
        $fields = $line -split ",", 6
        if ($fields.Count -ne 6) {
            Fail "nodes.csv row has invalid column count: $line"
        }
        $fields[5] = ""
        Add-Content -LiteralPath $tempFile -Value ($fields -join ",") -Encoding ascii
    }

    return $tempFile
}

function Has-Role($Roles, $Role) {
    return ("+$Roles+").Contains("+$Role+")
}

function Resolve-ControlNode($Rows, $Role, $ExplicitAlias, $DeprecatedAlias) {
    if ($DeprecatedAlias -and -not $ExplicitAlias) {
        Write-Warning "-Vps3Alias is deprecated. Use -ControlAlias instead."
        $ExplicitAlias = $DeprecatedAlias
    }

    if ($ExplicitAlias) {
        $node = $Rows | Where-Object { $_.current_alias -eq $ExplicitAlias } | Select-Object -First 1
        if (-not $node) {
            Fail "Control alias not found in nodes file: $ExplicitAlias"
        }
        if (-not (Has-Role $node.roles $Role)) {
            Fail "Control alias $ExplicitAlias does not have required role: $Role"
        }
        return $node
    }

    $matches = @($Rows | Where-Object { Has-Role $_.roles $Role })
    if ($matches.Count -eq 0) {
        Fail "No control node found: nodes.csv must contain exactly one row with role '$Role', or pass -ControlAlias."
    }
    if ($matches.Count -gt 1) {
        $aliases = ($matches | ForEach-Object { $_.current_alias }) -join ", "
        Fail "Multiple control nodes found for role '$Role': $aliases. Pass -ControlAlias to choose one explicitly."
    }

    return $matches[0]
}

function Split-AliasList($Value) {
    if (-not $Value) {
        return @()
    }
    return @($Value -split "\+" | Where-Object { $_ })
}

function Resolve-ControlNodeFromState($NodeRows, $StateRows, $Role, $ExplicitAlias, $DeprecatedAlias) {
    if ($DeprecatedAlias -and -not $ExplicitAlias) {
        Write-Warning "-Vps3Alias is deprecated. Use -ControlAlias instead."
        $ExplicitAlias = $DeprecatedAlias
    }

    $roleRows = @($StateRows | Where-Object { $_.kind -eq "role" -and $_.name -eq $Role -and $_.state -eq "present" })
    if ($roleRows.Count -eq 0) {
        Fail "No active control role found in state.csv: kind=role,name=$Role,state=present"
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
    if ($activeAliases.Count -eq 0) {
        Fail "Control role '$Role' must have exactly one active_aliases value in state.csv."
    }
    if ($activeAliases.Count -gt 1) {
        Fail "Control role '$Role' has multiple active aliases in state.csv: $($activeAliases -join ', '). Keep one active alias and put reserve nodes in candidate_aliases."
    }

    $node = $NodeRows | Where-Object { $_.current_alias -eq $activeAliases[0] } | Select-Object -First 1
    if (-not $node) {
        Fail "Control alias from state.csv not found in nodes.csv: $($activeAliases[0])"
    }
    return $node
}

Require-File $NodesFile "NodesFile"
if (-not $SkipVerify) {
    Require-File $VerifyControlScript "VerifyControlScript"
}

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Fail "ssh not found in PATH. Install Windows OpenSSH Client or fix PATH."
}
if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
    Fail "scp not found in PATH. Install Windows OpenSSH Client or fix PATH."
}
if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    Fail "ssh-keygen not found in PATH. Install Windows OpenSSH Client or fix PATH."
}

try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $sshVersion = (& ssh -V 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ($sshVersion -notmatch "OpenSSH") {
    Fail "ssh in PATH does not look like OpenSSH. Output:`n$sshVersion"
}

$firstLine = Get-Content -LiteralPath $NodesFile -TotalCount 1
if ($firstLine -ne $ExpectedHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedHeader"
}

$rows = Import-Csv -LiteralPath $NodesFile
$useStateFile = $false
if ($StateFile -and (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
    $stateFirstLine = Get-Content -LiteralPath $StateFile -TotalCount 1
    if ($stateFirstLine -ne $ExpectedStateHeader) {
        Fail "state.csv header must be exactly: $ExpectedStateHeader"
    }
    $stateRows = Import-Csv -LiteralPath $StateFile
    $controlNode = Resolve-ControlNodeFromState $rows $stateRows $ControlRole $ControlAlias $Vps3Alias
    $useStateFile = $true
} else {
    $controlNode = Resolve-ControlNode $rows $ControlRole $ControlAlias $Vps3Alias
}
if ($controlNode.endpoint -eq "local" -or $controlNode.connection -eq "local") {
    Fail "Cannot sync to control node when endpoint/connection is local in operator nodes.csv: $($controlNode.current_alias)"
}

if (-not $SshKeyFile) {
    $SshKeyFile = Join-Path (Join-Path $OperatorDir $controlNode.current_alias) "admin_key"
}
Require-File $SshKeyFile "SshKeyFile"
if (-not $Include) {
    $Include = ($rows | Where-Object { $_.current_alias } | ForEach-Object { $_.current_alias }) -join ","
}

$sanitized = New-SanitizedNodesFile $NodesFile
$remoteVerifyTemp = "/tmp/ai-service-platform.verify_control_node.sh"
$remote = "$SshUser@$($controlNode.endpoint)"

function Test-PrivateKeyAcl($KeyFile) {
    $broadPrincipalSids = @(
        "S-1-1-0",       # Everyone
        "S-1-5-11",      # Authenticated Users
        "S-1-5-32-545"   # BUILTIN\Users
    )
    $acl = Get-Acl -LiteralPath $KeyFile
    $badEntries = @()
    foreach ($entry in $acl.Access) {
        $identity = [string]$entry.IdentityReference
        $sid = ""
        try {
            $sid = $entry.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        } catch {
            $sid = ""
        }
        $hasRead = (($entry.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Read) -ne 0) -or
            (($entry.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::ReadData) -ne 0) -or
            (($entry.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne 0)
        if ($entry.AccessControlType -eq "Allow" -and $hasRead -and ($broadPrincipalSids -contains $sid)) {
            $badEntries += $identity
        }
    }
    return @($badEntries | Select-Object -Unique)
}

function Repair-PrivateKeyAcl($KeyFile) {
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Host "Fixing OpenSSH private key ACL for $KeyFile"
    & icacls $KeyFile "/inheritance:r" | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Fail "icacls failed to disable inheritance for $KeyFile"
    }
    & icacls $KeyFile "/grant:r" "$currentUser`:R" | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Fail "icacls failed to grant read access to $currentUser for $KeyFile"
    }
}

function Ensure-PrivateKeyAcl($KeyFile) {
    if (-not $IsWindowsPlatform) {
        return
    }

    $badEntries = Test-PrivateKeyAcl $KeyFile
    if ($badEntries.Count -eq 0) {
        return
    }

    $badText = $badEntries -join ", "
    Write-Warning "OpenSSH private key ACL is too open for $KeyFile. Broad readable entries: $badText. Fixing automatically."
    Repair-PrivateKeyAcl $KeyFile
    $remainingBadEntries = Test-PrivateKeyAcl $KeyFile
    if ($remainingBadEntries.Count -gt 0) {
        Fail "OpenSSH private key ACL is still too open after automatic repair: $($remainingBadEntries -join ', ')"
    }
}

function Get-SshCommonArgs($KeyFile) {
    $args = @("-i", $KeyFile, "-o", "IdentitiesOnly=yes")
    if ($AutoAcceptHostKey) {
        $args += @("-o", "StrictHostKeyChecking=accept-new")
    }
    return $args
}

function Invoke-ScpKey($KeyFile, $Source, $Target, $Label) {
    $scpArgs = @(Get-SshCommonArgs $KeyFile) + @($Source, $Target)
    & scp @scpArgs
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label failed"
    }
}

function Invoke-ScpKeyRecursive($KeyFile, $Source, $Target, $Label) {
    $scpArgs = @("-r") + @(Get-SshCommonArgs $KeyFile) + @($Source, $Target)
    & scp @scpArgs
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label failed"
    }
}

function Invoke-SshKey($KeyFile, $Remote, $Command, $Label) {
    $sshArgs = @(Get-SshCommonArgs $KeyFile) + @($Remote, $Command)
    & ssh @sshArgs
    if ($LASTEXITCODE -ne 0) {
        Fail "$Label failed"
    }
}

function Clear-OpenSshHostKey($Endpoint) {
    if (-not $AutoAcceptHostKey) {
        return
    }

    Write-Host "Removing old OpenSSH known_hosts entries for $Endpoint"
    & ssh-keygen -R $Endpoint | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Fail "ssh-keygen -R failed for $Endpoint"
    }
}

Ensure-PrivateKeyAcl $SshKeyFile
Clear-OpenSshHostKey $controlNode.endpoint

try {
    Write-Host "Syncing sanitized nodes.csv to control node $($controlNode.current_alias) at $remote"
    Invoke-ScpKey $SshKeyFile $sanitized "${remote}:$RemoteNodesFile" "scp sanitized nodes.csv"

    $remoteStateFile = "/tmp/ai-service-platform.state.csv"
    if ($useStateFile) {
        Write-Host "Syncing state.csv to control node $($controlNode.current_alias)"
        Invoke-ScpKey $SshKeyFile $StateFile "${remote}:$remoteStateFile" "scp state.csv"
    }

    $syncSoftether = Test-Path -LiteralPath $SoftetherDir -PathType Container
    if ($syncSoftether) {
        Write-Host "Syncing SoftEther operator secret directory to control node $($controlNode.current_alias)"
        Invoke-SshKey $SshKeyFile $remote "rm -rf '$RemoteSoftetherDir'" "remote cleanup SoftEther temp dir"
        Invoke-ScpKeyRecursive $SshKeyFile $SoftetherDir "${remote}:$RemoteSoftetherDir" "scp SoftEther operator directory"
    }
    if (-not $SkipVerify) {
        Write-Host "Syncing verify_control_node.sh to control node $($controlNode.current_alias)"
        Invoke-ScpKey $SshKeyFile $VerifyControlScript "${remote}:$remoteVerifyTemp" "scp verify_control_node.sh"
    }

    $prepareCommand = "sudo bash '$RemotePrepareScript' --source-nodes-file '$RemoteNodesFile' --skip-check"
    if ($useStateFile) {
        $prepareCommand = "$prepareCommand --source-state-file '$remoteStateFile'"
    }
    if ($Include) {
        $prepareCommand = "$prepareCommand --include '$Include'"
    }
    $softetherCommand = ""
    if ($syncSoftether) {
        $softetherCommand = "sudo mkdir -p /opt/ai-service-platform/operator; if [ -d '$RemoteSoftetherDir/softether' ]; then sudo rm -rf /opt/ai-service-platform/operator/softether && sudo cp -a '$RemoteSoftetherDir/softether' /opt/ai-service-platform/operator/softether; else sudo rm -rf /opt/ai-service-platform/operator/softether && sudo cp -a '$RemoteSoftetherDir' /opt/ai-service-platform/operator/softether; fi;"
    }
    $verifyCommand = ""
    if (-not $SkipVerify) {
        $verifyCommand = "sudo mkdir -p `"`$(dirname '$RemoteVerifyScript')`"; sudo install -m 700 '$remoteVerifyTemp' '$RemoteVerifyScript'; sudo bash '$RemoteVerifyScript';"
    }
    $remoteCommand = "set -e; $softetherCommand $prepareCommand; $verifyCommand rm -rf '$RemoteSoftetherDir'; rm -f '$RemoteNodesFile' '$remoteStateFile' '$remoteVerifyTemp'"

    Write-Host "Running control node inventory preparation"
    Invoke-SshKey $SshKeyFile $remote $remoteCommand "remote prepare_vps3_inventory.sh"

    if ($SkipVerify) {
        Write-Host "Control node nodes.csv and inventory.ini are in sync; verify skipped"
    } else {
        Write-Host "Control node nodes.csv, inventory.ini, and verification are complete"
    }
} finally {
    Remove-Item -LiteralPath $sanitized -Force -ErrorAction SilentlyContinue
}
