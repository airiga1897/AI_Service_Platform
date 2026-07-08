param(
    [string]$NodesFile = ".\operator\nodes.csv",
    [string]$OperatorDir = ".\operator",
    [string[]]$Aliases = @(),
    [string]$OutputDir = (Join-Path $env:TEMP "ai-service-platform\runtime-cleanup"),
    [int]$ConnectTimeoutSeconds = 10
)

$ErrorActionPreference = "Stop"

function Fail($Message) {
    Write-Error $Message
    exit 1
}

function Quote-BashArg($Value) {
    if ($null -eq $Value) { return "''" }
    return "'" + ([string]$Value).Replace("'", "'\''") + "'"
}

function Get-OpenSshCommonArgs($KeyFile) {
    return @(
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=$ConnectTimeoutSeconds",
        "-o", "IdentitiesOnly=yes",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "PasswordAuthentication=no",
        "-o", "PreferredAuthentications=publickey",
        "-o", "StrictHostKeyChecking=accept-new",
        "-i", $KeyFile
    )
}

function Invoke-SshCapture($Node, $Command) {
    $alias = [string]$Node.current_alias
    $port = [string]$Node.ssh_port
    if (-not $port) { $port = "22" }
    $key = Join-Path (Join-Path $OperatorDir $alias) "admin_key"
    if (-not (Test-Path -LiteralPath $key -PathType Leaf)) {
        return [pscustomobject]@{
            ok = $false
            rc = 255
            stdout = ""
            stderr = "missing admin key: $key"
        }
    }
    $remote = "useradmin@$($Node.endpoint)"
    $args = @("-n", "-T", "-p", $port) + @(Get-OpenSshCommonArgs $key) + @("-o", "RequestTTY=no", $remote, $Command)
    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath "ssh" -ArgumentList $args -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $stdout = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            ok = ($p.ExitCode -eq 0)
            rc = $p.ExitCode
            stdout = [string]$stdout
            stderr = [string]$stderr
        }
    } finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-JsonLines($Text) {
    $items = @()
    foreach ($line in (($Text -split "`r?`n") | Where-Object { $_.Trim().Length -gt 0 })) {
        try {
            $items += ($line | ConvertFrom-Json)
        } catch {
            $items += [pscustomobject]@{ parse_error = $_.Exception.Message; raw = $line }
        }
    }
    return @($items)
}

function Invoke-RemotePython($Node, $Script) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Script)
    $encoded = [Convert]::ToBase64String($bytes)
    $command = "python3 -c " + (Quote-BashArg "import base64; exec(base64.b64decode('$encoded').decode('utf-8'))")
    return Invoke-SshCapture $Node $command
}

function Read-Nodes($Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "nodes file not found: $Path"
    }
    $nodes = Import-Csv -LiteralPath $Path
    if ($Aliases.Count -gt 0) {
        $wanted = @{}
        foreach ($a in $Aliases) { $wanted[$a] = $true }
        $nodes = @($nodes | Where-Object { $wanted.ContainsKey([string]$_.current_alias) })
    }
    return @($nodes | Where-Object { $_.connection -eq "ssh" -and $_.endpoint -and $_.endpoint -ne "local" })
}

function Get-RemoteInventory($Node) {
    $alias = [string]$Node.current_alias
    Write-Host "[audit] $alias containers"
    $containers = Invoke-SshCapture $Node "sudo docker ps -a --format '{{json .}}'"
    Write-Host "[audit] $alias images"
    $images = Invoke-SshCapture $Node "sudo docker images --digests --format '{{json .}}'"
    Write-Host "[audit] $alias networks"
    $networks = Invoke-RemotePython $Node @'
import json
import subprocess

def run(args):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

ids = [line.strip() for line in run(["sudo", "docker", "network", "ls", "-q"]).stdout.splitlines() if line.strip()]
for item in ids:
    proc = run(["sudo", "docker", "network", "inspect", item])
    if proc.returncode == 0:
        for entry in json.loads(proc.stdout):
            print(json.dumps(entry, sort_keys=True))
    else:
        print(json.dumps({"Id": item, "inspect_error": proc.stderr.strip()}, sort_keys=True))
'@
    Write-Host "[audit] $alias temp/job files"
    $files = Invoke-RemotePython $Node @'
import json
import os
import subprocess

paths = ["/tmp", "/var/lib/ai-service-platform/jobs", "/var/log/ai-service-platform/jobs"]
for root in paths:
    if not os.path.exists(root):
        continue
    if root == "/tmp":
        cmd = ["sudo", "find", root, "-maxdepth", "1", "-name", "ai-sp-*", "-printf", "%p\t%y\t%s\t%TY-%Tm-%TdT%TH:%TM:%TS\n"]
    else:
        cmd = ["sudo", "find", root, "-mindepth", "1", "-maxdepth", "1", "-printf", "%p\t%y\t%s\t%TY-%Tm-%TdT%TH:%TM:%TS\n"]
    proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        print(json.dumps({"root": root, "error": proc.stderr.strip()}, sort_keys=True))
        continue
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 4:
            print(json.dumps({"path": parts[0], "type": parts[1], "size": parts[2], "mtime": parts[3]}, sort_keys=True))
'@
    Write-Host "[audit] $alias postgres status"
    $postgres = Invoke-RemotePython $Node @'
import json
import subprocess

def run(command):
    return subprocess.run(command, shell=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

names = run("sudo docker ps --format '{{.Names}}'").stdout.splitlines()
if "ai-service-postgres" not in names:
    print(json.dumps({"present": False}, sort_keys=True))
else:
    recovery = run("sudo docker exec ai-service-postgres psql -U postgres -tAc 'select pg_is_in_recovery()' 2>/dev/null || true").stdout.strip()
    route = run("sudo docker exec ai-service-postgres ip route 2>/dev/null || true").stdout.strip()
    replication = run("sudo docker exec ai-service-postgres psql -U postgres -tAc \"select application_name || '|' || coalesce(client_addr::text,'') || '|' || state || '|' || sync_state from pg_stat_replication order by application_name\" 2>/dev/null || true").stdout.strip()
    print(json.dumps({"present": True, "pg_is_in_recovery": recovery, "route": route, "replication": replication}, sort_keys=True))
'@

    $containerItems = ConvertFrom-JsonLines $containers.stdout
    $networkItems = ConvertFrom-JsonLines $networks.stdout
    $imageItems = ConvertFrom-JsonLines $images.stdout
    $fileItems = ConvertFrom-JsonLines $files.stdout

    $legacyContainers = @($containerItems | Where-Object {
        ([string]$_.Names) -match 'softether-p2p|vpn[-_]?cascade|cascade|softether-l3-vps-(client|server)'
    })
    $legacyNetworks = @($networkItems | Where-Object {
        ([string]$_.Name) -match 'softether_p2p|vpn_cascade|cascade'
    })
    $activeImageIds = @{}
    foreach ($c in $containerItems) {
        $imageId = [string]$c.ImageID
        if ($imageId) { $activeImageIds[$imageId] = $true }
    }
    $generatedImages = @($imageItems | Where-Object { ([string]$_.Repository) -like "ai-service-platform/*" })
    $unknownImages = @($imageItems | Where-Object {
        $repo = [string]$_.Repository
        $repo -and
        $repo -ne "<none>" -and
        $repo -notlike "ai-service-platform/*" -and
        $repo -notlike "softethervpn/*" -and
        $repo -notlike "postgres" -and
        $repo -notlike "redis" -and
        $repo -notlike "nginx" -and
        $repo -notlike "haproxy" -and
        $repo -notlike "alpine"
    })

    return [pscustomobject]@{
        alias = $alias
        endpoint = [string]$Node.endpoint
        ok = ($containers.ok -and $images.ok -and $networks.ok)
        errors = @(
            @($containers, $images, $networks, $files, $postgres) |
                Where-Object { -not $_.ok -and $_.stderr } |
                ForEach-Object { $_.stderr.Trim() }
        )
        containers = $containerItems
        networks = $networkItems
        images = $imageItems
        temp_artifacts = $fileItems
        legacy_containers = $legacyContainers
        legacy_networks = $legacyNetworks
        generated_images = $generatedImages
        unknown_images = $unknownImages
        postgres_raw = [string]$postgres.stdout
    }
}

function Write-MarkdownReport($Report, $Path) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Runtime Cleanup Audit")
    $lines.Add("")
    $lines.Add("- Generated: $($Report.generated_at)")
    $lines.Add("- Nodes: $($Report.nodes.Count)")
    $lines.Add("- Mode: read-only")
    $lines.Add("")
    foreach ($node in $Report.nodes) {
        $lines.Add("## $($node.alias)")
        $lines.Add("")
        $lines.Add("- Endpoint: ``$($node.endpoint)``")
        $lines.Add("- SSH/Docker inventory OK: ``$($node.ok)``")
        if ($node.errors.Count -gt 0) {
            $lines.Add("- Errors: $($node.errors.Count)")
        }
        $lines.Add("- Containers: $($node.containers.Count)")
        $lines.Add("- Networks: $($node.networks.Count)")
        $lines.Add("- Images: $($node.images.Count)")
        $lines.Add("- Temp/job artifacts: $($node.temp_artifacts.Count)")
        $lines.Add("- Legacy containers: $($node.legacy_containers.Count)")
        $lines.Add("- Legacy networks: $($node.legacy_networks.Count)")
        $lines.Add("- Generated images: $($node.generated_images.Count)")
        $lines.Add("- Unknown images: $($node.unknown_images.Count)")
        if ($node.legacy_containers.Count -gt 0) {
            $lines.Add("")
            $lines.Add("Legacy containers:")
            foreach ($item in $node.legacy_containers) {
                $lines.Add("- ``$($item.Names)`` image=``$($item.Image)`` status=``$($item.Status)``")
            }
        }
        if ($node.legacy_networks.Count -gt 0) {
            $lines.Add("")
            $lines.Add("Legacy networks:")
            foreach ($item in $node.legacy_networks) {
                $subnet = ""
                if ($item.IPAM -and $item.IPAM.Config -and $item.IPAM.Config.Count -gt 0) {
                    $subnet = [string]$item.IPAM.Config[0].Subnet
                }
                $lines.Add("- ``$($item.Name)`` subnet=``$subnet`` containers=$($item.Containers.PSObject.Properties.Count)")
            }
        }
        if ($node.temp_artifacts.Count -gt 0) {
            $lines.Add("")
            $lines.Add("Temp/job artifacts:")
            foreach ($item in $node.temp_artifacts | Select-Object -First 20) {
                $lines.Add("- ``$($item.path)`` type=``$($item.type)`` size=``$($item.size)`` mtime=``$($item.mtime)``")
            }
            if ($node.temp_artifacts.Count -gt 20) {
                $lines.Add("- ... $($node.temp_artifacts.Count - 20) more")
            }
        }
        $lines.Add("")
    }
    Set-Content -LiteralPath $Path -Value $lines -Encoding utf8
}

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Fail "ssh not found in PATH"
}

$nodes = Read-Nodes $NodesFile
if ($nodes.Count -eq 0) {
    Fail "no ssh nodes selected"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$stamp = Get-Date -Format "yyyyMMddTHHmmss"
$jsonPath = Join-Path $OutputDir "runtime-cleanup-audit-$stamp.json"
$mdPath = Join-Path $OutputDir "runtime-cleanup-audit-$stamp.md"

$nodeReports = @()
foreach ($node in $nodes) {
    $nodeReports += Get-RemoteInventory $node
}

$report = [pscustomobject]@{
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    nodes_file = $NodesFile
    mode = "read-only"
    nodes = $nodeReports
}

$report | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding utf8
Write-MarkdownReport $report $mdPath

Write-Host "[OK] JSON report: $jsonPath"
Write-Host "[OK] Markdown report: $mdPath"
