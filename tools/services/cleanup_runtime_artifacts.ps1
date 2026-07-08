param(
    [Parameter(Mandatory = $true)]
    [string]$AuditJson,
    [string]$OperatorDir = ".\operator",
    [string[]]$Aliases = @(),
    [switch]$Apply,
    [int]$ConnectTimeoutSeconds = 10,
    [int]$KeepGeneratedImageTagsPerRepository = 2,
    [int]$KeepJobDays = 2
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

function Invoke-Ssh($Alias, $Endpoint, $Command) {
    $key = Join-Path (Join-Path $OperatorDir $Alias) "admin_key"
    if (-not (Test-Path -LiteralPath $key -PathType Leaf)) {
        Fail "missing admin key for ${Alias}: $key"
    }
    $remote = "useradmin@$Endpoint"
    $args = @("-n", "-T", "-p", "22") + @(Get-OpenSshCommonArgs $key) + @("-o", "RequestTTY=no", $remote, $Command)
    & ssh @args
    if ($LASTEXITCODE -ne 0) {
        Fail "ssh cleanup command failed for $Alias with rc=$LASTEXITCODE"
    }
}

function Is-AllowedTempPath($Path) {
    return (
        $Path -match '^/tmp/ai-sp-[^/]+\.tar$' -or
        $Path -match '^/tmp/ai-sp-[^/]+\.tar\.gz$' -or
        $Path -match '^/var/lib/ai-service-platform/jobs/(service|bootstrap)-[A-Za-z0-9T-]+$' -or
        $Path -match '^/var/log/ai-service-platform/jobs/(service|bootstrap)-[A-Za-z0-9T-]+\.log$'
    )
}

function Get-CleanupPlan($Report) {
    $wanted = @{}
    foreach ($alias in $Aliases) { $wanted[$alias] = $true }
    $plans = @()
    foreach ($node in $Report.nodes) {
        $alias = [string]$node.alias
        if ($Aliases.Count -gt 0 -and -not $wanted.ContainsKey($alias)) { continue }

        $temp = @()
        foreach ($item in @($node.temp_artifacts)) {
            $path = [string]$item.path
            if (-not (Is-AllowedTempPath $path)) { continue }
            $temp += [pscustomobject]@{
                path = $path
                reason = "whitelisted temp/job artifact"
            }
        }

        $legacyContainers = @($node.legacy_containers | ForEach-Object {
            [pscustomobject]@{ name = [string]$_.Names; reason = "retired legacy container name" }
        })
        $legacyNetworks = @($node.legacy_networks | ForEach-Object {
            [pscustomobject]@{ name = [string]$_.Name; reason = "retired legacy network name; remove only if empty" }
        })

        $generatedImages = @()
        $byRepo = @{}
        foreach ($img in @($node.generated_images)) {
            $repo = [string]$img.Repository
            if (-not $byRepo.ContainsKey($repo)) { $byRepo[$repo] = @() }
            $byRepo[$repo] = @($byRepo[$repo]) + $img
        }
        foreach ($repo in $byRepo.Keys) {
            $sorted = @($byRepo[$repo] | Sort-Object -Property CreatedAt -Descending)
            $stale = @($sorted | Select-Object -Skip $KeepGeneratedImageTagsPerRepository)
            foreach ($img in $stale) {
                $ref = "$($img.Repository):$($img.Tag)"
                if ($img.Tag -and $img.Tag -ne "<none>") {
                    $generatedImages += [pscustomobject]@{
                        ref = $ref
                        reason = "stale generated ai-service-platform image; keep newest $KeepGeneratedImageTagsPerRepository per repository"
                    }
                }
            }
        }

        $plans += [pscustomobject]@{
            alias = $alias
            endpoint = [string]$node.endpoint
            temp_artifacts = $temp
            legacy_containers = $legacyContainers
            legacy_networks = $legacyNetworks
            stale_generated_images = $generatedImages
        }
    }
    return $plans
}

function Invoke-CleanupPlan($Plan) {
    foreach ($node in $Plan) {
        $alias = [string]$node.alias
        $endpoint = [string]$node.endpoint
        Write-Host "[cleanup] $alias"

        $paths = @($node.temp_artifacts | ForEach-Object { [string]$_.path })
        $containers = @($node.legacy_containers | ForEach-Object { [string]$_.name })
        $networks = @($node.legacy_networks | ForEach-Object { [string]$_.name })
        $images = @($node.stale_generated_images | ForEach-Object { [string]$_.ref })

        if (-not $Apply) {
            Write-Host "  temp/job artifacts: $($paths.Count)"
            Write-Host "  legacy containers: $($containers.Count)"
            Write-Host "  legacy networks: $($networks.Count)"
            Write-Host "  stale generated images: $($images.Count)"
            continue
        }

        $pathArgs = ($paths | ForEach-Object { Quote-BashArg $_ }) -join " "
        $containerArgs = ($containers | ForEach-Object { Quote-BashArg $_ }) -join " "
        $networkArgs = ($networks | ForEach-Object { Quote-BashArg $_ }) -join " "
        $imageArgs = ($images | ForEach-Object { Quote-BashArg $_ }) -join " "
        $command = @'
set -euo pipefail
keep_days=__KEEP_DAYS__
for path in __PATH_ARGS__; do
  [ -n "`$path" ] || continue
  case "`$path" in
    /tmp/ai-sp-*.tar|/tmp/ai-sp-*.tar.gz)
      sudo rm -f -- "`$path"
      ;;
    /var/lib/ai-service-platform/jobs/service-*|/var/lib/ai-service-platform/jobs/bootstrap-*)
      if [ -f "`$path/done" ] && [ -f "`$path/exit_code" ]; then
        sudo find "`$path" -maxdepth 0 -mtime +"`$keep_days" -exec rm -rf -- {} +
      fi
      ;;
    /var/log/ai-service-platform/jobs/service-*.log|/var/log/ai-service-platform/jobs/bootstrap-*.log)
      sudo find "`$path" -maxdepth 0 -mtime +"`$keep_days" -exec rm -f -- {} +
      ;;
  esac
done
for name in __CONTAINER_ARGS__; do
  [ -n "`$name" ] || continue
  case "`$name" in
    softether-p2p-server|softether-p2p-client|softether-cascade|vpn-cascade|softether-l3-vps-client|softether-l3-vps-server)
      sudo docker rm -f "`$name" >/dev/null 2>&1 || true
      ;;
  esac
done
for name in __NETWORK_ARGS__; do
  [ -n "`$name" ] || continue
  case "`$name" in
    ai_service_softether_p2p*|ai_service_vpn_cascade*|*cascade*)
      count="$(sudo docker network inspect -f '{{ len .Containers }}' "`$name" 2>/dev/null || echo 1)"
      if [ "`$count" = "0" ]; then sudo docker network rm "`$name" >/dev/null; fi
      ;;
  esac
done
for ref in __IMAGE_ARGS__; do
  [ -n "`$ref" ] || continue
  case "`$ref" in
    ai-service-platform/*:*)
      if ! sudo docker ps -a --format '{{.Image}}' | grep -Fx -- "`$ref" >/dev/null; then
        sudo docker image rm "`$ref" >/dev/null 2>&1 || true
      fi
      ;;
  esac
done
'@
        $command = $command.Replace("__KEEP_DAYS__", (Quote-BashArg ([string]$KeepJobDays))).
            Replace("__PATH_ARGS__", $pathArgs).
            Replace("__CONTAINER_ARGS__", $containerArgs).
            Replace("__NETWORK_ARGS__", $networkArgs).
            Replace("__IMAGE_ARGS__", $imageArgs)
        Invoke-Ssh $alias $endpoint $command
    }
}

if (-not (Test-Path -LiteralPath $AuditJson -PathType Leaf)) {
    Fail "audit JSON not found: $AuditJson"
}

$report = Get-Content -LiteralPath $AuditJson -Raw | ConvertFrom-Json
$plan = Get-CleanupPlan $report
$plan | ConvertTo-Json -Depth 50
Invoke-CleanupPlan $plan

if (-not $Apply) {
    Write-Host "[PLAN] No changes made. Re-run with -Apply only after reviewing the JSON plan above."
}
