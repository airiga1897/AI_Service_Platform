param(
    [string]$Repo = "airiga1897/AI_Service_Platform",

    [string]$Environment = "ai-retail-dev-preprod",

    [string]$SshHost,

    [string]$SshUser = "depuser",

    [string]$SshPort = "22",

    [Parameter(Mandatory=$true)]
    [string]$SshKeyFile,

    [string]$NodesFile,

    [string]$Alias
)

$ErrorActionPreference = "Stop"

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Require-Command($Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Fail "$Name not found in PATH"
    }
}

function Require-File($Path, $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Label not found: $Path"
    }
}

function Require-GhAuth {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $script:ErrorActionPreference = "Continue"
        $output = & gh auth status 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $script:ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        $output | ForEach-Object { Write-Host $_ }
        Fail @"
GitHub CLI is not authenticated.

Run:
  gh auth login

Use an account with repo access to $Repo, then re-run this script.
"@
    }
}

function Invoke-GhApi($Arguments) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $script:ErrorActionPreference = "Continue"
        $output = & gh @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $script:ErrorActionPreference = $previousErrorActionPreference
    }

    return [PSCustomObject]@{
        Output = $output
        ExitCode = $exitCode
    }
}

function Write-SecretFromString($Name, $Value) {
    $tmp = New-TemporaryFile
    try {
        Set-Content -LiteralPath $tmp -Value $Value -Encoding ascii -NoNewline
        & gh secret set $Name --repo $Repo --env $Environment --body-file $tmp
        if ($LASTEXITCODE -ne 0) {
            Fail "Failed to set GitHub Environment secret: $Name"
        }
        Write-Host "Secret ensured: $Name"
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

Require-Command gh
Require-GhAuth
Require-File $SshKeyFile "SshKeyFile"

if ($NodesFile -or $Alias) {
    if (-not $NodesFile -or -not $Alias) {
        Fail "NodesFile and Alias must be provided together"
    }
    Require-File $NodesFile "NodesFile"
    $expectedHeader = "current_alias,endpoint,connection,root_password"
    $firstLine = Get-Content -LiteralPath $NodesFile -TotalCount 1
    if ($firstLine -ne $expectedHeader) {
        Fail "nodes.csv header must be exactly: $expectedHeader"
    }
    $rows = Import-Csv -LiteralPath $NodesFile
    $node = $rows | Where-Object { $_.current_alias -eq $Alias } | Select-Object -First 1
    if (-not $node) {
        Fail "Alias not found in nodes file: $Alias"
    }
    if ($node.endpoint -eq "local" -or $node.connection -eq "local") {
        Fail "Alias $Alias uses local endpoint; GitHub SSH secrets require a public DNS/IP endpoint"
    }
    if (-not $SshHost) {
        $SshHost = $node.endpoint
    }
}

if ([string]::IsNullOrWhiteSpace($SshHost)) {
    Fail "SshHost is required, or provide NodesFile and Alias"
}
if ([string]::IsNullOrWhiteSpace($SshUser)) {
    Fail "SshUser is required"
}
if ([string]::IsNullOrWhiteSpace($SshPort)) {
    Fail "SshPort is required"
}

$envPath = "repos/$Repo/environments/$Environment"

Write-Host "Checking GitHub Environment: $Repo / $Environment"
$check = Invoke-GhApi @("api", $envPath, "--silent")
if ($check.ExitCode -eq 0) {
    Write-Host "GitHub Environment already exists: $Environment"
} else {
    Write-Host "GitHub Environment not found; creating: $Environment"
    $create = Invoke-GhApi @("api", "--method", "PUT", $envPath, "--silent")
    if ($create.ExitCode -ne 0) {
        $create.Output | ForEach-Object { Write-Host $_ }
        Fail "Failed to create GitHub Environment: $Environment"
    }
    Write-Host "GitHub Environment created: $Environment"
}

Write-Host "Ensuring Environment secrets for $Environment"
Write-SecretFromString "SSH_HOST" $SshHost
Write-SecretFromString "SSH_USER" $SshUser
Write-SecretFromString "SSH_PORT" $SshPort

& gh secret set SSH_KEY --repo $Repo --env $Environment --body-file $SshKeyFile
if ($LASTEXITCODE -ne 0) {
    Fail "Failed to set GitHub Environment secret: SSH_KEY"
}
Write-Host "Secret ensured: SSH_KEY"

Write-Host "GitHub Environment secrets are ready: $Environment"
