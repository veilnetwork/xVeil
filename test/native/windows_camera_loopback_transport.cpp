// Synthetic datagram callback loop for the opt-in Windows camera control.
// Never package this DLL: it implements only test channels 42 and 43, with no
// network, node state, identity keys, device persistence or user data.
#include <windows.h>
#include <stdint.h>
#include <stddef.h>

using Receive = void (*)(void*, const uint8_t*, size_t);
struct Slot {
  Receive callback;
  void* context;
};
static SRWLOCK lock = SRWLOCK_INIT;
static Slot slots[2] = {};
static volatile LONG64 packets = 0;

extern "C" __declspec(dllexport) int veil_media_send_datagram(
    uint64_t channel, const uint8_t* data, size_t size) {
  if (channel != 42 && channel != 43) return -1;
  InterlockedIncrement64(&packets);
  // Keep the peer callback registered for the complete invocation. Native
  // teardown must unregister before destroying its callback context.
  AcquireSRWLockShared(&lock);
  const auto peer = slots[channel == 42 ? 1 : 0];
  if (peer.callback) peer.callback(peer.context, data, size);
  ReleaseSRWLockShared(&lock);
  return peer.callback ? 0 : -1;
}

extern "C" __declspec(dllexport) int veil_media_send_video_control_datagram(
    uint64_t channel, const uint8_t* data, size_t size) {
  return veil_media_send_datagram(channel, data, size);
}

extern "C" __declspec(dllexport) int veil_media_set_recv_callback(
    uint64_t channel, Receive callback, void* context) {
  if (channel != 42 && channel != 43) return -1;
  AcquireSRWLockExclusive(&lock);
  slots[channel == 42 ? 0 : 1] = {callback, context};
  ReleaseSRWLockExclusive(&lock);
  return 0;
}

extern "C" __declspec(dllexport) LONG64 probe_packet_count() {
  return InterlockedCompareExchange64(&packets, 0, 0);
}
