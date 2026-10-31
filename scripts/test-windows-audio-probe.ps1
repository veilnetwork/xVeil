$ErrorActionPreference = 'Stop'
# Tests only: compile the production serializer/watchdog, without opening an
# audio device or starting the app. No ATL/plugin build is required.
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if (-not $visualStudio) { throw 'MSVC build tools are required' }
  Import-Module (Join-Path $visualStudio 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
  Enter-VsDevShell -VsInstallPath $visualStudio -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
}
$repo = Split-Path $PSScriptRoot -Parent
$sources = Join-Path $repo 'windows\runner'
$fixture = Join-Path $repo 'test\native\windows_audio_output_test.cpp'
$ownedOutput = Join-Path ([IO.Path]::GetTempPath()) ('xveil-audio-probe-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ownedOutput | Out-Null
Push-Location $ownedOutput
try {
  & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MD /DNOMINMAX "/I$sources" $fixture (Join-Path $sources 'audio_output_probe.cpp') /link ole32.lib /OUT:audio_output_test.exe
  if ($LASTEXITCODE -ne 0) { throw 'Native audio probe test compile failed' }
  $json = & .\audio_output_test.exe
  if ($LASTEXITCODE -ne 0) { throw 'Cancelled deadline/serializer test failed' }
  $snapshot = $json | ConvertFrom-Json
  if ($snapshot.outputVolumePercent -ne 0 -or $snapshot.outputMuted -ne $false -or
      $snapshot.appVolumePercent -ne 100 -or $snapshot.appMuted -ne $false) {
    throw 'The serializer lost valid zero/false values'
  }
  $stall = Start-Process -FilePath (Join-Path $ownedOutput 'audio_output_test.exe') -ArgumentList 'stall' -Wait -PassThru -NoNewWindow
  $stallExit = $stall.ExitCode
  $stall.Dispose()
  if ($stallExit -ne 124) { throw 'The native hard deadline did not fire' }
  Write-Output 'Audio probe serializer, cancellation and hard deadline passed'
} finally {
  Pop-Location
  Remove-Item $ownedOutput -Recurse -Force
}
