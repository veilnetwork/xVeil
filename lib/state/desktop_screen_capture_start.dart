/// Native desktop screen capture can stop the camera before failing to open
/// its replacement. Roll back the source queue and restore current camera
/// intent on failure, while leaving successful screen capture in charge.
bool startDesktopScreenCapture({
  required bool Function(bool screen) selectSource,
  required bool Function() startCapture,
  required bool Function() mayRestoreCamera,
  required void Function() restoreCamera,
}) {
  var captureAttempted = false;
  try {
    if (!selectSource(true)) return false;
    captureAttempted = true;
    if (startCapture()) return true;
  } catch (_) {
    // A native capture exception has the same rollback as a rejected start.
  }
  try {
    selectSource(false);
  } catch (_) {}
  if (captureAttempted && mayRestoreCamera()) {
    try {
      restoreCamera();
    } catch (_) {}
  }
  return false;
}
