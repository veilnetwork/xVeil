param(
  [Parameter(Mandatory=$true)][string]$VeilLibrary,
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$Sha256,
  [string]$Dart='dart'
)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT'){throw 'This packaged DLL regression runs on Windows'}
$repo=Split-Path $PSScriptRoot -Parent
$dll=(Resolve-Path -LiteralPath $VeilLibrary).Path
if((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -ne $Sha256){
  throw 'The selected Veil DLL does not match the reviewed build'
}
$owned=Join-Path ([IO.Path]::GetTempPath()) ('xveil-worker-loader-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $owned|Out-Null
try {
  # This probe imports only native_libs.dart and the Dart SDK. A minimal
  # package map avoids resolving unrelated Flutter/native-assets build hooks.
  $packages=@{configVersion=2;packages=@(@{
    name='xveil';rootUri=([Uri]($repo+[IO.Path]::DirectorySeparatorChar)).AbsoluteUri
    packageUri='lib/';languageVersion='3.12'
  })}|ConvertTo-Json -Depth 5
  $config=Join-Path $owned 'packages.json'
  [IO.File]::WriteAllText($config,$packages,[Text.UTF8Encoding]::new($false))
  $exe=Join-Path $owned 'probe.exe'
  & $Dart compile exe "--packages=$config" (Join-Path $repo 'test/native/probes/packaged_library_worker_probe.dart') -o $exe
  if($LASTEXITCODE -ne 0){throw 'Worker loader probe compile failed'}
  $packaged=Join-Path $owned 'veilclient_ffi.dll'
  Copy-Item -LiteralPath $dll -Destination $packaged
  if((Get-FileHash -LiteralPath $packaged -Algorithm SHA256).Hash -ne $Sha256){throw 'Copied DLL differs'}
  $decoy=Join-Path $owned 'unrelated-directory'
  New-Item -ItemType Directory -Path $decoy|Out-Null
  Push-Location $decoy
  try {
    $result=& $exe|ConvertFrom-Json
    if($LASTEXITCODE -ne 0 -or !$result.fresh_worker -or
       !$result.worker_after_parent_preload -or $result.process_scope_had_symbol){
      throw 'Fresh worker did not independently load its packaged DLL'
    }
    Move-Item -LiteralPath $packaged -Destination (Join-Path $decoy 'veilclient_ffi.dll')
    $negative=& $exe --missing-bundle|ConvertFrom-Json
    if($LASTEXITCODE -ne 0 -or !$negative.missing_bundle_refused){
      throw 'Missing packaged DLL was replaced by a working-directory DLL'
    }
  } finally {Pop-Location}
  Write-Output 'Fresh worker DLL lookup and working-directory refusal passed'
} finally {
  Remove-Item -LiteralPath $owned -Recurse -Force
}
