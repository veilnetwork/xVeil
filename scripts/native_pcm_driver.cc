// Stand only. No Python callbacks, device I/O, or network
// policy. The real test ADM still drives the production Opus/NetEq pipeline.
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <thread>
#ifdef __APPLE__
#include <mach/mach_time.h>
#include <pthread.h>
#include <pthread/qos.h>
#else
#include <time.h>
#endif

extern "C" double stand_pcm_now() {
#ifdef __APPLE__
  static const auto scale = [] {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    return double(info.numer) / info.denom / 1e9;
  }();
  return mach_absolute_time() * scale;  // Same clock as Python time.monotonic.
#else
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return double(ts.tv_sec) + double(ts.tv_nsec) / 1e9;
#endif
}

struct PcmRow {
  double t, source_at, rms, freq, interval_ms;
  uint64_t source_tick;
  uint32_t side, source_freq;
};
struct PcmStats {
  double max_interval_ms;
  uint64_t late_intervals, dropped_rows, failures[2], ticks;
  double max_wake_lateness_ms, max_callback_ms, max_publication_ms;
  int32_t qos_supported, qos_result, qos_requested, qos_actual;
  int32_t timer_error;
};
// Foreign test hosts must verify both layouts before passing writable buffers.
extern "C" size_t stand_pcm_row_size() { return sizeof(PcmRow); }
extern "C" size_t stand_pcm_stats_size() { return sizeof(PcmStats); }
namespace {
using Capture = int (*)(void*, int);
using Playout = int (*)(void*, int16_t*, size_t);
constexpr size_t kCapacity = 4096;  // 20 s of duplex observations, bounded.
struct Driver {
  Capture capture;
  Playout playout;
  std::array<void*, 2> engines;
  double origin;
  int period_ms;
  bool audio_priority = true;
  std::mutex mu;
  std::mutex wake_mu;  // An evidence reader cannot hold the timer/stop mutex.
  std::condition_variable wake;
  bool stop = false, finished = false;
  std::deque<PcmRow> rows;
  PcmStats stats{};
  std::thread thread;

  bool WaitUntil(std::chrono::steady_clock::time_point deadline) {
#ifdef __APPLE__
    static const auto timebase = [] {
      mach_timebase_info_data_t value;
      mach_timebase_info(&value);
      return value;
    }();
    // libc++ on this host converts condition-variable deadlines to wall time.
    // Keep the synthetic device on Mach monotonic time instead. Stop is polled
    // at each deadline, at most one normal 10-ms period after the request.
    for (;;) {
      {
        std::lock_guard lock(wake_mu);
        if (stop) return true;
      }
      const auto remaining = std::chrono::duration_cast<std::chrono::nanoseconds>(
          deadline - std::chrono::steady_clock::now()).count();
      if (remaining <= 0) return false;
      const uint64_t ticks = (uint64_t(remaining) * timebase.denom + timebase.numer - 1)
                             / timebase.numer;
      const auto result = mach_wait_until(mach_absolute_time() + ticks);
      if (result != KERN_SUCCESS && result != KERN_ABORTED) {
        std::lock_guard lock(mu);
        stats.timer_error = result;
        return true;
      }
    }
#else
    std::unique_lock lock(wake_mu);
    return wake.wait_until(lock, deadline, [&] { return stop; });
#endif
  }

  void Run() {
#ifdef __APPLE__
    {
      std::lock_guard lock(mu);
      // Synthetic capture represents the device callback, not a background
      // observer. Match latency-sensitive endpoint audio work; SDK/relay worker
      // threads and all network policies retain their original scheduling.
      stats.qos_supported = 1;
      stats.qos_requested = audio_priority ? QOS_CLASS_USER_INTERACTIVE : 0;
      if (audio_priority)
        stats.qos_result = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
      qos_class_t actual;
      int relative = 0;
      const int queried = pthread_get_qos_class_np(pthread_self(), &actual, &relative);
      if (!stats.qos_result) stats.qos_result = queried;
      stats.qos_actual = queried ? 0 : static_cast<int32_t>(actual);
    }
#endif
    auto deadline = std::chrono::steady_clock::now();
    std::array<double, 2> previous{stand_pcm_now(), stand_pcm_now()};
    uint64_t tick = 0;
    for (;;) {
      double wake_lateness_ms = 0;
      if (WaitUntil(deadline)) break;
      {
        wake_lateness_ms = std::max(0.0,
            std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - deadline).count());
      }
      std::array<PcmRow, 2> pair{};
      std::array<uint64_t, 2> failures{};
      for (size_t side = 0; side < engines.size(); ++side) {
        auto& row = pair[side];
        const double now = stand_pcm_now();
        row.source_at = now - origin;
        row.interval_ms = (now - previous[side]) * 1000;
        previous[side] = now;
        row.source_tick = tick;
        row.side = side;
        row.source_freq = int(row.source_at * 1000) / period_ms % 2 ? 1000 : 500;
        std::array<int16_t, 480> pcm{};
        if (capture(engines[side], row.source_freq) != 0) ++failures[side];
        const int count = playout(engines[side], pcm.data(), pcm.size());
        row.t = stand_pcm_now() - origin;  // Before analysis, after real playout.
        if (count <= 0 || count > int(pcm.size())) {
          ++failures[side];
        } else {
          double energy = 0;
          int crossings = 0;
          for (int i = 0; i < count; ++i) {
            energy += double(pcm[i]) * pcm[i];
            if (i && (pcm[i] >= 0) != (pcm[i - 1] >= 0)) ++crossings;
          }
          row.rms = std::sqrt(energy / count);
          row.freq = crossings * 48000.0 / (2 * count);
        }
      }
      const double publication_started = stand_pcm_now();
      {
        std::lock_guard lock(mu);
        stats.max_wake_lateness_ms = std::max(stats.max_wake_lateness_ms,
                                             wake_lateness_ms);
        for (size_t side = 0; side < pair.size(); ++side) {
          stats.max_callback_ms = std::max(stats.max_callback_ms,
              (pair[side].t - pair[side].source_at) * 1000);
          stats.max_interval_ms = std::max(stats.max_interval_ms, pair[side].interval_ms);
          if (pair[side].interval_ms >= 20) ++stats.late_intervals;
          stats.failures[side] += failures[side];
          if (rows.size() == kCapacity) {
            ++stats.dropped_rows;  // Never silently overwrite measurement data.
          } else {
            rows.push_back(pair[side]);
          }
        }
        stats.ticks = ++tick;
        stats.max_publication_ms = std::max(stats.max_publication_ms,
            (stand_pcm_now() - publication_started) * 1000);
      }
      deadline += std::chrono::milliseconds(10);
      // Never invent backdated samples or burst synthetic catch-up audio.
      const auto now = std::chrono::steady_clock::now();
      if (deadline < now - std::chrono::milliseconds(10))
        deadline = now + std::chrono::milliseconds(10);
    }
    std::lock_guard lock(wake_mu);
    finished = true;
  }
};
}
extern "C" void* stand_pcm_start(Capture capture, Playout playout, void* a,
                                  void* b, double origin, int period_ms,
                                  int audio_priority) {
  if (!capture || !playout || !a || !b || a == b || !std::isfinite(origin) ||
      origin > stand_pcm_now() || period_ms < 500 || period_ms > 5000) return nullptr;
  auto* driver = new Driver;
  driver->capture = capture;
  driver->playout = playout;
  driver->engines = {a, b};
  driver->origin = origin;
  driver->period_ms = period_ms;
  driver->audio_priority = audio_priority != 0;
  driver->thread = std::thread([driver] { driver->Run(); });
  return driver;
}
extern "C" size_t stand_pcm_poll(void* handle, PcmRow* out, size_t capacity,
                                  PcmStats* stats) {
  auto& d = *static_cast<Driver*>(handle);
  std::lock_guard lock(d.mu);
  size_t count = 0;
  while (count < capacity && !d.rows.empty()) {
    out[count++] = d.rows.front();
    d.rows.pop_front();
  }
  *stats = d.stats;
  return count;
}
extern "C" void stand_pcm_request_stop(void* handle) {
  auto& d = *static_cast<Driver*>(handle);
  std::lock_guard lock(d.wake_mu);
  d.stop = true;
  d.wake.notify_one();
}
extern "C" int stand_pcm_finished(void* handle) {
  auto& d = *static_cast<Driver*>(handle);
  std::lock_guard lock(d.wake_mu);
  return d.finished;
}
extern "C" void stand_pcm_destroy(void* handle) {
  auto* d = static_cast<Driver*>(handle);
  stand_pcm_request_stop(d);
  d->thread.join();  // Caller checks finished before destroying its engines.
  delete d;
}
