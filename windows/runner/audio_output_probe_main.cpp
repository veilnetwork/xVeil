#include "audio_output_probe.h"

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, wchar_t*, int) {
  AudioProbeDeadline deadline(1500);
  if (!deadline.armed()) return 1;
  try {
    const auto json = AudioOutputSnapshotJson(
        ReadAudioOutputSnapshot(AudioProbeParentProcessId()));
    DWORD written = 0;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), json.data(),
                   static_cast<DWORD>(json.size()), &written, nullptr)) return 1;
    return written == json.size() ? 0 : 1;
  } catch (...) {
    return 1;  // No exception text, paths, COM IDs or device names on stderr.
  }
}
