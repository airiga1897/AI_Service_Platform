param(
    [string]$HistoryDir = ".\operator\egress_policy\history",
    [string]$HistoryFile = "",
    [switch]$Latest = $true,
    [Alias("Profile")]
    [string[]]$ProfileName = @(),
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Get-Recommendation($Record) {
    $mode = if ($Record.path_mode) { [string]$Record.path_mode } else { "direct" }
    $httpStatus = if ($Record.target_status) { $Record.target_status.http_status } else { $Record.observation.http_status }
    $desired = if ($Record.desired_region_behavior) { [string]$Record.desired_region_behavior } else { "fallback_on_ingress_egress_failure" }

    if ($mode -eq "cascade") {
        $transportOk = $Record.cascade_transport_status -and $Record.cascade_transport_status.reachable
        $connectionOk = $Record.cascade_connection_status -and $Record.cascade_connection_status.online
        if (-not $transportOk -or -not $connectionOk) {
            return "fallback_unavailable"
        }
    }

    if ($Record.status -eq "probe_error") {
        if ($mode -eq "cascade") {
            return "fallback_unavailable"
        }
        return "probe_error"
    }

    if ($httpStatus -ge 200 -and $httpStatus -lt 400) {
        if ($desired -eq "require_non_ru_egress") {
            $country = if ($Record.effective_country) { [string]$Record.effective_country } else { [string]$Record.observation.external_country }
            if ($country -eq "RU") {
                return "strict_non_ru_violation"
            }
        }
        if ($mode -eq "cascade") {
            return "fallback_available"
        }
        return "good_ingress_local"
    }

    return "review"
}

function Convert-RecordToReportRow($Record) {
    $mode = if ($Record.path_mode) { [string]$Record.path_mode } else { "direct" }
    $observation = if ($Record.target_status) { $Record.target_status } else { $Record.observation }
    $target = $Record.target

    [pscustomobject]@{
        profile = $Record.profile
        mode = $mode
        alias = $Record.candidate_alias
        ingress = if ($Record.ingress_alias) { $Record.ingress_alias } else { $Record.candidate_alias }
        egress = if ($Record.egress_alias) { $Record.egress_alias } else { $Record.candidate_alias }
        cascade = $Record.cascade_connection
        link_state = $Record.cascade_link_state
        country = if ($Record.effective_country) { $Record.effective_country } elseif ($observation) { $observation.external_country } else { $null }
        ip = if ($Record.effective_ip) { $Record.effective_ip } elseif ($observation) { $observation.external_ip } else { $null }
        http = if ($observation) { $observation.http_status } else { $null }
        tcp_ms = if ($observation) { $observation.tcp_connect_ms } else { $null }
        tls_ms = if ($observation) { $observation.tls_handshake_ms } else { $null }
        http_first_ms = if ($observation) { $observation.http_first_byte_ms } else { $null }
        http_total_ms = if ($observation) { $observation.http_total_ms } else { $null }
        attempts = if ($Record.attempts_used) { "$($Record.attempts_used)/$($Record.attempts_total)" } else { $null }
        cascade_tcp = if ($Record.cascade_transport_status) { $Record.cascade_transport_status.reachable } else { $null }
        cascade_online = if ($Record.cascade_connection_status) { $Record.cascade_connection_status.online } else { $null }
        recommendation = Get-Recommendation $Record
        target = if ($target) { "$($target.protocol)://$($target.value):$($target.port)" } else { $null }
        observed_at_utc = $Record.observed_at_utc
        run_id = $Record.run_id
        error = $Record.error
    }
}

if ($HistoryFile) {
    if (-not (Test-Path -LiteralPath $HistoryFile -PathType Leaf)) {
        Fail "egress probe history file not found: $HistoryFile"
    }
    $historyFiles = @(Get-Item -LiteralPath $HistoryFile)
} else {
    if (-not (Test-Path -LiteralPath $HistoryDir -PathType Container)) {
        if ($Json) {
            Write-Output "[]"
        } else {
            Write-Host "No egress probe history found in: $HistoryDir"
        }
        exit 0
    }

    $historyFiles = @(Get-ChildItem -LiteralPath $HistoryDir -File -Filter "egress-probes-*.jsonl" | Sort-Object Name -Descending)
    if ($historyFiles.Count -eq 0) {
        if ($Json) {
            Write-Output "[]"
        } else {
            Write-Host "No egress probe history found in: $HistoryDir"
        }
        exit 0
    }

    if ($Latest) {
        $historyFiles = @($historyFiles | Select-Object -First 1)
    }
}

$profileFilter = @($ProfileName | Where-Object { $_ })
$rows = New-Object System.Collections.ArrayList

foreach ($file in $historyFiles) {
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        $lineNumber += 1
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $record = $line | ConvertFrom-Json
        } catch {
            Fail "failed to parse JSONL record $($file.FullName):$lineNumber"
        }
        if ($profileFilter.Count -gt 0 -and $profileFilter -notcontains $record.profile) {
            continue
        }
        [void]$rows.Add((Convert-RecordToReportRow $record))
    }
}

if ($rows.Count -eq 0) {
    if ($profileFilter.Count -gt 0) {
        if ($Json) {
            Write-Output "[]"
        } else {
            Write-Host "No egress probe records matched profile filter: $($profileFilter -join ', ')"
        }
        exit 0
    }
    if ($Json) {
        Write-Output "[]"
    } else {
        Write-Host "No egress probe records found."
    }
    exit 0
}

$result = @($rows.ToArray() | Sort-Object profile, alias, target)

if ($Json) {
    $result | ConvertTo-Json -Depth 8
    exit 0
}

$result |
    Select-Object `
        @{ Name = "profile"; Expression = { $_.profile } },
        mode,
        @{ Name = "in"; Expression = { $_.ingress } },
        @{ Name = "out"; Expression = { $_.egress } },
        @{ Name = "cascade"; Expression = { $_.cascade } },
        @{ Name = "link"; Expression = { $_.link_state } },
        country,
        http,
        @{ Name = "att"; Expression = { $_.attempts } },
        @{ Name = "total_ms"; Expression = { $_.http_total_ms } },
        @{ Name = "rec"; Expression = { $_.recommendation } } |
    Format-Table -AutoSize -Wrap
