// A stats poll that outlives its call must not republish a freed texture.
//
// `refreshStats` reads the texture id, awaits the platform channel, and then
// publishes. A stop landing in that window cleared the id and the notifier, and
// the poll republished the texture it had captured — one the native side has
// already freed. If a new call had started meanwhile, the stale answer
// overwrote ITS texture with the dead one (report9 X-11).
//
// The window is real rather than theoretical: the poll runs on a 200ms timer
// and crosses a platform channel, while stopping a call is a single method
// call. Here the channel is held open on purpose so the interleaving is exact
// instead of hoped for.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/android_native_call_video.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('xveil/test_native_call_video');
  late Completer<void> statsGate;
  var statsCalls = 0;

  setUp(() {
    statsGate = Completer<void>()..complete();
    statsCalls = 0;
    androidNativeCallVideoTexture.value = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'start':
              return <Object?, Object?>{'textureId': 7};
            case 'stats':
              statsCalls++;
              await statsGate.future;
              return <Object?, Object?>{
                'video_texture_running': true,
                'video_texture_frames': 5,
                'video_texture_width': 640,
                'video_texture_height': 480,
              };
            case 'stop':
              return null;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    androidNativeCallVideoTexture.value = null;
  });

  test('a stats poll that finishes after stop publishes nothing', () async {
    final renderer = AndroidNativeCallVideoRenderer(channel: channel);
    expect(await renderer.start(engineAddress: 1), isTrue);
    // The start already published the texture; let its first poll settle so
    // the one under test is the only thing in flight.
    await Future<void>.delayed(Duration.zero);
    expect(androidNativeCallVideoTexture.value?.textureId, 7);

    statsGate = Completer<void>();
    final polling = renderer.refreshStats();
    // Let it reach the held channel call.
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(statsCalls, greaterThan(0), reason: 'the poll never got underway');

    await renderer.stop();
    expect(
      androidNativeCallVideoTexture.value,
      isNull,
      reason: 'stop must clear the published texture',
    );

    statsGate.complete();
    await polling;
    expect(
      androidNativeCallVideoTexture.value,
      isNull,
      reason:
          'a poll from the stopped call republished its texture — the id it '
          'names has been freed on the native side, and had a new call started '
          'it would now be showing the dead one',
    );
  });

  /// The 200ms timer must not stack polls on top of a slow one.
  ///
  /// A poll that takes longer than the interval used to have the next tick
  /// start another, and two answers in flight publish in whatever order the
  /// platform returns them rather than the order they were asked.
  ///
  /// Costs half a second of real time on purpose: the timer is what is under
  /// test, so a fake clock would be testing something else.
  test('the timer does not stack polls on a slow one', () async {
    final renderer = AndroidNativeCallVideoRenderer(channel: channel);
    expect(await renderer.start(engineAddress: 1), isTrue);
    await Future<void>.delayed(Duration.zero);

    statsGate = Completer<void>();
    final before = statsCalls;
    // Long enough for two or three ticks while the first answer is held.
    await Future<void>.delayed(const Duration(milliseconds: 550));
    expect(
      statsCalls - before,
      1,
      reason:
          'the timer started ${statsCalls - before} polls while one was still '
          'unanswered — their answers publish in whatever order they return',
    );

    statsGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await renderer.stop();
  });

  test('a running call still gets its stats published', () async {
    // The other half: a fence that refused everything would pass the test
    // above and leave the renderer permanently blank.
    final renderer = AndroidNativeCallVideoRenderer(channel: channel);
    expect(await renderer.start(engineAddress: 1), isTrue);
    await renderer.refreshStats();
    final published = androidNativeCallVideoTexture.value;
    expect(published?.textureId, 7);
    expect(published?.width, 640);
    expect(published?.frames, 5);
    await renderer.stop();
  });
}
