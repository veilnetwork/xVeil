# SPDX-License-Identifier: MIT
# Run explicitly with xVeil and other camera apps closed. Does not open any
# profile, grant permissions, change ACLs, record media or upload a report.
param(
  [ValidateRange(0, 15)][int]$CameraIndex = 0,
  [switch]$TestDeadline
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-camera-probe-report.ps1')
if (Get-Process xveil -ErrorAction SilentlyContinue) {
  throw 'Close xVeil before testing: a live call may already own the camera.'
}
$repo = Split-Path -Parent $PSScriptRoot
$owned = Join-Path ([IO.Path]::GetTempPath()) ('xveil-camera-probe-' + [guid]::NewGuid().ToString('N'))
$oldInclude = $env:INCLUDE
$oldLib = $env:LIB
$process = $null
$started = $false
New-Item -ItemType Directory $owned | Out-Null
try {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
  if (-not $vs) { throw 'MSVC build tools are required for this source probe.' }
  $tools = Get-ChildItem (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
  $kits = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots').KitsRoot10
  $version = Get-ChildItem (Join-Path $kits 'Lib') -Directory | Where-Object { $_.Name -like '10.*' } | Sort-Object Name -Descending | Select-Object -First 1
  $env:INCLUDE = (@((Join-Path $tools.FullName 'include')) + @('ucrt', 'shared', 'um', 'winrt' | ForEach-Object { Join-Path $kits ('Include\' + $version.Name + '\' + $_) })) -join ';'
  $env:LIB = @((Join-Path $tools.FullName 'lib\x64'), (Join-Path $version.FullName 'um\x64'), (Join-Path $version.FullName 'ucrt\x64')) -join ';'
  $compiler = Join-Path $tools.FullName 'bin\Hostx64\x64\cl.exe'
  $binary = Join-Path $owned 'camera-probe.exe'
  $object = Join-Path $owned 'camera-probe.obj'
  $compileLog = Join-Path $owned 'compile-private.log'
  & $compiler /nologo /std:c++17 /EHsc /O2 /MT /W4 /WX /experimental:deterministic "/pathmap:$repo=C:\xveil-camera-probe" `
    "/I$(Join-Path $repo 'third_party\veil\flutter\veil_media\src')" `
    (Join-Path $PSScriptRoot 'windows-camera-probe.cpp') "/Fo$object" "/Fe$binary" `
    /link mf.lib mfplat.lib mfreadwrite.lib mfuuid.lib ole32.lib > $compileLog 2>&1
  if ($LASTEXITCODE -ne 0) {
    # Compiler paths are operator-only verbose output, never camera report data.
    Write-Verbose ([IO.File]::ReadAllText($compileLog))
    throw 'Camera probe compilation failed; no capture was attempted.'
  }
  $start = New-Object Diagnostics.ProcessStartInfo
  $start.FileName = $binary
  $start.Arguments = if ($TestDeadline) { '--test-stall' } else { [string]$CameraIndex }
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $process = New-Object Diagnostics.Process
  $process.StartInfo = $start
  $null = $process.Start()
  $started = $true
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit(15000)) {
    $process.Kill()
    $process.WaitForExit()
    throw 'Camera probe exceeded its watchdog; no success is reported.'
  }
  if ($TestDeadline) {
    if ($process.ExitCode -ne 124) { throw 'Camera watchdog test failed.' }
    Write-Output 'Camera watchdog test passed.'
  } elseif ($process.ExitCode -eq 124) {
    Write-Output '{"schema":"xveil-camera-probe/1","stage":12,"timedOut":true}'
  } elseif ($process.ExitCode -in @(0, 1)) {
    # Reconstruct the allowlist: never forward native stdout or driver stderr.
    $report = $stdout.GetAwaiter().GetResult() | ConvertFrom-Json
    $anonymous = ConvertTo-AnonymousCameraProbeReport $report
    if (($process.ExitCode -eq 0) -ne ($report.stage -eq 0)) { throw 'Camera probe exit/result mismatch.' }
    Write-Output $anonymous
  } else { throw 'Camera probe failed before producing a report.' }
} finally {
  if ($process) { if ($started -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }; $process.Dispose() }
  $env:INCLUDE = $oldInclude
  $env:LIB = $oldLib
  Remove-Item -LiteralPath $owned -Recurse -Force
}
