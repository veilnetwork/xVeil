// Regression: real callback stalls must remain in timing evidence; the driver
// must not invent catch-up samples, lose rows silently, or outlive shutdown.
#include "native_pcm_driver.cc"
#include <atomic>
#include <cassert>
#include <cstdio>

namespace {
struct Fake {
  std::atomic<int> calls{0};
  std::atomic<bool> stall{false};
  std::atomic<bool> hold_capture{false}, capture_entered{false}, release_capture{false};
  int frequency = 0;
};
int CaptureTone(void* ptr, int frequency) {
  auto& fake = *static_cast<Fake*>(ptr);
  ++fake.calls;
  fake.frequency = frequency;
  if (fake.stall.exchange(false))
    std::this_thread::sleep_for(std::chrono::milliseconds(65));
  if (fake.hold_capture.exchange(false)) {
    fake.capture_entered = true;
    while (!fake.release_capture.load())
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return 0;
}
int PlayoutTone(void* ptr, int16_t* pcm, size_t capacity) {
  assert(capacity == 480);
  const auto& fake = *static_cast<Fake*>(ptr);
  for (size_t i = 0; i < capacity; ++i)
    pcm[i] = int16_t(12000 * std::sin(2 * 3.141592653589793 * fake.frequency * i / 48000));
  return 480;
}
}
int main() {
  Fake a, b;
  const double origin = stand_pcm_now();
  assert(!stand_pcm_start(nullptr, PlayoutTone, &a, &b, origin, 1010, 1));
  assert(!stand_pcm_start(CaptureTone, PlayoutTone, &a, &a, origin, 1010, 1));
  void* handle = stand_pcm_start(CaptureTone, PlayoutTone, &a, &b, origin, 1010, 1);
  assert(handle);
  while (a.calls.load() < 5) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  a.stall = true;
  while (b.calls.load() < 12) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  stand_pcm_request_stop(handle);
  while (!stand_pcm_finished(handle)) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  std::array<PcmRow, 128> rows;
  PcmStats stats{};
  const auto n = stand_pcm_poll(handle, rows.data(), rows.size(), &stats);
  assert(stats.max_interval_ms >= 65);
  assert(stats.max_callback_ms >= 65);
  assert(stats.late_intervals >= 2 && stats.dropped_rows == 0);
  assert(!stats.failures[0] && !stats.failures[1]);
  assert(n == stats.ticks * 2 && n >= 24);
  std::array<double, 2> previous{};
  bool long_playout = false;
  for (size_t i = 0; i < n; ++i) {
    const auto& row = rows[i];
    assert(row.t >= row.source_at);
    assert(row.rms > 8000 && row.freq >= 450 && row.freq <= 1050);
    if (row.t - row.source_at > .06) long_playout = true;
    // After a stall the next tick is scheduled in the future, not a burst.
    if (previous[row.side]) assert(row.source_at - previous[row.side] > .001);
    previous[row.side] = row.source_at;
  }
  assert(long_playout);
  const int calls = a.calls.load();
  stand_pcm_destroy(handle);
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  assert(a.calls.load() == calls);
  // Fill the evidence buffer, then run the real producer. Overflow must be
  // counted while capture continues; it must never block media or look clean.
  Driver full;
  full.capture = CaptureTone;
  full.playout = PlayoutTone;
  full.engines = {&a, &b};
  full.origin = stand_pcm_now();
  full.period_ms = 1010;
  full.rows.resize(kCapacity);
  full.thread = std::thread([&] { full.Run(); });
  while (a.calls.load() == calls)
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  stand_pcm_request_stop(&full);
  full.thread.join();
  assert(full.stats.dropped_rows >= 2 && full.rows.size() == kCapacity);
  // A slow evidence reader must remain visible as publication delay and an
  // actual source-clock failure, rather than being blamed on the codec.
  const int before_publication_test = a.calls.load();
  a.hold_capture = true;
  handle = stand_pcm_start(CaptureTone, PlayoutTone, &a, &b, stand_pcm_now(), 1010, 1);
  while (!a.capture_entered.load())
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  {
    auto* driver = static_cast<Driver*>(handle);
    std::lock_guard held(driver->mu);
    a.release_capture = true;
    std::this_thread::sleep_for(std::chrono::milliseconds(70));
  }
  while (a.calls.load() < before_publication_test + 4)
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  stand_pcm_request_stop(handle);
  while (!stand_pcm_finished(handle))
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  stand_pcm_poll(handle, rows.data(), rows.size(), &stats);
  assert(stats.max_publication_ms >= 60 && stats.max_interval_ms >= 60);
  stand_pcm_destroy(handle);
  std::puts("native PCM driver: real stalls, timestamps, bounded rows, stop verified");
}
