param(
    [string]$OutputDir = ".\operator\geo_policy\data",
    [switch]$AcceptInitial
)

$ErrorActionPreference = "Stop"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-sp-geo-policy-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $ipdeny = Join-Path $tempDir "ru-aggregated.zone"
    $ripe = Join-Path $tempDir "delegated-ripencc-extended-latest"
    Invoke-WebRequest `
        -Uri "https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone" `
        -OutFile $ipdeny
    Invoke-WebRequest `
        -Uri "https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-extended-latest" `
        -OutFile $ripe

    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $cidrs = Join-Path $OutputDir "ru_ipv4.cidrs"
    $metadata = Join-Path $OutputDir "ru_ipv4.json"
    $arguments = @(
        "tools/geo_policy/geo_policy.py",
        "build-dataset",
        "--ipdeny-file", $ipdeny,
        "--ripe-file", $ripe,
        "--output-cidrs", $cidrs,
        "--output-metadata", $metadata
    )
    if (Test-Path -LiteralPath $metadata -PathType Leaf) {
        $arguments += @("--previous-metadata", $metadata)
    } elseif ($AcceptInitial) {
        $arguments += "--accept-initial"
    }
    & python @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "GeoPolicy dataset validation failed with exit code $LASTEXITCODE"
    }
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
