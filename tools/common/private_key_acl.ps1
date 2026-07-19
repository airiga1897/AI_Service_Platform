function Test-IsWindowsPlatform {
    return ($PSVersionTable.PSEdition -eq "Desktop") `
        -or ($PSVersionTable.ContainsKey("Platform") -and $PSVersionTable.Platform -eq "Win32NT") `
        -or ($env:OS -eq "Windows_NT")
}

function Get-IdentitySidValue($IdentityReference) {
    try {
        return $IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        if ($IdentityReference -is [System.Security.Principal.SecurityIdentifier]) {
            return $IdentityReference.Value
        }
        return ""
    }
}

function Test-FileSystemRuleHasReadAccess($Rule) {
    $rights = $Rule.FileSystemRights
    return (($rights -band [System.Security.AccessControl.FileSystemRights]::Read) -ne 0) `
        -or (($rights -band [System.Security.AccessControl.FileSystemRights]::ReadData) -ne 0) `
        -or (($rights -band [System.Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne 0) `
        -or (($rights -band [System.Security.AccessControl.FileSystemRights]::Modify) -ne 0) `
        -or (($rights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne 0)
}

function Get-OpenSshPrivateKeyAclProblemEntries($KeyFile) {
    if (-not (Test-IsWindowsPlatform)) {
        return @()
    }

    $currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowedSids = @(
        $currentUserSid,
        "S-1-5-18",     # NT AUTHORITY\SYSTEM
        "S-1-5-32-544"  # BUILTIN\Administrators
    )

    $acl = Get-Acl -LiteralPath $KeyFile
    $problems = @()

    foreach ($entry in $acl.Access) {
        if ($entry.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            continue
        }
        if (-not (Test-FileSystemRuleHasReadAccess $entry)) {
            continue
        }

        $sid = Get-IdentitySidValue $entry.IdentityReference
        if ($allowedSids -contains $sid) {
            continue
        }

        $problems += [PSCustomObject]@{
            Identity = [string]$entry.IdentityReference
            Sid = $sid
            Inherited = $entry.IsInherited
            Rights = [string]$entry.FileSystemRights
        }
    }

    return @($problems)
}

function Get-OpenSshPrivateKeyAclProblems($KeyFile) {
    $entries = @(Get-OpenSshPrivateKeyAclProblemEntries $KeyFile)
    return @($entries | ForEach-Object {
        $inherited = if ($_.Inherited) { "inherited" } else { "explicit" }
        "{0} ({1}, rights={2})" -f $_.Identity, $inherited, $_.Rights
    })
}

function Repair-OpenSshPrivateKeyAcl($KeyFile) {
    if (-not (Test-IsWindowsPlatform)) {
        return
    }

    $resolvedPath = (Resolve-Path -LiteralPath $KeyFile).Path
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $currentUserSid = $currentIdentity.User.Value

    Write-Host "Fixing OpenSSH private key ACL for $resolvedPath"

    & icacls $resolvedPath "/inheritance:r" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed to disable inheritance for $resolvedPath"
    }

    $problemEntries = @(Get-OpenSshPrivateKeyAclProblemEntries $resolvedPath)
    foreach ($entry in $problemEntries) {
        $principal = if ($entry.Sid) { "*$($entry.Sid)" } else { $entry.Identity }
        & icacls $resolvedPath "/remove:g" $principal | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "icacls failed to remove ACL entry '$($entry.Identity)' from $resolvedPath"
        }
    }

    & icacls $resolvedPath "/grant:r" "*${currentUserSid}:F" "*S-1-5-18:F" "*S-1-5-32-544:F" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed to grant private key ACL for $resolvedPath"
    }
}

function Ensure-OpenSshPrivateKeyAcl($KeyFile) {
    if (-not (Test-IsWindowsPlatform)) {
        return
    }

    $problems = @(Get-OpenSshPrivateKeyAclProblems $KeyFile)
    if ($problems.Count -eq 0) {
        return
    }

    Repair-OpenSshPrivateKeyAcl $KeyFile
    $remaining = @(Get-OpenSshPrivateKeyAclProblems $KeyFile)
    if ($remaining.Count -gt 0) {
        throw "OpenSSH private key ACL is still too open after automatic repair for $KeyFile. Remaining readable principals: $($remaining -join '; ')"
    }
}
