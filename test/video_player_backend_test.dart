import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/video_player_backend.dart';

void main() {
  test('non-Linux leaves the platform video backend untouched', () {
    var calls = 0;
    initializeVideoPlayerBackend(linux: false, initializeLinux: () => calls++);
    expect(calls, 0);
  });

  test('Linux registers exactly the supplied video_player backend', () {
    var calls = 0;
    initializeVideoPlayerBackend(linux: true, initializeLinux: () => calls++);
    expect(calls, 1);
  });
}
