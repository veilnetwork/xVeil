#include "audio_output_probe.h"

#include <audioclient.h>
#include <audiopolicy.h>
#include <endpointvolume.h>
#include <mmdeviceapi.h>
#include <tlhelp32.h>
#include <wrl/client.h>

#include <cmath>

using Microsoft::WRL::ComPtr;

namespace {
class ComScope {
 public:
  ComScope() : result_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
  ~ComScope() { if (SUCCEEDED(result_)) CoUninitialize(); }
  bool ready() const { return SUCCEEDED(result_); }
 private:
  HRESULT result_;
};

std::optional<std::wstring> EndpointId(IMMDevice* device) {
  if (!device) return std::nullopt;
  LPWSTR value = nullptr;
  if (FAILED(device->GetId(&value))) return std::nullopt;
  const std::wstring copy = value ? value : L"";
  CoTaskMemFree(value);
  return copy.empty() ? std::nullopt : std::make_optional(copy);
}

std::optional<int> Percent(float value) {
  if (!std::isfinite(value) || value < 0 || value > 1) return std::nullopt;
  return static_cast<int>(std::lround(value * 100));
}

void BoolField(std::string& json, const char* name, std::optional<bool> value) {
  if (value) json += std::string(",\"") + name + "\":" + (*value ? "true" : "false");
}
void IntField(std::string& json, const char* name, std::optional<int> value) {
  if (value) json += std::string(",\"") + name + "\":" + std::to_string(*value);
}
}  // namespace

AudioOutputSnapshot ReadAudioOutputSnapshot(DWORD process_id) {
  AudioOutputSnapshot result;
  ComScope com;
  if (!com.ready() || process_id == 0) return result;
  ComPtr<IMMDeviceEnumerator> enumerator;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                             IID_PPV_ARGS(&enumerator)))) return result;
  ComPtr<IMMDevice> console, communications;
  enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &console);
  enumerator->GetDefaultAudioEndpoint(eRender, eCommunications, &communications);
  const auto console_id = EndpointId(console.Get());
  const auto communications_id = EndpointId(communications.Get());
  if (console_id && communications_id) {
    result.default_outputs_same = *console_id == *communications_id;
  }

  ComPtr<IMMDeviceCollection> devices;
  UINT device_count = 0;
  if (FAILED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &devices)) ||
      FAILED(devices->GetCount(&device_count)) || device_count > 32) return result;
  bool complete = true;
  int active = 0;
  AudioOutputSnapshot selected;
  for (UINT i = 0; i < device_count; ++i) {
    ComPtr<IMMDevice> device;
    ComPtr<IAudioSessionManager2> manager;
    ComPtr<IAudioSessionEnumerator> sessions;
    int count = 0;
    if (FAILED(devices->Item(i, &device)) ||
        FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL,
                                nullptr, &manager)) ||
        FAILED(manager->GetSessionEnumerator(&sessions)) ||
        FAILED(sessions->GetCount(&count)) || count < 0 || count > 128) {
      complete = false;
      continue;
    }
    for (int index = 0; index < count; ++index) {
      ComPtr<IAudioSessionControl> base;
      ComPtr<IAudioSessionControl2> control;
      DWORD owner = 0;
      AudioSessionState state = AudioSessionStateInactive;
      if (FAILED(sessions->GetSession(index, &base)) || FAILED(base.As(&control)) ||
          FAILED(control->GetProcessId(&owner))) {
        complete = false;
        continue;
      }
      if (owner != process_id) continue;
      if (FAILED(control->GetState(&state))) { complete = false; continue; }
      if (state != AudioSessionStateActive) continue;
      active = (active == 0) ? 1 : 2;
      if (active > 1) continue;

      ComPtr<ISimpleAudioVolume> app_volume;
      ComPtr<IAudioEndpointVolume> output_volume;
      float volume = 0;
      BOOL muted = FALSE;
      if (SUCCEEDED(base.As(&app_volume))) {
        if (SUCCEEDED(app_volume->GetMasterVolume(&volume))) selected.app_volume_percent = Percent(volume);
        if (SUCCEEDED(app_volume->GetMute(&muted))) selected.app_muted = muted != FALSE;
      }
      if (SUCCEEDED(device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL,
                                     nullptr, &output_volume))) {
        if (SUCCEEDED(output_volume->GetMasterVolumeLevelScalar(&volume))) selected.output_volume_percent = Percent(volume);
        if (SUCCEEDED(output_volume->GetMute(&muted))) selected.output_muted = muted != FALSE;
      }
      const auto id = EndpointId(device.Get());
      if (id && console_id) selected.uses_default_output = *id == *console_id;
      if (id && communications_id) selected.uses_communications_output = *id == *communications_id;
    }
  }
  // An incomplete enumeration cannot prove how many sessions exist, nor which
  // session owns the observed output. Never publish a guessed zero/default.
  if (!complete) return result;
  result.session_state = active;
  result.success = true;
  if (active == 1) {
    selected.session_state = 1;
    selected.default_outputs_same = result.default_outputs_same;
    selected.success = selected.app_volume_percent.has_value() &&
        selected.app_muted.has_value() && selected.output_volume_percent.has_value() &&
        selected.output_muted.has_value();
    return selected;
  }
  return result;
}

std::string AudioOutputSnapshotJson(const AudioOutputSnapshot& value) {
  std::string json = "{\"schema\":\"xveil-audio-output/1\",\"success\":";
  json += value.success ? "true" : "false";
  IntField(json, "sessionState", value.session_state);
  IntField(json, "outputVolumePercent", value.output_volume_percent);
  BoolField(json, "outputMuted", value.output_muted);
  IntField(json, "appVolumePercent", value.app_volume_percent);
  BoolField(json, "appMuted", value.app_muted);
  BoolField(json, "usesDefaultOutput", value.uses_default_output);
  BoolField(json, "usesCommunicationsOutput", value.uses_communications_output);
  BoolField(json, "defaultOutputsSame", value.default_outputs_same);
  return json + "}";
}

DWORD AudioProbeParentProcessId() {
  const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return 0;
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  DWORD parent = 0;
  if (Process32FirstW(snapshot, &entry)) {
    do {
      if (entry.th32ProcessID == GetCurrentProcessId()) {
        parent = entry.th32ParentProcessID;
        break;
      }
    } while (Process32NextW(snapshot, &entry));
  }
  CloseHandle(snapshot);
  return parent;
}
