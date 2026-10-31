#include "audio_output_probe.h"

#include <cstring>
#include <iostream>

int main(int argc, char** argv) {
  if (argc == 2 && std::strcmp(argv[1], "stall") == 0) {
    AudioProbeDeadline deadline(100);
    if (!deadline.armed()) return 8;
    Sleep(5000);
    return 9;  // The watchdog must terminate this fixture with exit code 124.
  }
  {
    AudioProbeDeadline deadline(500);
    if (!deadline.armed()) return 8;
  }
  Sleep(750);  // A cancelled watchdog must not terminate the caller later.
  AudioOutputSnapshot snapshot;
  snapshot.success = true;
  snapshot.session_state = 1;
  snapshot.output_volume_percent = 0;
  snapshot.output_muted = false;
  snapshot.app_volume_percent = 100;
  snapshot.app_muted = false;
  if (AudioOutputSnapshotJson(AudioOutputSnapshot{}).find("outputVolumePercent") !=
      std::string::npos) return 7;
  std::cout << AudioOutputSnapshotJson(snapshot);
  return 0;
}
