import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_rtcp_loss.dart';

void main() {
  test('each fresh loss witness is consumed once per media lane', () {
    final loss = CallRtcpLoss();
    ({bool audio, bool video}) sample(Object? audio, Object? video) =>
        loss.observe(
          audioReportUs: audio,
          videoReportUs: video,
          audioExpected: true,
          videoExpected: true,
        );
    expect(sample(null, null), (audio: false, video: false));
    expect(sample(100, 0), (audio: true, video: false));
    expect(sample(100, 200), (audio: false, video: true));
    expect(sample(100, 200), (audio: false, video: false));
    expect(sample(300, 200), (audio: true, video: false));
    // Expiry or removal of the most recently lossy room participant cannot
    // turn an older participant's retained witness into a new event.
    expect(sample(0, 0), (audio: false, video: false));
    expect(sample(150, 100), (audio: false, video: false));
    expect(sample(null, null), (audio: false, video: false));
    expect(sample(300, 200), (audio: false, video: false));
    expect(sample(-1, '400'), (audio: false, video: false));
    expect(sample(400.0, true), (audio: false, video: false));
    loss.reset();
    expect(sample(10, 20), (audio: true, video: true));
  });

  test('muted audio and stopped video consume without deferring loss', () {
    final loss = CallRtcpLoss();
    expect(
      loss.observe(
        audioReportUs: 10,
        videoReportUs: 20,
        audioExpected: false,
        videoExpected: false,
      ),
      (audio: false, video: false),
    );
    expect(
      loss.observe(
        audioReportUs: 10,
        videoReportUs: 20,
        audioExpected: true,
        videoExpected: true,
      ),
      (audio: false, video: false),
    );
    expect(
      loss.observe(
        audioReportUs: 11,
        videoReportUs: 21,
        audioExpected: true,
        videoExpected: true,
      ),
      (audio: true, video: true),
    );
  });
}
