param(
    [string]$NodesFile = ".\operator\nodes.csv",

    [string]$StateFile = ".\operator\state.csv",

    [string]$ControlRole = "orchestration",

    [string]$ControlAlias = "",

    [string[]]$ManagedAliases = @(),

    [string]$OperatorDir = ".\operator",

    [string]$AdminUser = "useradmin",

    [string]$BootstrapRunner = "tools/bootstrap/bootstrap_from_windows.ps1",

    [string]$SyncRunner = "tools/bootstrap/sync_to_orchestration.ps1",

    [string]$BootstrapConvergeRunner = "tools/bootstrap/bootstrap_converge_remote.ps1",

    [string]$OperatorBackupScript = "tools/operator_backup/backup_operator.ps1",

    [string]$OperatorBackupDir = "D:\Backup\Projects\AI_SP\operator",

    [string]$OperatorBackupRemoteDir = "/opt/backups/ai-service-platform/operator",

    [int]$OperatorBackupKeepLatest = 30,

    [string]$AnsibleAuthorizedKeyFile = "",

    [switch]$ForceManagementKeyRefresh,

    [switch]$ForceOverwriteKeys,

    [switch]$AutoAcceptHostKey = $true,

    [switch]$FixKeyAcl,

    [switch]$RegenerateRemoteKeys,

    [switch]$SkipSync,

    [switch]$SkipVerify,

    [switch]$SkipServicePlan,

    [switch]$SkipManaged,

    [switch]$SkipExistingRebootstrap,

    [switch]$SkipBootstrapConverge,

    [switch]$UseAdminKeyFallback,

    [int]$BootstrapConvergePollSeconds = 2,

    [int]$BootstrapConvergeHeartbeatSeconds = 10,

    [switch]$SkipOperatorBackup
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

function Get-OrchestrationCapableAliases($StateRows, $Role) {
    $roleRows = @($StateRows | Where-Object { ($_.kind -eq "platform_role" -or $_.kind -eq "role") -and $_.name -eq $Role -and $_.state -eq "present" })
    if ($roleRows.Count -eq 0) {
        Fail "No active control role found in state.csv: kind=platform_role,name=$Role,state=present"
    }
    if ($roleRows.Count -gt 1) {
        Fail "Multiple state.csv rows found for control role '$Role'. Keep exactly one row."
    }

    $aliases = New-Object System.Collections.Generic.List[string]
    foreach ($alias in @(Split-AliasList $roleRows[0].active_aliases) + @(Split-AliasList $roleRows[0].candidate_aliases)) {
        if ($alias -and -not $aliases.Contains($alias)) {
            $aliases.Add($alias)
        }
    }
    return @($aliases)
}

function Get-OrchestrationCandidateAliases($StateRows, $Role) {
    $roleRows = @($StateRows | Where-Object { ($_.kind -eq "platform_role" -or $_.kind -eq "role") -and $_.name -eq $Role -and $_.state -eq "present" })
    if ($roleRows.Count -eq 0) {
        Fail "No active control role found in state.csv: kind=platform_role,name=$Role,state=present"
    }
    if ($roleRows.Count -gt 1) {
        Fail "Multiple state.csv rows found for control role '$Role'. Keep exactly one row."
    }

    $aliases = New-Object System.Collections.Generic.List[string]
    foreach ($alias in @(Split-AliasList $roleRows[0].candidate_aliases)) {
        if ($alias -and -not $aliases.Contains($alias)) {
            $aliases.Add($alias)
        }
    }
    return @($aliases)
}

function Get-StateBootstrapAliases($NodeRows, $StateRows, $ControlAliasValue, $IncludeExisting) {
    $aliases = New-Object System.Collections.Generic.List[string]

    foreach ($node in $NodeRows) {
        if ($node.current_alias -eq $ControlAliasValue) {
            continue
        }
        if ($node.connection -ne "ssh" -or $node.endpoint -eq "local") {
            continue
        }
        if (Has-RootPassword $node) {
            if (-not $aliases.Contains($node.current_alias)) {
                $aliases.Add($node.current_alias)
            }
        }
    }

    if ($IncludeExisting) {
        foreach ($row in @($StateRows | Where-Object { $_.state -eq "present" })) {
            foreach ($field in @("active_aliases", "candidate_aliases")) {
                foreach ($alias in @(Split-AliasList $row.$field)) {
                    if (-not $alias -or $alias -eq $ControlAliasValue -or $aliases.Contains($alias)) {
                        continue
                    }
                    $node = $NodeRows | Where-Object { $_.current_alias -eq $alias } | Select-Object -First 1
                    if ($node -and $node.connection -eq "ssh" -and $node.endpoint -ne "local") {
                        $aliases.Add($alias)
                    }
                }
            }
        }
    }

    return @($aliases)
}

function Invoke-ChildScript($ScriptPath, $Arguments) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        Fail "Child script failed: $ScriptPath"
    }
}

function Invoke-SyncRunner($Label, [switch]$SkipVerifyForSync, [switch]$SkipServicePlanForSync) {
    $syncArgs = @(
        "-NodesFile", $NodesFile,
        "-ControlRole", $ControlRole,
        "-ControlAlias", $controlNode.current_alias,
        "-OperatorDir", $OperatorDir
    )
    if ($useStateFile) {
        $syncArgs += @("-StateFile", $StateFile)
    }
    if ($AutoAcceptHostKey) {
        $syncArgs += "-AutoAcceptHostKey"
    }
    if ($SkipVerify -or $SkipVerifyForSync) {
        $syncArgs += "-SkipVerify"
    }
    if ($SkipServicePlan -or $SkipServicePlanForSync) {
        $syncArgs += "-SkipServicePlan"
    }
    if ($FixKeyAcl) {
        Write-Warning "-FixKeyAcl is deprecated. sync_to_orchestration.ps1 now fixes OpenSSH key ACL automatically."
    }

    Write-Host $Label
    Invoke-ChildScript $SyncRunner $syncArgs
}

function Invoke-BootstrapConverge($Aliases, $AuthorizedKeyFile) {
    if ($Aliases.Count -eq 0) {
        return
    }
    if ($SkipBootstrapConverge) {
        Write-Host "Step 3b/5: bootstrap converge skipped by -SkipBootstrapConverge for: $($Aliases -join ', ')"
        return
    }
    if ($SkipSync) {
        Fail "Bootstrap converge requires sync/inventory preparation. Remove -SkipSync or pass -SkipBootstrapConverge."
    }

    Require-File $BootstrapConvergeRunner "BootstrapConvergeRunner"
    Require-File $AuthorizedKeyFile "AnsibleAuthorizedKeyFile"
    $limit = $Aliases -join ":"
    $args = @(
        "-NodesFile", $NodesFile,
        "-StateFile", $StateFile,
        "-OperatorDir", $OperatorDir,
        "-ControlRole", $ControlRole,
        "-ControlAlias", $controlNode.current_alias,
        "-Limit", $limit,
        "-AnsibleAuthorizedKeyFile", $AuthorizedKeyFile,
        "-RemoteJobPollSeconds", $BootstrapConvergePollSeconds,
        "-RemoteJobHeartbeatSeconds", $BootstrapConvergeHeartbeatSeconds
    )

    Write-Host "Step 3b/5: bootstrap converge existing managed nodes through Ansible: $($Aliases -join ', ')"
    Invoke-ChildScript $BootstrapConvergeRunner $args
}

function Has-RootPassword($Node) {
    return -not [string]::IsNullOrWhiteSpace([string]$Node.root_password)
}

function Has-AdminKey($AliasToCheck, $BaseOperatorDir) {
    $adminKey = Join-Path (Join-Path $BaseOperatorDir $AliasToCheck) "admin_key"
    return (Test-Path -LiteralPath $adminKey -PathType Leaf)
}

function Add-PublicKeyLines($Path, $Label, $KeyLines) {
    Require-File $Path $Label
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        $keyLine = ([string]$line).Trim()
        if ($keyLine -and -not $KeyLines.Contains($keyLine)) {
            $KeyLines.Add($keyLine)
        }
    }
}

function New-AnsibleAuthorizedKeyBundle($BaseKeyFile, $BaseOperatorDir, $OrchestrationAliases) {
    $keyLines = New-Object System.Collections.Generic.List[string]
    Add-PublicKeyLines $BaseKeyFile "AnsibleAuthorizedKeyFile" $keyLines

    foreach ($alias in $OrchestrationAliases) {
        $aliasKeyFile = Join-Path (Join-Path $BaseOperatorDir $alias) "ansible_control.managed_nodes.pub"
        if (Test-Path -LiteralPath $aliasKeyFile -PathType Leaf) {
            Add-PublicKeyLines $aliasKeyFile "Orchestration Ansible public key for $alias" $keyLines
        }
    }

    if ($keyLines.Count -eq 0) {
        Fail "No Ansible authorized public keys found for managed nodes."
    }

    $bundlePath = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-service-platform.ansible-authorized-keys.{0}.pub" -f ([guid]::NewGuid().ToString("N")))
    Set-Content -LiteralPath $bundlePath -Value $keyLines -Encoding ascii
    return $bundlePath
}

function Assert-OrchestrationCandidateKeyFiles($BaseOperatorDir, $CandidateAliases, $ControlAliasValue) {
    foreach ($alias in $CandidateAliases) {
        if ($alias -eq $ControlAliasValue) {
            continue
        }

        $aliasKeyFile = Join-Path (Join-Path $BaseOperatorDir $alias) "ansible_control.managed_nodes.pub"
        if (-not (Test-Path -LiteralPath $aliasKeyFile -PathType Leaf)) {
            Fail "Orchestration candidate $alias did not produce an Ansible public key at $aliasKeyFile. Re-run bootstrap for the candidate or restore the key before bootstrapping managed nodes."
        }
    }
}

function Require-RemoteNode($Node, $Label) {
    if ($Node.connection -ne "ssh" -or $Node.endpoint -eq "local") {
        Fail "$Label $($Node.current_alias) must use connection=ssh and a real endpoint for operator bootstrap."
    }
}

Require-File $NodesFile "NodesFile"
Require-File $BootstrapRunner "BootstrapRunner"
Require-File $SyncRunner "SyncRunner"

$firstLine = Get-Content -LiteralPath $NodesFile -TotalCount 1
if ($firstLine -ne $ExpectedHeader) {
    Fail "nodes.csv header must be exactly: $ExpectedHeader"
}

if ($RegenerateRemoteKeys -and -not $ForceOverwriteKeys) {
    Fail "-RegenerateRemoteKeys requires -ForceOverwriteKeys so local operator keys are refreshed explicitly."
}

$rows = Import-Csv -LiteralPath $NodesFile
$useStateFile = $false
if (-not $StateFile -or -not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
    Fail "StateFile is required. Control/managed selection lives in state.csv."
}
$stateFirstLine = Get-Content -LiteralPath $StateFile -TotalCount 1
if ($stateFirstLine -ne $ExpectedStateHeader) {
    Fail "state.csv header must be exactly: $ExpectedStateHeader"
}
$stateRows = Import-Csv -LiteralPath $StateFile
$controlNode = Resolve-ControlNodeFromState $rows $stateRows $ControlRole $ControlAlias
$orchestrationCapableAliases = @(Get-OrchestrationCapableAliases $stateRows $ControlRole)
$orchestrationCandidateAliases = @(Get-OrchestrationCandidateAliases $stateRows $ControlRole)
$useStateFile = $true
if ($controlNode.connection -ne "ssh" -or $controlNode.endpoint -eq "local") {
    Fail "Control node $($controlNode.current_alias) must use connection=ssh and a real endpoint for operator bootstrap."
}

if (-not $AnsibleAuthorizedKeyFile) {
    $AnsibleAuthorizedKeyFile = Join-Path $OperatorDir "ansible_control.managed_nodes.pub"
}

$controlNeedsBootstrap = Has-RootPassword $controlNode
$explicitManagedAliases = ($ManagedAliases.Count -gt 0)
if ($ManagedAliases.Count -eq 0) {
    $ManagedAliases = @(Get-StateBootstrapAliases $rows $stateRows $controlNode.current_alias (-not $SkipExistingRebootstrap))
}

$freshBootstrapAliases = New-Object System.Collections.Generic.List[string]
$rebootstrapAliases = New-Object System.Collections.Generic.List[string]
$skippedExistingAliases = New-Object System.Collections.Generic.List[string]
$orchestrationBootstrapAliases = New-Object System.Collections.Generic.List[string]
$managedBootstrapAliases = New-Object System.Collections.Generic.List[string]
$managedConvergeAliases = New-Object System.Collections.Generic.List[string]
foreach ($managedAlias in $ManagedAliases) {
    $managedNode = $rows | Where-Object { $_.current_alias -eq $managedAlias } | Select-Object -First 1
    if (-not $managedNode) {
        Fail "Managed alias not found in nodes file: $managedAlias"
    }
    if ($managedNode.current_alias -eq $controlNode.current_alias) {
        Fail "Managed alias cannot be the same as control alias: $managedAlias"
    }
    Require-RemoteNode $managedNode "Managed node"
    if (Has-RootPassword $managedNode) {
        if (-not $freshBootstrapAliases.Contains($managedAlias)) {
            $freshBootstrapAliases.Add($managedAlias)
        }
    } elseif (Has-AdminKey $managedAlias $OperatorDir) {
        if (-not $rebootstrapAliases.Contains($managedAlias)) {
            $rebootstrapAliases.Add($managedAlias)
        }
    } else {
        if ($explicitManagedAliases -and $UseAdminKeyFallback) {
            Fail "Managed alias $managedAlias has empty root_password and no admin key at $(Join-Path (Join-Path $OperatorDir $managedAlias) 'admin_key'). Reinstall OS/fresh bootstrap or restore the admin key."
        }
        if (-not $skippedExistingAliases.Contains($managedAlias)) {
            $skippedExistingAliases.Add($managedAlias)
        }
    }

    if ($orchestrationCapableAliases -contains $managedAlias) {
        if (-not $orchestrationBootstrapAliases.Contains($managedAlias)) {
            $orchestrationBootstrapAliases.Add($managedAlias)
        }
    } else {
        if (-not $managedBootstrapAliases.Contains($managedAlias)) {
            $managedBootstrapAliases.Add($managedAlias)
        }
        if (-not (Has-RootPassword $managedNode) -and -not $UseAdminKeyFallback -and -not $managedConvergeAliases.Contains($managedAlias)) {
            $managedConvergeAliases.Add($managedAlias)
        }
    }
}

$needsPasswordBootstrap = $controlNeedsBootstrap -or ($freshBootstrapAliases.Count -gt 0)
if ($needsPasswordBootstrap) {
    if (-not (Get-Command plink -ErrorAction SilentlyContinue)) {
        Fail "plink not found in PATH"
    }
    if (-not (Get-Command pscp -ErrorAction SilentlyContinue)) {
        Fail "pscp not found in PATH"
    }
}
$needsAnsibleAuthorizedKey = $false
if (-not $SkipManaged) {
    foreach ($managedAlias in $managedBootstrapAliases) {
        if ($UseAdminKeyFallback -and $skippedExistingAliases.Contains($managedAlias)) {
            continue
        }
        $needsAnsibleAuthorizedKey = $true
        break
    }
}
if ($managedConvergeAliases.Count -gt 0 -and -not $UseAdminKeyFallback) {
    $needsAnsibleAuthorizedKey = $true
}
$needsAnsibleTrustBundle = (-not $SkipManaged) -and ($needsAnsibleAuthorizedKey -or $orchestrationCapableAliases.Count -gt 1)

Write-Host "Control node: $($controlNode.current_alias) via role '$ControlRole'"
if ($controlNeedsBootstrap) {
    Write-Host "Control bootstrap: pending root_password found"
} else {
    Write-Host "Control bootstrap: skipped; no root_password for $($controlNode.current_alias)"
}
if ($SkipManaged) {
    Write-Host "Managed nodes: skipped"
} elseif ($ManagedAliases.Count -eq 0) {
    Write-Host "Managed nodes: none selected"
} else {
    if ($orchestrationBootstrapAliases.Count -gt 0) {
        Write-Host "Orchestration-capable bootstrap nodes: $($orchestrationBootstrapAliases -join ', ')"
    }
    if ($managedBootstrapAliases.Count -gt 0) {
        Write-Host "Managed bootstrap nodes: $($managedBootstrapAliases -join ', ')"
    }
    if ($freshBootstrapAliases.Count -gt 0) {
        Write-Host "Fresh bootstrap nodes: $($freshBootstrapAliases -join ', ')"
    }
    if ($rebootstrapAliases.Count -gt 0) {
        if ($UseAdminKeyFallback) {
            Write-Host "Admin-key fallback re-bootstrap nodes: $($rebootstrapAliases -join ', ')"
        } else {
            Write-Host "Existing nodes selected for Ansible converge: $($rebootstrapAliases -join ', ')"
        }
    }
    if ($skippedExistingAliases.Count -gt 0) {
        if ($UseAdminKeyFallback) {
            Write-Host "Existing nodes skipped because admin_key is missing: $($skippedExistingAliases -join ', ')"
        } else {
            Write-Host "Existing nodes without admin_key selected for Ansible converge: $($skippedExistingAliases -join ', ')"
        }
    }
}

if (-not $controlNeedsBootstrap) {
    if ($ForceManagementKeyRefresh) {
        Write-Warning "-ForceManagementKeyRefresh ignored because active orchestration node $($controlNode.current_alias) has no root_password; existing control keys will be used."
    }

    $controlAdminKey = Join-Path (Join-Path $OperatorDir $controlNode.current_alias) "admin_key"
    if (-not $SkipSync) {
        Require-File $controlAdminKey "Control admin key"
        Ensure-OpenSshPrivateKeyAcl $controlAdminKey
    }
}

if ($controlNeedsBootstrap) {
    Require-RemoteNode $controlNode "Control node"
    $controlArgs = @(
        "-NodesFile", $NodesFile,
        "-Alias", $controlNode.current_alias,
        "-OperatorDir", $OperatorDir,
        "-OperatorBackupScript", $OperatorBackupScript,
        "-OperatorBackupDir", $OperatorBackupDir,
        "-OperatorBackupRemoteDir", $OperatorBackupRemoteDir,
        "-OperatorBackupKeepLatest", $OperatorBackupKeepLatest,
        "-AdminUser", $AdminUser,
        "-OutputAnsibleAuthorizedKeyFile", $AnsibleAuthorizedKeyFile
    )
    if ($useStateFile) {
        $controlArgs += @("-StateFile", $StateFile)
    }
    if ($ForceManagementKeyRefresh -or $ForceOverwriteKeys) {
        $controlArgs += "-Force"
    }
    if ($RegenerateRemoteKeys) {
        $controlArgs += "-RegenerateRemoteKeys"
    }
    if ($AutoAcceptHostKey) {
        $controlArgs += "-AutoAcceptHostKey"
    }
    if ($SkipOperatorBackup) {
        $controlArgs += "-SkipOperatorBackup"
    }

    Write-Host "Step 1/5: bootstrap control node $($controlNode.current_alias)"
    Invoke-ChildScript $BootstrapRunner $controlArgs
} else {
    Write-Host "Step 1/5: control node bootstrap skipped"
}

if ($controlNeedsBootstrap -or (-not $SkipManaged -and $needsAnsibleAuthorizedKey)) {
    Require-File $AnsibleAuthorizedKeyFile "AnsibleAuthorizedKeyFile"
}

$managedAnsibleAuthorizedKeyFile = $AnsibleAuthorizedKeyFile
$temporaryAnsibleAuthorizedKeyFile = ""

try {
if (-not $SkipManaged) {
    foreach ($managedAlias in $orchestrationBootstrapAliases) {
        $managedNode = $rows | Where-Object { $_.current_alias -eq $managedAlias } | Select-Object -First 1
        if (-not $managedNode) {
            Fail "Managed alias not found in nodes file: $managedAlias"
        }
        if ($managedNode.current_alias -eq $controlNode.current_alias) {
            Fail "Managed alias cannot be the same as control alias: $managedAlias"
        }
        if (-not (Has-RootPassword $managedNode) -and -not (Has-AdminKey $managedAlias $OperatorDir)) {
            Write-Host "Step 2a/5: skip orchestration-capable node $managedAlias; admin_key is missing"
            continue
        }

        $managedArgs = @(
            "-NodesFile", $NodesFile,
            "-Alias", $managedAlias,
            "-OperatorDir", $OperatorDir,
            "-OperatorBackupScript", $OperatorBackupScript,
            "-OperatorBackupDir", $OperatorBackupDir,
            "-OperatorBackupRemoteDir", $OperatorBackupRemoteDir,
            "-OperatorBackupKeepLatest", $OperatorBackupKeepLatest,
            "-AdminUser", $AdminUser
        )
        $candidateAnsiblePublicKeyFile = Join-Path (Join-Path $OperatorDir $managedAlias) "ansible_control.candidate.pub"
        $managedArgs += @("-OutputAnsibleAuthorizedKeyFile", $candidateAnsiblePublicKeyFile)
        if ($useStateFile) {
            $managedArgs += @("-StateFile", $StateFile)
        }
        if ($ForceOverwriteKeys) {
            $managedArgs += "-Force"
        }
        if ($RegenerateRemoteKeys) {
            $managedArgs += "-RegenerateRemoteKeys"
        }
        if ($AutoAcceptHostKey) {
            $managedArgs += "-AutoAcceptHostKey"
        }
        if ($SkipOperatorBackup) {
            $managedArgs += "-SkipOperatorBackup"
        }

        if (Has-RootPassword $managedNode) {
            Write-Host "Step 2a/5: bootstrap orchestration-capable node $managedAlias"
        } else {
            Write-Host "Step 2a/5: re-bootstrap orchestration-capable node $managedAlias through admin key"
        }
        Invoke-ChildScript $BootstrapRunner $managedArgs
    }

    if ($needsAnsibleTrustBundle) {
        Assert-OrchestrationCandidateKeyFiles $OperatorDir $orchestrationCandidateAliases $controlNode.current_alias
        Require-File $AnsibleAuthorizedKeyFile "AnsibleAuthorizedKeyFile"
        Write-Host "Step 2b/5: prepare aggregate Ansible trust bundle"
        $temporaryAnsibleAuthorizedKeyFile = New-AnsibleAuthorizedKeyBundle $AnsibleAuthorizedKeyFile $OperatorDir $orchestrationCapableAliases
        $managedAnsibleAuthorizedKeyFile = $temporaryAnsibleAuthorizedKeyFile
    }

    if ($needsAnsibleTrustBundle) {
        foreach ($managedAlias in $orchestrationCapableAliases) {
            $managedNode = $rows | Where-Object { $_.current_alias -eq $managedAlias } | Select-Object -First 1
            if (-not $managedNode) {
                Fail "Orchestration-capable alias not found in nodes file: $managedAlias"
            }
            Require-RemoteNode $managedNode "Orchestration-capable node"
            if (-not (Has-AdminKey $managedAlias $OperatorDir)) {
                Fail "Orchestration-capable alias $managedAlias has no admin key at $(Join-Path (Join-Path $OperatorDir $managedAlias) 'admin_key'). Cannot refresh orchestration trust mesh."
            }

            $managedArgs = @(
                "-NodesFile", $NodesFile,
                "-Alias", $managedAlias,
                "-OperatorDir", $OperatorDir,
                "-OperatorBackupScript", $OperatorBackupScript,
                "-OperatorBackupDir", $OperatorBackupDir,
                "-OperatorBackupRemoteDir", $OperatorBackupRemoteDir,
                "-OperatorBackupKeepLatest", $OperatorBackupKeepLatest,
                "-AdminUser", $AdminUser,
                "-AnsibleAuthorizedKeyFile", $managedAnsibleAuthorizedKeyFile
            )
            if ($useStateFile) {
                $managedArgs += @("-StateFile", $StateFile)
            }
            if ($AutoAcceptHostKey) {
                $managedArgs += "-AutoAcceptHostKey"
            }
            if ($SkipOperatorBackup) {
                $managedArgs += "-SkipOperatorBackup"
            }

            Write-Host "Step 2c/5: refresh orchestration trust mesh on $managedAlias"
            Invoke-ChildScript $BootstrapRunner $managedArgs
        }
    }

    foreach ($managedAlias in $managedBootstrapAliases) {
        $managedNode = $rows | Where-Object { $_.current_alias -eq $managedAlias } | Select-Object -First 1
        if (-not $managedNode) {
            Fail "Managed alias not found in nodes file: $managedAlias"
        }
        if ($managedNode.current_alias -eq $controlNode.current_alias) {
            Fail "Managed alias cannot be the same as control alias: $managedAlias"
        }
        if (-not (Has-RootPassword $managedNode) -and -not $UseAdminKeyFallback) {
            Write-Host "Step 2d/5: queue existing managed node $managedAlias for Ansible bootstrap converge"
            continue
        }
        if (-not (Has-RootPassword $managedNode) -and -not (Has-AdminKey $managedAlias $OperatorDir)) {
            Write-Host "Step 2d/5: skip existing managed node $managedAlias; admin_key is missing"
            continue
        }

        $managedArgs = @(
            "-NodesFile", $NodesFile,
            "-Alias", $managedAlias,
            "-OperatorDir", $OperatorDir,
            "-OperatorBackupScript", $OperatorBackupScript,
            "-OperatorBackupDir", $OperatorBackupDir,
            "-OperatorBackupRemoteDir", $OperatorBackupRemoteDir,
            "-OperatorBackupKeepLatest", $OperatorBackupKeepLatest,
            "-AdminUser", $AdminUser,
            "-AnsibleAuthorizedKeyFile", $managedAnsibleAuthorizedKeyFile
        )
        if ($useStateFile) {
            $managedArgs += @("-StateFile", $StateFile)
        }
        if ($ForceOverwriteKeys) {
            $managedArgs += "-Force"
        }
        if ($RegenerateRemoteKeys) {
            $managedArgs += "-RegenerateRemoteKeys"
        }
        if ($AutoAcceptHostKey) {
            $managedArgs += "-AutoAcceptHostKey"
        }
        if ($SkipOperatorBackup) {
            $managedArgs += "-SkipOperatorBackup"
        }

        if (Has-RootPassword $managedNode) {
            Write-Host "Step 2d/5: bootstrap managed node $managedAlias"
        } else {
            Write-Host "Step 2d/5: re-bootstrap existing managed node $managedAlias through admin key fallback"
        }
        Invoke-ChildScript $BootstrapRunner $managedArgs
    }
}

if ($managedConvergeAliases.Count -gt 0 -and -not $SkipBootstrapConverge) {
    if (-not $SkipSync) {
        Invoke-SyncRunner "Step 3a/5: sync sanitized nodes.csv to control node for bootstrap converge" -SkipVerifyForSync -SkipServicePlanForSync
    }
    Invoke-BootstrapConverge $managedConvergeAliases $managedAnsibleAuthorizedKeyFile
} elseif ($managedConvergeAliases.Count -gt 0) {
    Write-Host "Step 3b/5: bootstrap converge skipped by -SkipBootstrapConverge for: $($managedConvergeAliases -join ', ')"
}
} finally {
    if ($temporaryAnsibleAuthorizedKeyFile -and (Test-Path -LiteralPath $temporaryAnsibleAuthorizedKeyFile -PathType Leaf)) {
        Remove-Item -LiteralPath $temporaryAnsibleAuthorizedKeyFile -Force -ErrorAction SilentlyContinue
    }
}

if (-not $SkipSync) {
    Invoke-SyncRunner "Step 4/5: final sync sanitized nodes.csv to control node"
} else {
    Write-Host "Step 4/5: sync skipped; verify skipped too"
}

if ($SkipSync) {
    Write-Host "Step 5/5: verify skipped because sync was skipped"
} elseif ($SkipVerify) {
    Write-Host "Step 5/5: verify skipped by -SkipVerify"
} else {
    Write-Host "Step 5/5: verify control node and managed nodes completed by sync runner"
}
if ($SkipServicePlan) {
    Write-Host "Service plan skipped by -SkipServicePlan"
}
Write-Host "Bootstrap-all completed."
