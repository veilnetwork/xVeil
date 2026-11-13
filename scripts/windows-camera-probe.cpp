// SPDX-License-Identifier: MIT
// Standalone operator probe. No xVeil profile, network, recording or device
// names/IDs are read or exported. Compile with probe-windows-camera.ps1.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <objbase.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "veil_mf_camera_format.h"

using Microsoft::WRL::ComPtr;

namespace {
enum Stage {
  kSamples = 0, kCom = 1, kPlatform = 2, kAttributes = 3,
  kEnumeration = 4, kSelection = 5, kActivation = 6,
  kReaderAttributes = 7, kReader = 8, kFormat = 9,
  kRead = 10, kNoFrames = 11,
};
struct Report {
  Stage stage = kCom;
  HRESULT result = S_OK;
  UINT32 devices = 0;
  unsigned samples = 0;
  bool truncated = false;
  void Print() const {
    std::printf("{\"schema\":\"xveil-camera-probe/1\",\"stage\":%d,"
                "\"hresult\":%lu,\"cameraCount\":%u,\"samples\":%u,"
                "\"countCapped\":%s}\n",
                static_cast<int>(stage), static_cast<unsigned long>(result),
                devices, samples, truncated ? "true" : "false");
  }
};
void CALLBACK Expired(void*, BOOLEAN) {
  // The parent turns 124 into a distinct timeout report, never camera success.
  TerminateProcess(GetCurrentProcess(), 124);
}

// Source shutdown may itself hang in a driver. The process-wide watchdog
// covers opening, synchronous ReadSample and teardown, not just the read loop.
class Deadline {
 public:
  explicit Deadline(DWORD milliseconds) {
    if (!CreateTimerQueueTimer(&timer_, nullptr, Expired, nullptr, milliseconds,
                              0, WT_EXECUTEONLYONCE)) timer_ = nullptr;
  }
  ~Deadline() {
    if (timer_) DeleteTimerQueueTimer(nullptr, timer_, INVALID_HANDLE_VALUE);
  }
  bool armed() const { return timer_ != nullptr; }
 private:
  HANDLE timer_ = nullptr;
};

Report Capture(unsigned selected) {
  Report report;
  report.result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(report.result)) return report;
  struct Apartment { ~Apartment() { CoUninitialize(); } } apartment;
  report.stage = kPlatform;
  report.result = MFStartup(MF_VERSION);
  if (FAILED(report.result)) return report;
  struct Platform { ~Platform() { MFShutdown(); } } platform;
  report.stage = kAttributes;
  ComPtr<IMFAttributes> attributes;
  report.result = MFCreateAttributes(&attributes, 1);
  if (FAILED(report.result)) return report;
  report.result = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                                     MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  if (FAILED(report.result)) return report;
  report.stage = kEnumeration;
  IMFActivate** devices = nullptr;
  UINT32 count = 0;
  report.result = MFEnumDeviceSources(attributes.Get(), &devices, &count);
  if (FAILED(report.result)) return report;
  report.devices = std::min(count, 16u);
  report.truncated = count > 16;
  ComPtr<IMFActivate> chosen;
  for (UINT32 i = 0; i < count; ++i) {
    if (i == selected) chosen = devices[i];
    devices[i]->Release();
  }
  CoTaskMemFree(devices);
  report.stage = kSelection;
  if (!chosen || selected >= report.devices) return report;
  report.stage = kActivation;
  ComPtr<IMFMediaSource> source;
  report.result = chosen->ActivateObject(IID_PPV_ARGS(&source));
  if (FAILED(report.result)) return report;
  struct SourceShutdown {
    IMFMediaSource* source;
    ~SourceShutdown() { source->Shutdown(); }
  } shutdown{source.Get()};
  report.stage = kReaderAttributes;
  ComPtr<IMFAttributes> reader_attributes;
  report.result = MFCreateAttributes(&reader_attributes, 1);
  if (FAILED(report.result)) return report;
  report.result = reader_attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
  if (FAILED(report.result)) return report;
  report.stage = kReader;
  ComPtr<IMFSourceReader> reader;
  report.result = MFCreateSourceReaderFromMediaSource(source.Get(), reader_attributes.Get(), &reader);
  if (FAILED(report.result)) return report;
  report.stage = kFormat;
  report.result = veil_media::mf_camera::RequestCaptureFormat(reader.Get(), 352, 198);
  if (FAILED(report.result)) return report;
  // A sample is NOT a converted/encoded video frame. This deliberately tests
  // the OS capture boundary only, using production format negotiation.
  const ULONGLONG until = GetTickCount64() + 2000;
  report.stage = kNoFrames;
  while (report.samples < 8 && GetTickCount64() < until) {
    DWORD flags = 0;
    ComPtr<IMFSample> sample;
    report.result = reader->ReadSample(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0,
                                      nullptr, &flags, nullptr, &sample);
    if (FAILED(report.result)) { report.stage = kRead; return report; }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    if (sample) {
      DWORD bytes = 0;
      report.result = sample->GetTotalLength(&bytes);
      if (FAILED(report.result)) { report.stage = kRead; return report; }
      if (bytes > 0) ++report.samples;
    }
  }
  if (report.samples > 0) report.stage = kSamples;
  return report;
}
}  // namespace

int main(int argc, char** argv) {
  const bool stall = argc == 2 && std::strcmp(argv[1], "--test-stall") == 0;
  Deadline deadline(stall ? 100 : 10000);
  if (!deadline.armed()) return 125;
  if (stall) { Sleep(5000); return 126; }
  if (argc != 2 || std::strlen(argv[1]) > 2) return 2;
  char* end = nullptr;
  const unsigned long selected = std::strtoul(argv[1], &end, 10);
  if (*argv[1] == '\0' || *end != '\0' || selected > 15) return 2;
  const Report report = Capture(static_cast<unsigned>(selected));
  report.Print();
  return report.stage == kSamples ? 0 : 1;
}
