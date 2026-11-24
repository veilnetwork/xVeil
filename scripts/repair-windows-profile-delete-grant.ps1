# Run in the same Windows account as xVeil, with xVeil closed.
# This tool edits only the ordinary xVeil app-data directory's explicit ACL.
$ErrorActionPreference = 'Stop'
$handles = [Collections.Generic.List[IDisposable]]::new()
$result = 'failed'
try {
    $roaming = [Environment]::GetFolderPath('ApplicationData')
    if ($roaming -notmatch '^[a-zA-Z]:[\\/]') {
        throw 'Windows Roaming AppData must be on a local drive.'
    }
    $folder = [IO.DirectoryInfo]::new((Join-Path $roaming 'network.veil\xveil'))
    if (-not ('XVeilAclRepair.DirectoryGuard' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace XVeilAclRepair {
    public static class DirectoryGuard {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string path, uint access, uint share, IntPtr security,
            uint disposition, uint flags, IntPtr template);

        [StructLayout(LayoutKind.Sequential)]
        private struct AttributeTagInfo {
            public uint Attributes;
            public uint ReparseTag;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandleEx(
            SafeFileHandle file, int informationClass, out AttributeTagInfo info, int size);

        public static SafeFileHandle Open(string path) {
            // FILE_LIST_DIRECTORY with FILE_SHARE_READ | FILE_SHARE_WRITE,
            // OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT.
            var handle = CreateFile(path, 1, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            try {
                if (handle.IsInvalid) throw new Win32Exception();
                AttributeTagInfo info;
                if (!GetFileInformationByHandleEx(handle, 9, out info, 8))
                    throw new Win32Exception();
                if ((info.Attributes & 0x410) != 0x10)
                    throw new InvalidOperationException("Expected a directory without a reparse point.");
                return handle;
            } catch {
                handle.Dispose();
                throw;
            }
        }
    }
}
'@
    }
    $chain = [Collections.Generic.List[string]]::new()
    for ($dir = $folder; $null -ne $dir; $dir = $dir.Parent) {
        $chain.Add($dir.FullName)
    }
    for ($i = $chain.Count - 1; $i -ge 0; $i--) {
        $handles.Add([XVeilAclRepair.DirectoryGuard]::Open($chain[$i]))
    }

    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $trusted = @($user, 'S-1-5-18', 'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $acl = Get-Acl -LiteralPath $folder.FullName
    $original = $acl.GetSecurityDescriptorBinaryForm()
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($original, 0)
    if ($descriptor.Owner.Value -notin @($user, 'S-1-5-32-544') -or
        $null -eq $descriptor.DiscretionaryAcl) {
        throw 'The directory owner or ACL requires manual review.'
    }
    $dacl = $descriptor.DiscretionaryAcl
    $changed = [Collections.Generic.List[string]]::new()
    for ($i = $dacl.Count - 1; $i -ge 0; $i--) {
        $ace = $dacl[$i]
        if ($ace.AceType -eq [Security.AccessControl.AceType]::AccessDenied) { continue }
        if ($ace.AceType -ne [Security.AccessControl.AceType]::AccessAllowed) {
            throw 'The ACL contains a rule this repair tool cannot review.'
        }
        if (([int]$ace.AceFlags -band [int][Security.AccessControl.AceFlags]::InheritOnly) -or
            $ace.SecurityIdentifier.Value -in $trusted) { continue }
        $blocked = $ace.AccessMask -band 0x500d0040
        if ($blocked -eq 0) { continue }
        if ($ace.IsInherited) {
            $result = 'inherited'
            throw 'An inherited grant requires manual review. No rights were changed.'
        }
        if ($blocked -ne 0x10000) {
            $result = 'other-unsafe-right'
            throw 'Another unsafe right requires manual review. No rights were changed.'
        }
        $principal = $ace.SecurityIdentifier
        try { $principal = $principal.Translate([Security.Principal.NTAccount]) } catch {}
        $changed.Add($principal.Value)
        $ace.AccessMask = $ace.AccessMask -band (-bnot 0x10000)
        if ($ace.AccessMask -eq 0) { $dacl.RemoveAce($i) }
    }
    if ($changed.Count -eq 0) {
        $result = 'no-explicit-delete'
        return
    }

    Write-Host "Directory  $($folder.FullName)"
    $principals = ($changed | Sort-Object -Unique) -join ', '
    Write-Host "Remove only DELETE from  $principals"
    if ((Read-Host 'Type REMOVE DELETE to confirm') -cne 'REMOVE DELETE') {
        $result = 'cancelled'
        return
    }
    $latest = (Get-Acl -LiteralPath $folder.FullName).GetSecurityDescriptorBinaryForm()
    if ([Convert]::ToBase64String($original) -cne [Convert]::ToBase64String($latest)) {
        $result = 'acl-changed'
        throw 'The security descriptor changed during review. Rerun the tool.'
    }
    $updated = [byte[]]::new($descriptor.BinaryLength)
    $descriptor.GetBinaryForm($updated, 0)
    $acl.SetSecurityDescriptorBinaryForm($updated, [Security.AccessControl.AccessControlSections]::Access)
    Set-Acl -LiteralPath $folder.FullName -AclObject $acl
    $result = 'applied'
} finally {
    for ($i = $handles.Count - 1; $i -ge 0; $i--) {
        $handles[$i].Dispose()
    }
    [ordered]@{ schema = 'xveil-windows-acl-repair/1'; result = $result } |
        ConvertTo-Json -Compress
}
