#ifndef RUNNER_AUDIO_OUTPUT_PROBE_H_
#define RUNNER_AUDIO_OUTPUT_PROBE_H_

#include <windows.h>

#include <optional>
#include <string>

// No endpoint/session identifiers or device labels cross this boundary.
struct AudioOutputSnapshot {
  bool success = false;
  // 0=no active render session, 1=one, 2=multiple; absent=unknown.
  std::optional<int> session_state;
  std::optional<int> output_volume_percent;
  std::optional<bool> output_muted;
  std::optional<int> app_volume_percent;
  std::optional<bool> app_muted;
  std::optional<bool> uses_default_output;
  std::optional<bool> uses_communications_output;
  std::optional<bool> default_outputs_same;
};

AudioOutputSnapshot ReadAudioOutputSnapshot(DWORD process_id);
std::string AudioOutputSnapshotJson(const AudioOutputSnapshot& snapshot);
DWORD AudioProbeParentProcessId();

// A separate, read-only process isolates slow/broken device COM providers from
// the Flutter thread. Its hard deadline also applies if the caller disappears.
class AudioProbeDeadline {
 public:
  explicit AudioProbeDeadline(DWORD milliseconds) {
    if (!CreateTimerQueueTimer(&timer_, nullptr, Expired, nullptr, milliseconds,
                              0, WT_EXECUTEONLYONCE)) {
      timer_ = nullptr;
    }
  }
  ~AudioProbeDeadline() {
    if (timer_) DeleteTimerQueueTimer(nullptr, timer_, INVALID_HANDLE_VALUE);
  }
  bool armed() const { return timer_ != nullptr; }
  AudioProbeDeadline(const AudioProbeDeadline&) = delete;
  AudioProbeDeadline& operator=(const AudioProbeDeadline&) = delete;

 private:
  static void CALLBACK Expired(void*, BOOLEAN) {
    TerminateProcess(GetCurrentProcess(), 124);
  }
  HANDLE timer_ = nullptr;
};

#endif
