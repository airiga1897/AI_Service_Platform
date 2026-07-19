param(
    [string]$HistoryDir = ".\operator\egress_policy\history",
    [string]$ArchiveRoot = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Fail($Message) {
    Write-Error $Message
    exit 1
}

if (-not (Test-Path -LiteralPath $HistoryDir -PathType Container)) {
    Write-Host "No egress probe history directory found: $HistoryDir"
    exit 0
}

$historyFiles = @(Get-ChildItem -LiteralPath $HistoryDir -File -Filter "egress-probes-*.jsonl" | Sort-Object Name)
if ($historyFiles.Count -eq 0) {
    Write-Host "No egress probe history files found in: $HistoryDir"
    exit 0
}

if ([string]::IsNullOrWhiteSpace($ArchiveRoot)) {
    $ArchiveRoot = Join-Path $HistoryDir "archive"
}

$stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$archiveDir = Join-Path $ArchiveRoot $stamp

if ($DryRun) {
    Write-Host "Would archive $($historyFiles.Count) egress probe history file(s) to: $archiveDir"
    foreach ($file in $historyFiles) {
        Write-Host "  $($file.FullName)"
    }
    exit 0
}

New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null
foreach ($file in $historyFiles) {
    Move-Item -LiteralPath $file.FullName -Destination (Join-Path $archiveDir $file.Name)
}

Write-Host "[OK] Archived $($historyFiles.Count) egress probe history file(s) to: $archiveDir"
