param(
    [Parameter(Mandatory=$true)]
    [string]$NodesFile,

    [Parameter(Mandatory=$true)]
    [string]$Alias,

    [string]$SetupScript = "tools/bootstrap/setup_vps.sh",

    [string]$AnsibleAuthorizedKeyFile,

    [string]$OutputAnsibleAuthorizedKeyFile = ".\operator\ansible_control.managed_nodes.pub",

    [switch]$Force
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

Require-File $NodesFile "NodesFile"
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
    Fail "Cannot bootstrap remote VPS with endpoint=local: $Alias"
}
if (-not $row.root_password) {
    Fail "root_password is required for first remote bootstrap from Windows runner: $Alias"
}
if (-not (Has-Role $row.roles "management") -and -not (Has-Role $row.roles "orchestration") -and -not $AnsibleAuthorizedKeyFile) {
    Fail "Managed node $Alias requires -AnsibleAuthorizedKeyFile"
}

$isManagementNode = Is-ManagementNode $row.roles
if ($isManagementNode -and (Test-Path -LiteralPath $OutputAnsibleAuthorizedKeyFile -PathType Leaf) -and -not $Force) {
    Fail "Output Ansible public key file already exists: $OutputAnsibleAuthorizedKeyFile. Use -Force to overwrite it."
}

$sanitized = New-TemporaryFile
try {
    Set-Content -LiteralPath $sanitized -Value $ExpectedHeader -Encoding ascii
    foreach ($item in $rows) {
        Add-Content -LiteralPath $sanitized -Value ("{0},{1},{2},{3},{4}," -f $item.current_alias,$item.endpoint,$item.connection,$item.ansible_group,$item.roles) -Encoding ascii
    }

    $remote = "root@$($row.endpoint)"
    Write-Host "Bootstrapping $Alias at $($row.endpoint)"

    & pscp -pw $row.root_password $SetupScript "${remote}:/tmp/setup_vps.sh"
    if ($LASTEXITCODE -ne 0) { Fail "pscp setup_vps.sh failed" }

    & pscp -pw $row.root_password $sanitized "${remote}:/tmp/nodes.csv"
    if ($LASTEXITCODE -ne 0) { Fail "pscp sanitized nodes.csv failed" }

    if ($AnsibleAuthorizedKeyFile) {
        & pscp -pw $row.root_password $AnsibleAuthorizedKeyFile "${remote}:/tmp/ansible_control.managed_nodes.pub"
        if ($LASTEXITCODE -ne 0) { Fail "pscp Ansible public key failed" }
    }

    if ($AnsibleAuthorizedKeyFile) {
        $setupCommand = "ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash /tmp/setup_vps.sh --nodes-file /tmp/nodes.csv --alias '$Alias'"
    } else {
        $setupCommand = "bash /tmp/setup_vps.sh --nodes-file /tmp/nodes.csv --alias '$Alias'"
    }

    if ($isManagementNode) {
        $emitKeyCommand = "if [ `$rc -eq 0 ]; then echo $PublicKeyBeginMarker; cat /home/ansible/.ssh/ansible_control.managed_nodes.pub; echo $PublicKeyEndMarker; fi"
    } else {
        $emitKeyCommand = ":"
    }
    $remoteCommand = "set +e; $setupCommand; rc=`$?; $emitKeyCommand; rm -f /tmp/setup_vps.sh /tmp/nodes.csv /tmp/ansible_control.managed_nodes.pub; exit `$rc"

    $remoteOutput = & plink -pw $row.root_password $remote $remoteCommand 2>&1
    $remoteExitCode = $LASTEXITCODE
    $remoteOutput | ForEach-Object { Write-Host $_ }
    if ($remoteExitCode -ne 0) { Fail "remote setup_vps.sh failed" }

    if ($isManagementNode) {
        $outputDir = Split-Path -Parent $OutputAnsibleAuthorizedKeyFile
        if ($outputDir) {
            New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
        }
        if ((Test-Path -LiteralPath $OutputAnsibleAuthorizedKeyFile -PathType Leaf) -and $Force) {
            Remove-Item -LiteralPath $OutputAnsibleAuthorizedKeyFile -Force
        }

        $publicKeyLines = New-Object System.Collections.Generic.List[string]
        $insidePublicKey = $false
        foreach ($line in $remoteOutput) {
            $lineText = [string]$line
            if ($lineText -eq $PublicKeyBeginMarker) {
                $insidePublicKey = $true
                continue
            }
            if ($lineText -eq $PublicKeyEndMarker) {
                $insidePublicKey = $false
                continue
            }
            if ($insidePublicKey) {
                $publicKeyLines.Add($lineText)
            }
        }
        if ($publicKeyLines.Count -ne 1) {
            Fail "Could not capture exactly one Ansible control public key from remote bootstrap output."
        }
        Set-Content -LiteralPath $OutputAnsibleAuthorizedKeyFile -Value $publicKeyLines[0] -Encoding ascii
        Write-Host "Saved Ansible control public key: $OutputAnsibleAuthorizedKeyFile"
    }

    Write-Host "Bootstrap completed for $Alias"
} finally {
    Remove-Item -LiteralPath $sanitized -Force -ErrorAction SilentlyContinue
}
