# SPDX-License-Identifier: MIT
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-camera-probe-report.ps1')
$passed = 0
$base = '{"schema":"xveil-camera-probe/1","stage":6,"hresult":2147943568,"cameraCount":1,"samples":0,"countCapped":false}'
$report = $base | ConvertFrom-Json
$report | Add-Member -NotePropertyName devicePath -NotePropertyValue 'PRIVATE_PATH'
$report | Add-Member -NotePropertyName deviceName -NotePropertyValue 'PRIVATE_NAME'
$safe = ConvertTo-AnonymousCameraProbeReport $report
if ($safe -match 'PRIVATE_|devicePath|deviceName') { throw 'Private camera fields escaped.' }
if (($safe | ConvertFrom-Json).hresult -ne 2147943568) { throw 'Numeric HRESULT was lost.' }
$passed++
foreach ($entry in @(
  @('schema', 'private'), @('stage', -1), @('stage', 12), @('stage', '6'),
  @('hresult', -1), @('hresult', 4294967296), @('hresult', 'PRIVATE_VALUE'),
  @('cameraCount', 17), @('cameraCount', 1.5), @('samples', 9),
  @('samples', $null), @('countCapped', 'false'), @('stage', 0)
)) {
  $bad = $base | ConvertFrom-Json
  $bad.($entry[0]) = $entry[1]
  $rejected = $false
  try { $null = ConvertTo-AnonymousCameraProbeReport $bad } catch { $rejected = $true }
  if (-not $rejected) { throw 'Malformed camera report was accepted.' }
  $passed++
}
$positive = '{"schema":"xveil-camera-probe/1","stage":0,"hresult":0,"cameraCount":1,"samples":8,"countCapped":false}' | ConvertFrom-Json
$null = ConvertTo-AnonymousCameraProbeReport $positive
$passed++
Write-Output "Camera report checks passed: $passed"
& (Join-Path $PSScriptRoot 'probe-windows-camera.ps1') -TestDeadline
