param(
    [string]$OutputDir = ".\operator\geo_policy\data",
    [switch]$AcceptInitial
)

$ErrorActionPreference = "Stop"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Invoke-GeoPolicyDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$OutFile
    )

    $downloadErrors = [System.Collections.Generic.List[string]]::new()
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    foreach ($candidateUri in $Uri) {
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        if ($null -ne $curl) {
            & $curl.Source `
                --fail `
                --silent `
                --show-error `
                --location `
                --retry 3 `
                --retry-delay 2 `
                --connect-timeout 20 `
                --max-time 240 `
                --output $OutFile `
                $candidateUri
            if ($LASTEXITCODE -eq 0 -and
                (Test-Path -LiteralPath $OutFile -PathType Leaf) -and
                (Get-Item -LiteralPath $OutFile).Length -gt 0) {
                return
            }
            $downloadErrors.Add("curl failed for $candidateUri with exit code $LASTEXITCODE")
        }

        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        try {
            # Windows PowerShell can otherwise negotiate an obsolete TLS mode.
            [Net.ServicePointManager]::SecurityProtocol = `
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest `
                -UseBasicParsing `
                -Uri $candidateUri `
                -Headers @{ "User-Agent" = "AI-Service-Platform-GeoPolicy/1.0" } `
                -TimeoutSec 240 `
                -OutFile $OutFile
            if ((Test-Path -LiteralPath $OutFile -PathType Leaf) -and
                (Get-Item -LiteralPath $OutFile).Length -gt 0) {
                return
            }
            $downloadErrors.Add("Invoke-WebRequest returned an empty file for $candidateUri")
        } catch {
            $downloadErrors.Add("Invoke-WebRequest failed for ${candidateUri}: $($_.Exception.Message)")
        }
    }

    Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    throw "GeoPolicy source download failed. $($downloadErrors -join '; ')"
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-sp-geo-policy-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $ipdeny = Join-Path $tempDir "ru-aggregated.zone"
    $ripe = Join-Path $tempDir "delegated-ripencc-extended-latest"
    Invoke-GeoPolicyDownload `
        -Uri @("https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone") `
        -OutFile $ipdeny
    Invoke-GeoPolicyDownload `
        -Uri @(
            "https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-extended-latest",
            "https://ftp.ripe.net/ripe/stats/delegated-ripencc-extended-latest"
        ) `
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
