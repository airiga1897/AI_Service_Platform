param(
    [Parameter(Mandatory=$true)]
    [string]$NodesFile,

    [string]$StateFile = ".\operator\state.csv",

    [string]$ControlRole = "orchestration",

    [string]$ControlAlias = "",

    [string[]]$ManagedAliases = @(),

    [string]$OperatorDir = ".\operator",

    [string]$BootstrapRunner = "tools/bootstrap/bootstrap_from_windows.ps1",

[string]$SyncRunner = "tools/bootstrap/sync_to_orchestration.ps1",

    [string]$AnsibleAuthorizedKeyFile = "",

    [switch]$ForceManagementKeyRefresh,

    [switch]$ForceOverwriteKeys,

    [switch]$AutoAcceptHostKey,

    [switch]$FixKeyAcl,

    [switch]$RegenerateRemoteKeys,

    [switch]$SkipSync,

    [switch]$SkipVerify,

    [switch]$SkipServicePlan,

    [switch]$SkipManaged
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

function Get-StateReferencedAliases($StateRows) {
    $aliases = New-Object System.Collections.Generic.HashSet[string]
    foreach ($row in $StateRows) {
        foreach ($field in @("active_aliases", "candidate_aliases", "old_aliases")) {
            foreach ($alias in (Split-AliasList $row.$field)) {
                [void]$aliases.Add($alias)
            }
        }
    }
    return $aliases
}

function Invoke-ChildScript($ScriptPath, $Arguments) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        Fail "Child script failed: $ScriptPath"
    }
}

Require-File $NodesFile "NodesFile"
Require-File $BootstrapRunner "BootstrapRunner"
Require-File $SyncRunner "SyncRunner"

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
$useStateFile = $true
if ($controlNode.connection -ne "ssh" -or $controlNode.endpoint -eq "local") {
    Fail "Control node $($controlNode.current_alias) must use connection=ssh and a real endpoint for operator bootstrap."
}

if (-not $AnsibleAuthorizedKeyFile) {
    $AnsibleAuthorizedKeyFile = Join-Path $OperatorDir "ansible_control.managed_nodes.pub"
}

if ($ManagedAliases.Count -eq 0) {
    $referencedAliases = Get-StateReferencedAliases $stateRows
    $ManagedAliases = @(
        $rows |
            Where-Object {
                $_.current_alias -ne $controlNode.current_alias -and
                $_.connection -eq "ssh" -and
                $_.endpoint -ne "local" -and
                $referencedAliases.Contains($_.current_alias)
            } |
            ForEach-Object { $_.current_alias }
    )
}

Write-Host "Control node: $($controlNode.current_alias) via role '$ControlRole'"
if ($SkipManaged) {
    Write-Host "Managed nodes: skipped"
} else {
    Write-Host "Managed nodes: $($ManagedAliases -join ', ')"
}

$controlArgs = @(
    "-NodesFile", $NodesFile,
    "-Alias", $controlNode.current_alias,
    "-OperatorDir", $OperatorDir,
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

Write-Host "Step 1/4: bootstrap control node $($controlNode.current_alias)"
Invoke-ChildScript $BootstrapRunner $controlArgs

Require-File $AnsibleAuthorizedKeyFile "AnsibleAuthorizedKeyFile"

if (-not $SkipManaged) {
    foreach ($managedAlias in $ManagedAliases) {
        $managedNode = $rows | Where-Object { $_.current_alias -eq $managedAlias } | Select-Object -First 1
        if (-not $managedNode) {
            Fail "Managed alias not found in nodes file: $managedAlias"
        }
        if ($managedNode.current_alias -eq $controlNode.current_alias) {
            Fail "Managed alias cannot be the same as control alias: $managedAlias"
        }
        if ($managedNode.connection -ne "ssh" -or $managedNode.endpoint -eq "local") {
            Fail "Managed node $managedAlias must use connection=ssh and a real endpoint for operator bootstrap."
        }

        $managedArgs = @(
            "-NodesFile", $NodesFile,
            "-Alias", $managedAlias,
            "-OperatorDir", $OperatorDir,
            "-AnsibleAuthorizedKeyFile", $AnsibleAuthorizedKeyFile
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

        Write-Host "Step 2/4: bootstrap managed node $managedAlias"
        Invoke-ChildScript $BootstrapRunner $managedArgs
    }
}

if (-not $SkipSync) {
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
    if ($SkipVerify) {
        $syncArgs += "-SkipVerify"
    }
    if ($SkipServicePlan) {
        $syncArgs += "-SkipServicePlan"
    }
    if ($FixKeyAcl) {
        Write-Warning "-FixKeyAcl is deprecated. sync_nodes_to_vps3.ps1 now fixes OpenSSH key ACL automatically."
    }

    Write-Host "Step 3/4: sync sanitized nodes.csv to control node"
    Invoke-ChildScript $SyncRunner $syncArgs
} else {
    Write-Host "Step 3/4: sync skipped; verify skipped too"
}

if ($SkipSync) {
    Write-Host "Step 4/4: verify skipped because sync was skipped"
} elseif ($SkipVerify) {
    Write-Host "Step 4/4: verify skipped by -SkipVerify"
} else {
    Write-Host "Step 4/4: verify control node and managed nodes completed by sync runner"
}
if ($SkipServicePlan) {
    Write-Host "Service plan skipped by -SkipServicePlan"
}
Write-Host "Bootstrap-all completed."
