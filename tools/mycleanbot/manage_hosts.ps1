param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("plan", "apply", "verify", "remove")]
    [string]$Action,

    [string]$Address = "172.31.1.11",

    [string]$Hostname = "mycleanbot.mine-craft.su",

    [string]$HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
)

$ErrorActionPreference = "Stop"
$Marker = "# ai-service-platform:mycleanbot"
$ManagedLine = "$Address`t$Hostname`t$Marker"

function Fail([string]$Message) {
    throw "MyCleanBot hosts error: $Message"
}

function Require-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail "apply/remove requires an elevated PowerShell session"
    }
}

if ($Address -ne "172.31.1.11") {
    Fail "only the approved private endpoint 172.31.1.11 is allowed"
}
if ($Hostname -ne "mycleanbot.mine-craft.su") {
    Fail "only mycleanbot.mine-craft.su is managed by this helper"
}
if (-not (Test-Path -LiteralPath $HostsPath -PathType Leaf)) {
    Fail "hosts file not found: $HostsPath"
}

$Lines = @([IO.File]::ReadAllLines((Resolve-Path -LiteralPath $HostsPath).Path))
$Managed = @($Lines | Where-Object { $_ -match [regex]::Escape($Marker) })
$UnmanagedConflicts = @(
    $Lines | Where-Object {
        $_ -notmatch "^\s*#" -and
        $_ -notmatch [regex]::Escape($Marker) -and
        $_ -match "(^|\s)$([regex]::Escape($Hostname))(\s|$)"
    }
)

if ($Managed.Count -gt 1) {
    Fail "more than one managed MyCleanBot hosts line exists"
}

switch ($Action) {
    "plan" {
        if ($UnmanagedConflicts.Count -gt 0) {
            Fail "an unmanaged hosts entry already references $Hostname"
        }
        $State = if ($Managed.Count -eq 1 -and $Managed[0].Trim() -eq $ManagedLine.Trim()) {
            "already-present"
        } elseif ($Managed.Count -eq 1) {
            "managed-entry-needs-replacement"
        } else {
            "will-add"
        }
        Write-Output "action=plan hostname=$Hostname address=$Address state=$State mutations=false"
    }
    "verify" {
        if ($Managed.Count -ne 1 -or $Managed[0].Trim() -ne $ManagedLine.Trim()) {
            Fail "the exact managed MyCleanBot hosts line is absent"
        }
        if ($UnmanagedConflicts.Count -gt 0) {
            Fail "an unmanaged hosts entry also references $Hostname"
        }
        Write-Output "action=verify hostname=$Hostname address=$Address state=present"
    }
    "apply" {
        Require-Administrator
        if ($UnmanagedConflicts.Count -gt 0) {
            Fail "an unmanaged hosts entry already references $Hostname"
        }
        if ($Managed.Count -eq 1 -and $Managed[0].Trim() -eq $ManagedLine.Trim()) {
            Write-Output "action=apply hostname=$Hostname address=$Address state=already-present"
            break
        }
        $ResolvedHosts = (Resolve-Path -LiteralPath $HostsPath).Path
        $BackupPath = "$ResolvedHosts.ai-service-platform-mycleanbot.bak"
        Copy-Item -LiteralPath $ResolvedHosts -Destination $BackupPath -Force
        $Updated = @($Lines | Where-Object { $_ -notmatch [regex]::Escape($Marker) })
        $Updated += $ManagedLine
        [IO.File]::WriteAllLines($ResolvedHosts, $Updated, [Text.UTF8Encoding]::new($false))
        Clear-DnsClientCache
        Write-Output "action=apply hostname=$Hostname address=$Address state=present backup=$BackupPath"
    }
    "remove" {
        Require-Administrator
        if ($Managed.Count -eq 0) {
            Write-Output "action=remove hostname=$Hostname state=already-absent"
            break
        }
        $ResolvedHosts = (Resolve-Path -LiteralPath $HostsPath).Path
        $BackupPath = "$ResolvedHosts.ai-service-platform-mycleanbot.remove.bak"
        Copy-Item -LiteralPath $ResolvedHosts -Destination $BackupPath -Force
        $Updated = @($Lines | Where-Object { $_ -notmatch [regex]::Escape($Marker) })
        [IO.File]::WriteAllLines($ResolvedHosts, $Updated, [Text.UTF8Encoding]::new($false))
        Clear-DnsClientCache
        Write-Output "action=remove hostname=$Hostname state=absent backup=$BackupPath"
    }
}
