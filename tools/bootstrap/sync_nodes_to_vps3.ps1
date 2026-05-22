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

    [string]$RemotePrepareScript = "/opt/ai-service-platform/tools/bootstrap/prepare_vps3_inventory.sh",

    [string]$Include = ""
)

$ErrorActionPreference = "Stop"
$ExpectedHeader = "current_alias,endpoint,connection,ansible_group,roles,root_password"
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
$remote = "$SshUser@$($controlNode.endpoint)"

try {
    Write-Host "Syncing sanitized nodes.csv to control node $($controlNode.current_alias) at $remote"
    & pscp -i $SshKeyFile $sanitized "${remote}:$RemoteNodesFile"
    if ($LASTEXITCODE -ne 0) { Fail "pscp sanitized nodes.csv failed" }

    $remoteStateFile = "/tmp/ai-service-platform.state.csv"
    if ($useStateFile) {
        Write-Host "Syncing state.csv to control node $($controlNode.current_alias)"
        & pscp -i $SshKeyFile $StateFile "${remote}:$remoteStateFile"
        if ($LASTEXITCODE -ne 0) { Fail "pscp state.csv failed" }
    }

    $prepareCommand = "sudo bash '$RemotePrepareScript' --source-nodes-file '$RemoteNodesFile'"
    if ($useStateFile) {
        $prepareCommand = "$prepareCommand --source-state-file '$remoteStateFile'"
    }
    if ($Include) {
        $prepareCommand = "$prepareCommand --include '$Include'"
    }
    $remoteCommand = "set -e; $prepareCommand; rm -f '$RemoteNodesFile' '$remoteStateFile'"

    Write-Host "Running control node inventory preparation"
    & plink -batch -i $SshKeyFile $remote $remoteCommand
    if ($LASTEXITCODE -ne 0) { Fail "remote prepare_vps3_inventory.sh failed" }

    Write-Host "Control node nodes.csv and inventory.ini are in sync"
} finally {
    Remove-Item -LiteralPath $sanitized -Force -ErrorAction SilentlyContinue
}
