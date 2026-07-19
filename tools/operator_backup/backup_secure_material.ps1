param(
    [string]$SecureDir = "D:\Projects\Ai_SP\Secure",
    [string]$LocalBackupDir = "D:\Backup\Projects\AI_SP\secure",
    [int]$KeepLatest = 10,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$RequiredFiles = @(
    "operator-backup-age-identity.txt",
    "operator-backup.env"
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

function Require-Dir($Path, $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Fail "$Label not found: $Path"
    }
}

function Invoke-BackupRotation($BackupDir, $Keep) {
    if ($Keep -le 0) {
        return
    }

    $archives = @(Get-ChildItem -LiteralPath $BackupDir -File -Filter "secure-material-*.zip" |
        Sort-Object Name -Descending)
    if ($archives.Count -le $Keep) {
        return
    }

    foreach ($archive in @($archives | Select-Object -Skip $Keep)) {
        $checksum = "$($archive.FullName).sha256"
        Write-Host "Rotating old secure material backup: $($archive.Name)"
        Remove-Item -LiteralPath $archive.FullName -Force
        Remove-Item -LiteralPath $checksum -Force -ErrorAction SilentlyContinue
    }
}

if ($KeepLatest -lt 0) {
    Fail "KeepLatest must be 0 or greater"
}

Require-Dir $SecureDir "SecureDir"
foreach ($fileName in $RequiredFiles) {
    Require-File (Join-Path $SecureDir $fileName) $fileName
}

$securePath = (Resolve-Path -LiteralPath $SecureDir).Path
$backupPath = $LocalBackupDir
$timestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$archiveName = "secure-material-$timestamp.zip"
$archivePath = Join-Path $backupPath $archiveName
$checksumPath = "$archivePath.sha256"

Write-Host "Secure material source:      $securePath"
Write-Host "Local secure backup target: $backupPath"
Write-Host "Archive:                    $archivePath"
Write-Host "Required files:"
foreach ($fileName in $RequiredFiles) {
    Write-Host "  - $fileName"
}
Write-Host "Remote upload:              disabled"

if ($WhatIf) {
    Write-Host "[WHATIF] Secure material backup archive was not created."
    exit 0
}

New-Item -ItemType Directory -Force -Path $backupPath | Out-Null
if (Test-Path -LiteralPath $archivePath) {
    Fail "Backup archive already exists: $archivePath"
}

Compress-Archive -Path (Join-Path $securePath "*") -DestinationPath $archivePath -CompressionLevel Optimal
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    Fail "Compress-Archive did not create archive: $archivePath"
}

$hash = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
("{0}  {1}" -f $hash.Hash.ToLowerInvariant(), $archiveName) |
    Set-Content -LiteralPath $checksumPath -Encoding ascii

Invoke-BackupRotation $backupPath $KeepLatest
Write-Host "[OK] Secure material backup completed: $archivePath"
