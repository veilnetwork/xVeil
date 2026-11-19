param(
  [Parameter(Mandatory=$true)][string]$ProbeExecutable,
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$Sha256,
  [switch]$AdministratorsOwner
)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT'){throw 'This ACL regression runs on Windows'}
$exe=(Resolve-Path -LiteralPath $ProbeExecutable).Path
if((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $Sha256){throw 'The selected probe differs from the reviewed build'}
# Match the application's profile ancestry. A machine's Temp may deliberately
# allow other principals to replace children and is then correctly refused.
$fixture=Join-Path ([Environment]::GetFolderPath('ApplicationData')) ('xveil-prefs-acl-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture|Out-Null
try {
  # Independent fixture oracle: read-only Everyone access is stable for a
  # profile directory, but must never be inherited by its preference payloads.
  $acl=Get-Acl -LiteralPath $fixture
  $acl.SetAccessRuleProtection($true,$false)
  $inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
  $propagation=[Security.AccessControl.PropagationFlags]::None
  $allow=[Security.AccessControl.AccessControlType]::Allow
  $current=[Security.Principal.WindowsIdentity]::GetCurrent().User
  $administrators=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
  $owner=$current
  $ownerArg=@()
  if($AdministratorsOwner){
    $owner=$administrators
    $ownerArg=@('administrators')
  }
  $acl.SetOwner($owner)
  foreach($sid in @($current,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),$administrators)){
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,$inherit,$propagation,$allow))
  }
  $everyone=[Security.Principal.SecurityIdentifier]::new('S-1-1-0')
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($everyone,[Security.AccessControl.FileSystemRights]::ReadAndExecute,$inherit,$propagation,$allow))
  Set-Acl -LiteralPath $fixture -AclObject $acl
  foreach($mode in @('exercise','verify')){
    $result=& $exe $mode $fixture @ownerArg|ConvertFrom-Json
    $result|ConvertTo-Json -Compress
    if($LASTEXITCODE -ne 0 -or !$result.ok){throw ('Preference '+$mode+' regression failed')}
  }
} finally {
  Remove-Item -LiteralPath $fixture -Recurse -Force
}
