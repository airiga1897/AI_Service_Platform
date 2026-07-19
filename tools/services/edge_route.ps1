param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("vpn_ingress", "minecraft")]
    [string]$Route,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateSet("present", "absent", "purged")]
    [string]$State,

    [Parameter(Mandatory = $true)]
    [string]$Alias,

    [string]$StateFile = ".\operator\state.csv"
)

$ExpectedHeader = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
$RouteGroups = @{
    "vpn_ingress" = "vpn_ingress"
    "minecraft" = "minecraft_edge"
}

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Split-Aliases($Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }
    return @(
        $Value -replace ",", "+" -split "\+" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
}

if ($Alias -notmatch "^[A-Za-z0-9_-]+$") {
    Fail "Alias must contain only letters, digits, underscore or dash: $Alias"
}

if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
    Fail "state.csv not found: $StateFile"
}

$lines = [System.Collections.Generic.List[string]]::new()
foreach ($line in (Get-Content -LiteralPath $StateFile)) {
    $lines.Add([string]$line)
}

if ($lines.Count -eq 0 -or $lines[0] -ne $ExpectedHeader) {
    Fail "state.csv header must be exactly: $ExpectedHeader"
}

$aliasKnown = $false
for ($i = 1; $i -lt $lines.Count; $i++) {
    if (-not $lines[$i].Trim()) {
        continue
    }
    $columns = $lines[$i].Split(",")
    if ($columns.Count -ne 7) {
        Fail "state.csv row $($i + 1) must have exactly 7 columns"
    }
    foreach ($field in @($columns[3], $columns[4], $columns[5])) {
        if ((Split-Aliases $field) -contains $Alias) {
            $aliasKnown = $true
        }
    }
}

if (-not $aliasKnown) {
    Fail "Alias '$Alias' is not referenced in state.csv"
}

$routeGroup = $RouteGroups[$Route]
$updated = $false
for ($i = 1; $i -lt $lines.Count; $i++) {
    $columns = $lines[$i].Split(",")
    if ($columns.Count -eq 7 -and $columns[0] -eq "edge_route" -and $columns[1] -eq $Route -and $columns[3] -eq $Alias) {
        $lines[$i] = "edge_route,$Route,$routeGroup,$Alias,,,$State"
        $updated = $true
        break
    }
}

if (-not $updated) {
    $lines.Add("edge_route,$Route,$routeGroup,$Alias,,,$State")
}

Set-Content -LiteralPath $StateFile -Value $lines -Encoding ascii
Write-Host "edge_route $Route on $Alias set to $State in $StateFile"
