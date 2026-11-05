// Production media DLL, real Windows ADM, synthetic RTP at the Veil boundary.
// No microphone capture, PCM recording, network, or persistent audio changes.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <audiopolicy.h>
#include <endpointvolume.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>
#include "audio_output_probe.h"

using Microsoft::WRL::ComPtr;
using Clock = std::chrono::steady_clock;

template <typename T> T Symbol(HMODULE module, const char* name) {
  auto value = reinterpret_cast<T>(GetProcAddress(module, name));
  if (!value) throw std::runtime_error("missing fixture API");
  return value;
}

static ComPtr<IAudioMeterInformation> SessionMeter() {
  ComPtr<IMMDeviceEnumerator> enumerator;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                             IID_PPV_ARGS(&enumerator)))) return {};
  ComPtr<IMMDeviceCollection> devices;
  UINT count = 0;
  if (FAILED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &devices)) ||
      FAILED(devices->GetCount(&count)) || count > 32) return {};
  ComPtr<IAudioMeterInformation> selected;
  int matches = 0;
  for (UINT i = 0; i < count; ++i) {
    ComPtr<IMMDevice> device;
    ComPtr<IAudioSessionManager2> manager;
    ComPtr<IAudioSessionEnumerator> sessions;
    int length = 0;
    if (FAILED(devices->Item(i, &device)) ||
        FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL,
                                nullptr, &manager)) ||
        FAILED(manager->GetSessionEnumerator(&sessions)) ||
        FAILED(sessions->GetCount(&length)) || length < 0 || length > 128) return {};
    for (int j = 0; j < length; ++j) {
      ComPtr<IAudioSessionControl> session;
      ComPtr<IAudioSessionControl2> control;
      DWORD pid = 0;
      AudioSessionState state = AudioSessionStateInactive;
      if (FAILED(sessions->GetSession(j, &session)) || FAILED(session.As(&control)) ||
          FAILED(control->GetProcessId(&pid))) return {};
      if (pid != GetCurrentProcessId()) continue;
      if (FAILED(control->GetState(&state))) return {};
      if (state != AudioSessionStateActive) continue;
      ++matches;
      if (FAILED(session.As(&selected))) return {};
    }
  }
  return matches == 1 ? selected : ComPtr<IAudioMeterInformation>{};
}

struct Fixture {
  uint32_t packet_ms;
  std::vector<std::vector<uint8_t>> packets;
};
static Fixture ReadFixture(const wchar_t* path) {
  std::ifstream file(path, std::ios::binary);
  auto word = [&] {
    uint32_t value = 0;
    if (!file.read(reinterpret_cast<char*>(&value), 4))
      throw std::runtime_error("truncated fixture");
    return value;
  };
  char magic[4];
  if (!file.read(magic, 4) || std::string(magic, 4) != "XVR2")
    throw std::runtime_error("invalid fixture");
  const auto count = word();
  const auto packet_ms = word();
  if ((packet_ms != 20 && packet_ms != 40 && packet_ms != 60) ||
      count != 12000 / packet_ms) throw std::runtime_error("unexpected fixture length");
  std::vector<std::vector<uint8_t>> packets;
  for (uint32_t i = 0; i < count; ++i) {
    const auto size = word();
    if (size < 12 || size > 16384) throw std::runtime_error("invalid packet");
    packets.emplace_back(size);
    if (!file.read(reinterpret_cast<char*>(packets.back().data()), size))
      throw std::runtime_error("truncated packet");
  }
  if (file.peek() != std::char_traits<char>::eof())
    throw std::runtime_error("trailing fixture bytes");
  return {packet_ms, std::move(packets)};
}

int wmain(int argc, wchar_t** argv) {
  if (argc != 4) return 2;  // fixture DLL, production media DLL, RTP fixture
  AudioProbeDeadline deadline(40000);
  if (!deadline.armed()) return 3;
  const auto initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) return 4;
  struct ComCleanup { ~ComCleanup() { CoUninitialize(); } } com_cleanup;
  timeBeginPeriod(1);
  struct TimerCleanup { ~TimerCleanup() { timeEndPeriod(1); } } timer_cleanup;
  void* engine = nullptr;
  void (__cdecl* destroy)(void*) = nullptr;
  std::thread source;
  try {
    const auto fixture = ReadFixture(argv[3]);
    const auto flags = LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS;
    HMODULE boundary = LoadLibraryExW(argv[1], nullptr, flags);
    HMODULE media = LoadLibraryExW(argv[2], nullptr, flags);
    if (!boundary || !media) throw std::runtime_error("load refused");
    auto create = Symbol<void* (__cdecl*)(uint64_t, const uint8_t*, const uint8_t*)>(
        media, "veil_media_engine_create");
    auto start = Symbol<int (__cdecl*)(void*, int, int)>(media, "veil_media_engine_start_audio");
    destroy = Symbol<void (__cdecl*)(void*)>(media, "veil_media_engine_destroy");
    auto stats = Symbol<char* (__cdecl*)(void*)>(media, "veil_media_engine_get_stats");
    auto free_string = Symbol<void (__cdecl*)(char*)>(media, "veil_media_free_string");
    auto deliver = Symbol<int (__cdecl*)(const uint8_t*, size_t)>(boundary, "probe_deliver");
    auto registered = Symbol<int (__cdecl*)()>(boundary, "probe_registered");
    std::array<uint8_t, 32> local{}, peer{};
    local.fill(1); peer.fill(2);
    engine = create(777, local.data(), peer.data());
    if (!engine || registered() != 1) throw std::runtime_error("create refused");
    const int result = start(engine, 0, 1);
    std::printf("{\"kind\":\"start\",\"result\":%d,\"output\":%s}\n", result,
                AudioOutputSnapshotJson(ReadAudioOutputSnapshot(GetCurrentProcessId())).c_str());
    if (result != 0) throw std::runtime_error("playout refused");
    auto meter = SessionMeter();
    const auto origin = Clock::now() + std::chrono::milliseconds(300);
    const auto delivery_failures = std::make_shared<std::atomic<int>>(0);
    source = std::thread([fixture, origin, deliver, delivery_failures] {
      for (size_t i = 0; i < fixture.packets.size(); ++i) {
        std::this_thread::sleep_until(origin + std::chrono::milliseconds(i * fixture.packet_ms));
        if (deliver(fixture.packets[i].data(), fixture.packets[i].size()) != 0)
          ++*delivery_failures;
      }
    });
    for (int i = 0; i < 66; ++i) {
      std::this_thread::sleep_until(origin + std::chrono::milliseconds(i * 200));
      if (!meter) meter = SessionMeter();
      float peak = -1;
      if (meter && FAILED(meter->GetPeakValue(&peak))) peak = -1;
      char* value = stats(engine);
      const double seconds = std::chrono::duration<double>(Clock::now() - origin).count();
      std::printf("{\"kind\":\"sample\",\"seconds\":%.6f,\"session_peak\":%.8f,\"stats\":%s}\n",
                  seconds, peak, value ? value : "{}");
      if (value) free_string(value);
      std::fflush(stdout);
    }
    source.join();
    destroy(engine); engine = nullptr;
    std::printf("{\"kind\":\"finish\",\"delivery_failures\":%d,\"registered\":%d}\n",
                delivery_failures->load(), registered());
    return delivery_failures->load() == 0 && registered() == 0 ? 0 : 6;
  } catch (...) {
    if (source.joinable()) source.join();
    if (engine && destroy) destroy(engine);
    std::puts("{\"kind\":\"failure\"}");
    return 5;
  }
}
