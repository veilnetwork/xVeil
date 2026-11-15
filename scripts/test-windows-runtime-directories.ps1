param(
  [Parameter(Mandatory=$true)][string]$ProbeExecutable,
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$Sha256
)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT'){throw 'This runtime ACL regression runs on Windows'}
$exe=(Resolve-Path -LiteralPath $ProbeExecutable).Path
if((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $Sha256){throw 'Selected probe differs from the reviewed build'}
$failures=0
foreach($mode in @('claim','lease','unsafe-claim','unsafe-lease','nested-claim','nested-lease','unsafe-parent-claim','unsafe-parent-lease','verify-shared')){
  $base=Join-Path ([Environment]::GetFolderPath('ApplicationData')) ('xveil-runtime-acl-'+[guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $base|Out-Null
  try {
    $acl=Get-Acl -LiteralPath $base;$acl.SetAccessRuleProtection($true,$false)
    $inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $propagation=[Security.AccessControl.PropagationFlags]::None
    $allow=[Security.AccessControl.AccessControlType]::Allow
    $current=[Security.Principal.WindowsIdentity]::GetCurrent().User;$acl.SetOwner($current)
    foreach($sid in @($current,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))){
      $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,$inherit,$propagation,$allow))
    }
    $rights=if($mode.StartsWith('unsafe-')){[Security.AccessControl.FileSystemRights]::FullControl}else{[Security.AccessControl.FileSystemRights]::ReadAndExecute}
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),$rights,$inherit,$propagation,$allow))
    Set-Acl -LiteralPath $base -AclObject $acl
    $result=& $exe $mode $base|ConvertFrom-Json
    $result|ConvertTo-Json -Compress
    if($LASTEXITCODE -ne 0 -or !$result.ok){$failures++}
  } finally {
    Remove-Item -LiteralPath $base -Recurse -Force
  }
}

if($failures -ne 0){throw ('Runtime regression failures: '+$failures)}
