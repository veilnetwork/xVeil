// Stand-only plaintext boundary. Never copy this DLL into an app bundle.
#include <windows.h>
#include <cstddef>
#include <cstdint>
#include <mutex>

using Receive = void (*)(void*, const uint8_t*, size_t);
static std::mutex mutex;
static Receive receive = nullptr;
static void* context = nullptr;
constexpr uint64_t channel = 777;

extern "C" __declspec(dllexport) int veil_media_send_datagram(
    uint64_t id, const uint8_t*, size_t length) {
  return id == channel && length <= 16384 ? 0 : -1;
}
extern "C" __declspec(dllexport) int veil_media_send_video_control_datagram(
    uint64_t id, const uint8_t* data, size_t length) {
  return veil_media_send_datagram(id, data, length);
}
extern "C" __declspec(dllexport) int veil_media_set_recv_callback(
    uint64_t id, Receive next, void* ctx) {
  if (id != channel) return -1;
  std::lock_guard<std::mutex> lock(mutex);
  receive = next;
  context = ctx;
  return 0;
}
extern "C" __declspec(dllexport) int probe_deliver(
    const uint8_t* data, size_t length) {
  if (!data || length < 12 || length > 16384) return -1;
  std::lock_guard<std::mutex> lock(mutex);
  if (!receive) return -1;
  receive(context, data, length);
  return 0;
}
extern "C" __declspec(dllexport) int probe_registered() {
  std::lock_guard<std::mutex> lock(mutex);
  return receive ? 1 : 0;
}

BOOL WINAPI DllMain(HINSTANCE, DWORD, LPVOID) { return TRUE; }
