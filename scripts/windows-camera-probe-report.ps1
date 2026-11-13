# SPDX-License-Identifier: MIT
function ConvertTo-AnonymousCameraProbeReport($Report) {
  function IsBoundedInteger($Value, [long]$Maximum) {
    ($Value -is [int] -or $Value -is [long]) -and $Value -ge 0 -and $Value -le $Maximum
  }
  if ($Report.schema -cne 'xveil-camera-probe/1' -or
      -not (IsBoundedInteger $Report.stage 11) -or
      -not (IsBoundedInteger $Report.hresult 4294967295) -or
      -not (IsBoundedInteger $Report.cameraCount 16) -or
      -not (IsBoundedInteger $Report.samples 8) -or
      $Report.countCapped -isnot [bool] -or
      ($Report.stage -eq 0 -and ($Report.samples -eq 0 -or $Report.hresult -ge 2147483648))) {
    throw 'Invalid anonymous camera probe result.'
  }
  # Reconstruct fields; even an unexpected valid report must not forward
  # driver names, paths, private strings or arbitrary native log content.
  [ordered]@{schema='xveil-camera-probe/1';stage=$Report.stage;hresult=$Report.hresult;cameraCount=$Report.cameraCount;samples=$Report.samples;countCapped=$Report.countCapped} | ConvertTo-Json -Compress
}
