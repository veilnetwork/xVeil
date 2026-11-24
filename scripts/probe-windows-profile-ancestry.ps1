param(
    [string]$Profile = $env:XVEIL_PROFILE,
    [string]$SupportDirectory
)

# Read-only triage for profilePreferencesOpenFailed / unsafeAncestor.
# Report fixed labels and depth, with 0 denoting the selected profile.
$ErrorActionPreference = 'Stop'
$report = [ordered]@{ schema = 'xveil-windows-profile-ancestry/1' }
$entry = $null

try {
    if ([string]::IsNullOrWhiteSpace($Profile)) { $Profile = 'default' }
    $Profile = $Profile.Trim().ToLowerInvariant()
    if ($Profile -notmatch '^[a-z0-9][a-z0-9._-]{0,31}$' -or $Profile.Contains('..')) {
        $report.result = 'invalid-profile'
        return
    }
    if ([string]::IsNullOrEmpty($SupportDirectory)) {
        $roaming = [Environment]::GetFolderPath('ApplicationData')
        if ([string]::IsNullOrEmpty($roaming)) {
            $report.result = 'application-data-unavailable'
            return
        }
        $SupportDirectory = Join-Path $roaming 'network.veil\xveil'
    }
    if ($SupportDirectory -notmatch '^[a-zA-Z]:[\\/]') {
        $report.result = 'non-drive-path'
        return
    }
    $support = [IO.DirectoryInfo]::new($SupportDirectory)
    $profiles = [IO.Path]::Combine($support.FullName, 'profiles')
    $selected = if ($Profile -eq 'default') { $support } else {
        [IO.DirectoryInfo]::new([IO.Path]::Combine($profiles, $Profile))
    }
    $ancestry = @()
    # Mirror the bounded ancestor walk in the profile admission code.
    for ($dir = $selected; $null -ne $dir -and $ancestry.Count -lt 256; $dir = $dir.Parent) {
        $position = if ($dir.FullName -eq $support.FullName) { 'app-support' }
        elseif ($dir.FullName -eq $selected.FullName) { 'profile' }
        elseif ($dir.FullName -eq $profiles) { 'profiles' }
        elseif ($null -eq $dir.Parent) { 'drive-root' }
        else { 'ancestor' }
        $ancestry += @{ path = $dir.FullName; position = $position; depth = $ancestry.Count }
    }
    if ($null -ne $dir) {
        $report.result = 'ancestry-too-deep'
        return
    }
    # Check from the root so a reparse point is reported without following it.
    for ($i = $ancestry.Count - 1; $i -ge 0; $i--) {
        $entry = $ancestry[$i]
        $item = Get-Item -LiteralPath $entry.path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $report.result = 'reparse-point'
            return
        }
        if (!$item.PSIsContainer) {
            $report.result = 'not-directory'
            return
        }
    }
    $trusted = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        'S-1-5-18'
        'S-1-5-32-544'
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    )
    # Keep the ancestor mask in sync with managedWindowsAclPolicy.
    $risk = [ordered]@{
        deleteChild = 0x00000040
        delete = 0x00010000
        changePermissions = 0x00040000
        changeOwner = 0x00080000
        genericAll = 0x10000000
        genericWrite = 0x40000000
    }
    foreach ($entry in $ancestry) {
        $acl = Get-Acl -LiteralPath $entry.path
        $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new(
            $acl.GetSecurityDescriptorBinaryForm(), 0)
        if (!$descriptor.Owner -or $descriptor.Owner.Value -notin $trusted) {
            $report.result = 'untrusted-owner'
            return
        }
        if ($null -eq $descriptor.DiscretionaryAcl) {
            $report.result = 'null-dacl'
            return
        }
        $rights = 0
        foreach ($ace in $descriptor.DiscretionaryAcl) {
            if ($ace.AceType -eq [Security.AccessControl.AceType]::AccessDenied) { continue }
            if ($ace.AceType -ne [Security.AccessControl.AceType]::AccessAllowed) {
                $report.result = 'unsupported-ace'
                return
            }
            if (([int]$ace.AceFlags -band [int][Security.AccessControl.AceFlags]::InheritOnly) -or
                $ace.SecurityIdentifier.Value -in $trusted) { continue }
            $rights = $rights -bor $ace.AccessMask
        }
        $blocked = @($risk.Keys | Where-Object { $rights -band $risk[$_] })
        if ($blocked.Count -gt 0) {
            $report.result = 'unsafe-grant'
            $report.rights = $blocked
            return
        }
    }
    $entry = $null
    $report.result = 'no-unsafe-ancestor-observed'
} catch [System.Management.Automation.ItemNotFoundException] {
    $report.result = 'missing-directory'
} catch {
    $report.result = 'inspection-failed'
} finally {
    if ($null -ne $entry) {
        $report.position = $entry.position
        $report.depth = $entry.depth
    }
    $report | ConvertTo-Json -Compress
}
