import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_rtcp_loss.dart';

void main() {
  test('each fresh loss witness is consumed once per media lane', () {
    final loss = CallRtcpLoss();
    ({bool audio, bool video}) sample(Object? audio, Object? video) {
      final observed = loss.observe(
        audioReportUs: audio,
        videoReportUs: video,
        audioExpected: true,
        videoExpected: true,
      );
      expect(observed.repeatedAudio, isNull);
      return (audio: observed.audio, video: observed.video);
    }

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
      (audio: false, video: false, repeatedAudio: null),
    );
    expect(
      loss.observe(
        audioReportUs: 10,
        videoReportUs: 20,
        audioExpected: true,
        videoExpected: true,
      ),
      (audio: false, video: false, repeatedAudio: null),
    );
    expect(
      loss.observe(
        audioReportUs: 11,
        videoReportUs: 21,
        audioExpected: true,
        videoExpected: true,
      ),
      (audio: true, video: true, repeatedAudio: null),
    );
  });

  test('report arrivals distinguish repeated loss from adjacent polls', () {
    final loss = CallRtcpLoss();
    bool? repeated(int latest, int previous) => loss
        .observe(
          audioReportUs: latest,
          previousAudioReportUs: previous,
          audioExpected: true,
          videoExpected: false,
        )
        .repeatedAudio;

    expect(repeated(1000000, 0), isFalse);
    expect(repeated(7000001, 1000000), isFalse);
    expect(repeated(13000001, 7000001), isTrue);
    expect(repeated(13000001, 7000001), isFalse);
    expect(repeated(13400000, 13000001), isTrue);
    expect(repeated(13900000, 0), isFalse); // First report on a new route.
  });

  test('native repetition does not span a mute', () {
    final loss = CallRtcpLoss();
    bool? repeated(int latest, int previous, {bool sending = true}) => loss
        .observe(
          audioReportUs: latest,
          previousAudioReportUs: previous,
          audioExpected: sending,
          videoExpected: false,
        )
        .repeatedAudio;

    expect(repeated(100, 0), isFalse);
    expect(repeated(200, 100, sending: false), isFalse);
    expect(repeated(200, 100), isFalse);
    expect(repeated(300, 200), isFalse);
    expect(repeated(400, 300), isTrue);
  });
}
