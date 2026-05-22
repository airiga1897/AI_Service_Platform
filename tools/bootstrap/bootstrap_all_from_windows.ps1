param(
    [Parameter(Mandatory=$true)]
    [string]$NodesFile,

    [string]$StateFile = ".\operator\state.csv",

    [string]$ControlRole = "orchestration",

    [string]$ControlAlias = "",

    [string[]]$ManagedAliases = @(),

    [string]$OperatorDir = ".\operator",

    [string]$BootstrapRunner = "tools/bootstrap/bootstrap_from_windows.ps1",

    [string]$SyncRunner = "tools/bootstrap/sync_nodes_to_vps3.ps1",

    [string]$AnsibleAuthorizedKeyFile = "",

    [switch]$ForceManagementKeyRefresh,

    [switch]$ForceOverwriteKeys,

    [switch]$AutoAcceptHostKey,

    [switch]$RegenerateRemoteKeys,

    [switch]$SkipSync,

    [switch]$SkipManaged
)

$ErrorActionPreference = "Stop"
$ExpectedHeader = "current_alias,endpoint,connection,ansible_group,roles,root_password"
$ExpectedStateHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$ManagedRoleSet = @(
    "production",
    "production-runtime",
    "preprod",
    "hot-standby",
    "backup",
    "vpn-edge",
    "vpn-cascade"
)

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

function Resolve-ControlNode($Rows, $Role, $ExplicitAlias) {
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

function Resolve-ControlNodeFromState($NodeRows, $StateRows, $Role, $ExplicitAlias) {
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

function Has-AnyManagedRole($Roles) {
    foreach ($role in $ManagedRoleSet) {
        if (Has-Role $Roles $role) {
            return $true
        }
    }
    return $false
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
if ($StateFile -and (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
    $stateFirstLine = Get-Content -LiteralPath $StateFile -TotalCount 1
    if ($stateFirstLine -ne $ExpectedStateHeader) {
        Fail "state.csv header must be exactly: $ExpectedStateHeader"
    }
    $stateRows = Import-Csv -LiteralPath $StateFile
    $controlNode = Resolve-ControlNodeFromState $rows $stateRows $ControlRole $ControlAlias
    $useStateFile = $true
} else {
    $controlNode = Resolve-ControlNode $rows $ControlRole $ControlAlias
}
if ($controlNode.connection -ne "ssh" -or $controlNode.endpoint -eq "local") {
    Fail "Control node $($controlNode.current_alias) must use connection=ssh and a real endpoint for operator bootstrap."
}

if (-not $AnsibleAuthorizedKeyFile) {
    $AnsibleAuthorizedKeyFile = Join-Path $OperatorDir "ansible_control.managed_nodes.pub"
}

if ($ManagedAliases.Count -eq 0) {
    $ManagedAliases = @(
        $rows |
            Where-Object {
                $_.current_alias -ne $controlNode.current_alias -and
                $_.connection -eq "ssh" -and
                $_.endpoint -ne "local" -and
                (Has-AnyManagedRole $_.roles)
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

    Write-Host "Step 3/4: sync sanitized nodes.csv to control node"
    Invoke-ChildScript $SyncRunner $syncArgs
} else {
    Write-Host "Step 3/4: sync skipped"
}

Write-Host "Step 4/4: next manual check on control node"
Write-Host "  cd /opt/ai-service-platform"
Write-Host "  ansible all -i inventory.ini -m ping"
Write-Host "Bootstrap-all completed."
