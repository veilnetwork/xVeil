#undef NDEBUG
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <map>
#include <string>
#include <vector>
#include "api/field_trials_view.h"
#include "modules/pacing/pacing_controller.h"
#include "system_wrappers/include/clock.h"
#include "video/video_send_stream_impl.h"

class Trials final : public webrtc::FieldTrialsView {
 public:
  explicit Trials(std::string value) : value_(std::move(value)) {}
  std::string Lookup(absl::string_view key) const override {
    return key == "WebRTC-Video-Pacing" ? value_ : "";
  }
  std::unique_ptr<webrtc::FieldTrialsView> CreateCopy() const override {
    return std::make_unique<Trials>(value_);
  }
 private:
  std::string value_;
};

class Sender final : public webrtc::PacingController::PacketSender {
 public:
  explicit Sender(webrtc::SimulatedClock& clock) : clock_(clock) {}
  void SendPacket(std::unique_ptr<webrtc::RtpPacketToSend> packet,
                  const webrtc::PacedPacketInfo&) override {
    bytes_at_ms[clock_.TimeInMilliseconds() - 1000] += packet->size();
    sequences.push_back(packet->SequenceNumber());
  }
  std::vector<std::unique_ptr<webrtc::RtpPacketToSend>> FetchFec() override { return {}; }
  std::vector<std::unique_ptr<webrtc::RtpPacketToSend>> GeneratePadding(webrtc::DataSize) override { return {}; }
  std::map<int64_t, size_t> bytes_at_ms;
  std::vector<uint16_t> sequences;
 private:
  webrtc::SimulatedClock& clock_;
};

int main() {
  Trials trials("factor:4.0,max_delay:25ms");
  webrtc::internal::PacingConfig profile(trials);
  webrtc::SimulatedClock clock(1000000);
  Sender sender(clock);
  webrtc::PacingController pacer(&clock, &sender, trials);
  pacer.SetQueueTimeLimit(profile.max_pacing_delay.Get());
  pacer.SetPacerConfig(webrtc::PacerConfig::Create(clock.CurrentTime(), webrtc::DataRate::BitsPerSec(3600000), webrtc::DataRate::Zero()));
  auto add = [&](int sequence, int payload) {
    auto p = std::make_unique<webrtc::RtpPacketToSend>(nullptr);
    p->set_packet_type(webrtc::RtpPacketMediaType::kVideo);
    p->SetSsrc(11); p->SetSequenceNumber(sequence);
    p->set_capture_time(clock.CurrentTime()); p->SetPayloadSize(payload);
    pacer.EnqueuePacket(std::move(p));
  };
  for (int i=0;i<14;++i) add(i,1000);
  pacer.ProcessPackets();
  assert(sender.sequences.size()==14);
  pacer.SetPacerConfig(webrtc::PacerConfig::Create(clock.CurrentTime(), webrtc::DataRate::BitsPerSec(60000), webrtc::DataRate::Zero()));
  clock.AdvanceTimeMilliseconds(1); add(14,400);
  for (int ms=0;ms<3000;++ms) { pacer.ProcessPackets(); clock.AdvanceTimeMilliseconds(1); }
  assert(sender.sequences.size()==15);
  for (int i=0;i<15;++i) assert(sender.sequences[i]==i);
  const auto delay=sender.bytes_at_ms.rbegin()->first-1;
  std::printf("fresh video after 900->15 kbit/s profile cut: %lld ms; queue target 25 ms; all 15 packets preserved in order\n", (long long)delay);
  std::fflush(stdout);
  assert(delay<=50);
}
