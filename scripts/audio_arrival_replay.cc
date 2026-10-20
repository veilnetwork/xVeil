#undef NDEBUG // Pinned WebRTC release flags must retain diagnostic assertions.
// Standalone receiver replay. All audio is regenerated; nothing is sent to a
// device.
#include "api/audio_codecs/builtin_audio_decoder_factory.h"
#include "api/environment/environment_factory.h"
#include "rtc_base/time_utils.h"
#include "third_party/opus/src/include/opus.h"
#include "veil_playout_recovery.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <vector>
struct Wall : webrtc::ClockInterface {
  int64_t us = 1000000;
  int64_t TimeNanos() const override { return us * 1000; }
};
struct Packet {
  int64_t first, arrival;
  int blocks;
  uint32_t stamp;
  int sequence;
  std::vector<uint8_t> bytes;
};
int main(int argc, char **argv) {
  assert(argc == 3);
  const double duration = std::stod(argv[2]);
  assert(duration >= 20 && duration <= 600);
  std::ifstream f(argv[1]);
  assert(f);
  std::vector<Packet> packets;
  std::string line;
  int err;
  OpusEncoder *enc = opus_encoder_create(48000, 1, OPUS_APPLICATION_VOIP, &err);
  assert(err == OPUS_OK);
  assert(opus_encoder_ctl(enc, OPUS_SET_BITRATE(24000)) == OPUS_OK);
  assert(opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(1)) == OPUS_OK);
  double phase = 0;
  constexpr double pi = 3.141592653589793;
  while (std::getline(f, line)) {
    std::replace(line.begin(), line.end(), ',', ' ');
    std::istringstream s(line);
    Packet p;
    s >> p.first >> p.arrival >> p.blocks >> p.stamp >> p.sequence;
    assert(s);
    std::vector<int16_t> input(p.blocks * 480);
    for (size_t i = 0; i < input.size(); ++i) {
      const int tick = int(std::llround(p.first / 10000.)) + int(i / 480);
      int hz = (tick / 101) % 2 ? 900 : 600;
      input[i] = int16_t(5000 * std::sin(phase));
      phase += 2 * pi * hz / 48000;
    }
    p.bytes.resize(1275);
    int n = opus_encode(enc, input.data(), int(input.size()), p.bytes.data(),
                        int(p.bytes.size()));
    assert(n > 0);
    p.bytes.resize(n);
    packets.push_back(std::move(p));
  }
  opus_encoder_destroy(enc);
  assert(!packets.empty());
  std::stable_sort(packets.begin(), packets.end(),
                   [](auto &a, auto &b) { return a.arrival < b.arrival; });
  Wall wall;
  auto *previous = webrtc::SetClockForTesting(&wall);
  webrtc::SimulatedClock clock(1000000);
  auto env = webrtc::CreateEnvironment(&clock);
  auto stats = std::make_shared<veil_media::PlayoutRecoveryStats>();
  veil_media::RecoveringNetEqFactory factory(stats);
  webrtc::NetEq::Config config;
  config.sample_rate_hz = 48000;
  config.max_packets_in_buffer = 30;
  config.enable_fast_accelerate = true;
  auto neteq =
      factory.Create(env, config, webrtc::CreateBuiltinAudioDecoderFactory());
  assert(neteq->RegisterPayloadType(111,
                                    webrtc::SdpAudioFormat("opus", 48000, 2)));
  size_t pos = 0;
  double max_delay = 0;
  int edges = 0, missing = 0, prev = -1, pending = -1, run = 0,
      pending_tick = 0;
  int64_t max_at = 0;
  auto power = [](const int16_t *pcm, size_t n, int hz) {
    double a = 0, b = 0, c = 2 * std::cos(2 * pi * hz / 48000);
    for (size_t i = 0; i < n; ++i) {
      double next = pcm[i] + c * a - b;
      b = a;
      a = next;
    }
    return (a * a + b * b - c * a * b) / (n * n);
  };
  webrtc::NetEqLifetimeStatistics measured;
  uint64_t measured_discarded = 0;
  for (int tick = 0; tick < int(duration * 100) + 100; ++tick) {
    int64_t at = tick * 10000;
    wall.us = 1000000 + at;
    if (tick)
      clock.AdvanceTimeMicroseconds(10000);
    while (pos < packets.size() && packets[pos].arrival <= at) {
      auto &p = packets[pos++];
      webrtc::RTPHeader h;
      h.ssrc = 1; // One synthetic receiver stream, never sent on a network.
      h.sequenceNumber = uint16_t(p.sequence);
      h.timestamp = p.stamp;
      h.payloadType = 111;
      assert(neteq->InsertPacket(h, p.bytes,
                                 webrtc::RtpPacketInfo(
                                     h, webrtc::Timestamp::Micros(wall.us))) ==
             0);
    }
    webrtc::AudioFrame out;
    bool muted = false;
    assert(neteq->GetAudio(&out, &muted, nullptr, std::nullopt) == 0);
    assert(out.num_channels_ == 1);
    const auto lo = power(out.data(), out.samples_per_channel_, 600),
               hi = power(out.data(), out.samples_per_channel_, 900);
    int freq = std::max(lo, hi) > 125000 ? (hi > lo ? 1 : 0) : -1;
    if (freq < 0 || freq == prev) {
      pending = -1;
      run = 0;
    } else if (freq != pending) {
      pending = freq;
      pending_tick = tick;
      run = 1;
    } else if (++run >= 2) {
      const int source_tick = edges * 101;
      if (freq != edges % 2)
        ++missing;
      double delay = (pending_tick - source_tick) * 10.;
      if (source_tick >= 500 && source_tick < int(duration * 100) &&
          delay > max_delay) {
        max_delay = delay;
        max_at = source_tick * 10000LL;
      }
      ++edges;
      prev = freq;
      pending = -1;
      run = 0;
    }
    if (tick == int(duration * 100) - 1) {
      measured = neteq->GetLifetimeStatistics();
      measured_discarded = stats->discarded_ms.load();
    }
  }
  const auto st = measured;
  std::printf("{\"packets\":%zu,\"edges\":%d,\"expected_edges\":%d,\"ordinal_"
              "mismatches\":%d,\"max_ms\":%.1f,\"source_at_seconds\":%.2f,"
              "\"concealed_samples\":%llu,\"silent_concealed_samples\":%llu,"
              "\"interruption_count\":%d,\"inserted_samples\":%llu,\"removed_"
              "samples\":%llu,\"discarded_ms\":%llu}\n",
              pos, edges, int(std::ceil(duration / 1.01)), missing, max_delay,
              max_at / 1e6, (unsigned long long)st.concealed_samples,
              (unsigned long long)st.silent_concealed_samples,
              st.interruption_count,
              (unsigned long long)st.inserted_samples_for_deceleration,
              (unsigned long long)st.removed_samples_for_acceleration,
              (unsigned long long)measured_discarded);
  neteq.reset();
  webrtc::SetClockForTesting(previous);
}
