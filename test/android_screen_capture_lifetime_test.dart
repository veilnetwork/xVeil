import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/android_screen_capture.dart';
import 'package:xveil/core/capture_resource_lifetime.dart';

Uint8List _frame() => Uint8List(20)
  ..buffer.asByteData().setUint32(0, 4)
  ..buffer.asByteData().setUint32(4, 2);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var sequence = 0;
  late MethodChannel channel;
  late List<Object?> sessions;
  int stops = 0;
  final captures = <AndroidScreenCapture>[];
  Completer<bool>? startGate;
  Completer<void>? stopGate;
  bool refuseStop = false;
  bool loseStartReply = false;

  AndroidScreenCapture capture([void Function()? unexpected]) {
    final value = AndroidScreenCapture(
      unexpected ?? () {},
      channel: channel,
      isAndroid: true,
    );
    captures.add(value);
    return value;
  }

  Future<void> deliver(String method, Object? session) =>
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(
            method,
            session == null
                ? (method == 'frame' ? _frame() : null)
                : {
                    'session': session,
                    if (method == 'frame') 'frame': _frame(),
                  },
          ),
        ),
        (_) {},
      );

  setUp(() {
    channel = MethodChannel('xveil/screen_lifetime_${sequence++}');
    sessions = [];
    stops = 0;
    startGate = null;
    stopGate = null;
    refuseStop = false;
    loseStartReply = false;
    captures.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        sessions.add(
          call.arguments is Map ? (call.arguments as Map)['session'] : null,
        );
        if (loseStartReply) {
          throw PlatformException(code: 'synthetic_start_reply_lost');
        }
        return startGate == null ? true : await startGate!.future;
      }
      if (call.method == 'stop') {
        stops++;
        expect(call.arguments, {'session': sessions.last});
        if (refuseStop) throw PlatformException(code: 'synthetic_stop_refused');
        await stopGate?.future;
      }
      return null;
    });
  });
  tearDown(() async {
    if (startGate != null && !startGate!.isCompleted) startGate!.complete(true);
    if (stopGate != null && !stopGate!.isCompleted) stopGate!.complete();
    refuseStop = false;
    for (final value in captures) {
      try {
        await value.stop();
      } catch (_) {}
    }
    messenger.setMockMethodCallHandler(channel, null);
    CaptureResourceLifetime.resetForTesting();
  });

  test(
    'stop joins pending consent and a late success cannot revive capture',
    () async {
      startGate = Completer<bool>();
      final value = capture();
      final starting = value.start((_, _, _, _, _) {});
      final stopping = value.stop();
      var returned = false;
      unawaited(stopping.then((_) => returned = true));
      try {
        await Future<void>(() {});
        expect(
          returned,
          isFalse,
          reason: 'accepted consent request still pending',
        );
      } finally {
        startGate!.complete(true);
        await stopping;
      }
      expect(await starting, isFalse);
      expect(value.rebindFrameSink((_, _, _, _, _) {}), isFalse);
      expect(await value.start((_, _, _, _, _) {}), isFalse);
    },
  );

  test(
    'replacement waits for closing owner and keeps its message handler',
    () async {
      final old = capture();
      expect(await old.start((_, _, _, _, _) {}), isTrue);
      stopGate = Completer<void>();
      final stopping = old.stop();
      var frames = 0;
      final fresh = capture();
      final starting = fresh.start((_, _, _, _, _) => frames++);
      try {
        await Future<void>(() {});
        expect(sessions.length, 1, reason: 'old stop has not acknowledged');
      } finally {
        stopGate!.complete();
        await stopping;
      }
      expect(await starting, isTrue);
      await deliver('frame', sessions.last);
      expect(frames, 1);
    },
  );

  test(
    'old stop cannot stop or detach a replacement after grant expiry',
    () async {
      final old = capture();
      expect(await old.start((_, _, _, _, _) {}), isTrue);
      await deliver('stopped', sessions.last);
      var frames = 0;
      final fresh = capture();
      expect(await fresh.start((_, _, _, _, _) => frames++), isTrue);
      final before = stops;
      await old.stop();
      expect(
        stops,
        before,
        reason: 'only its own native session may be stopped',
      );
      await deliver('frame', sessions.last);
      expect(frames, 1);
    },
  );

  test(
    'late stopped event for an old session does not close current capture',
    () async {
      final old = capture();
      expect(await old.start((_, _, _, _, _) {}), isTrue);
      final oldSession = sessions.last;
      await deliver('stopped', oldSession);
      var unexpected = 0, frames = 0;
      final fresh = capture(() => unexpected++);
      expect(await fresh.start((_, _, _, _, _) => frames++), isTrue);
      await deliver('stopped', oldSession);
      await deliver('frame', sessions.last);
      expect(unexpected, 0);
      expect(frames, 1);
    },
  );

  test(
    'failed stop remains owned and retry cannot be mistaken for absence',
    () async {
      final old = capture();
      expect(await old.start((_, _, _, _, _) {}), isTrue);
      refuseStop = true;
      await expectLater(old.stop(), throwsA(isA<PlatformException>()));
      final fresh = capture();
      expect(await fresh.start((_, _, _, _, _) {}), isFalse);
      refuseStop = false;
      await old.stop();
      expect(await fresh.start((_, _, _, _, _) {}), isTrue);
    },
  );

  test(
    'concurrent starts share one consent request and the first sink',
    () async {
      startGate = Completer<bool>();
      var first = 0, second = 0;
      final value = capture();
      final a = value.start((_, _, _, _, _) => first++);
      final b = value.start((_, _, _, _, _) => second++);
      startGate!.complete(true);
      expect(await a, isTrue);
      expect(await b, isTrue);
      expect(sessions, hasLength(1));
      await deliver('frame', sessions.single);
      expect((first, second), (1, 0));
    },
  );
  test(
    'a lost start reply stops its native attempt before yielding ownership',
    () async {
      loseStartReply = true;
      final old = capture();
      expect(await old.start((_, _, _, _, _) {}), isFalse);
      expect(stops, 1);
      loseStartReply = false;
      final fresh = capture();
      expect(await fresh.start((_, _, _, _, _) {}), isTrue);
    },
  );

  test(
    'an unacknowledged cleanup after lost start keeps replacement sealed',
    () async {
      loseStartReply = true;
      refuseStop = true;
      final old = capture();
      expect(await old.start((_, _, _, _, _) {}), isFalse);
      final fresh = capture();
      expect(await fresh.start((_, _, _, _, _) {}), isFalse);
      refuseStop = false;
      loseStartReply = false;
      await old.stop();
      expect(await fresh.start((_, _, _, _, _) {}), isTrue);
    },
  );

  test(
    'cancelling a waiting replacement cannot stop the closing owner',
    () async {
      final old = capture();
      expect(await old.start((_, _, _, _, _) {}), isTrue);
      stopGate = Completer<void>();
      final closing = old.stop();
      final fresh = capture();
      final starting = fresh.start((_, _, _, _, _) {});
      final cancel = fresh.stop();
      stopGate!.complete();
      await closing;
      await cancel;
      expect(await starting, isFalse);
      expect(stops, 1);
      expect(sessions, hasLength(1));
    },
  );

  test('unscoped and foreign frames cannot feed a consented sink', () async {
    var frames = 0, unexpected = 0;
    final value = capture(() => unexpected++);
    expect(await value.start((_, _, _, _, _) => frames++), isTrue);
    await deliver('frame', null);
    await deliver('frame', 'foreign-session');
    await deliver('stopped', null);
    await deliver('stopped', 'foreign-session');
    expect((frames, unexpected), (0, 0));
    await deliver('frame', sessions.single);
    expect(frames, 1);
  });
  test('profile retirement reaches an active screen projection', () async {
    final source = capture();
    expect(await source.start((_, _, _, _, _) {}), isTrue);
    final owner = await CaptureResourceLifetime.current().retire();
    expect(stops, 1, reason: 'retirement cannot overlook a live projection');
    expect(source.rebindFrameSink((_, _, _, _, _) {}), isFalse);
    await owner.verifyReleasedResources();
  });

  test(
    'a source constructed before erasure cannot adopt the next profile',
    () async {
      final source = capture();
      final owner = await CaptureResourceLifetime.current().retire();
      owner.releaseAdmission();
      expect(await source.start((_, _, _, _, _) {}), isFalse);
      expect(
        sessions,
        isEmpty,
        reason: 'no consent request for an old profile',
      );
    },
  );
  test(
    'projection retirement joins accepted consent before releasing ownership',
    () async {
      startGate = Completer<bool>();
      final source = capture();
      final starting = source.start((_, _, _, _, _) {});
      final retiring = CaptureResourceLifetime.current().retire();
      var finished = false;
      final observed = retiring.then((_) => finished = true);
      try {
        await Future<void>(() {});
        expect(stops, 1, reason: 'cancel consent promptly');
        expect(finished, isFalse, reason: 'accepted start is still unsettled');
      } finally {
        startGate!.complete(true);
        await observed;
      }
      expect(await starting, isFalse);
      expect(source.rebindFrameSink((_, _, _, _, _) {}), isFalse);
    },
  );

  test(
    'a refused projection stop blocks profile retirement until retry',
    () async {
      final source = capture();
      expect(await source.start((_, _, _, _, _) {}), isTrue);
      final scope = CaptureResourceLifetime.current();
      refuseStop = true;
      await expectLater(
        scope.retire(),
        throwsA(isA<CaptureResourceRetirementFailure>()),
      );
      expect(source.rebindFrameSink((_, _, _, _, _) {}), isFalse);
      refuseStop = false;
      final receipt = await scope.retire();
      expect(stops, 2);
      await receipt.verifyReleasedResources();
    },
  );

  test(
    'sealing profile admission immediately drops frames and engine rebind',
    () async {
      var frames = 0;
      final source = capture();
      expect(await source.start((_, _, _, _, _) => frames++), isTrue);
      await deliver('frame', sessions.single);
      expect(frames, 1);
      final scope = CaptureResourceLifetime.current();
      scope.sealAdmission();
      await deliver('frame', sessions.single);
      expect(frames, 1);
      expect(source.rebindFrameSink((_, _, _, _, _) {}), isFalse);
      await scope.retire();
    },
  );

  test(
    'an ordinary privacy cover does not end an ongoing screen-sharing call',
    () async {
      var frames = 0;
      final source = capture();
      expect(await source.start((_, _, _, _, _) => frames++), isTrue);
      await CaptureResourceLifetime.current().stopForPrivacy();
      expect(stops, 0);
      await deliver('frame', sessions.single);
      expect(frames, 1);
      expect(source.rebindFrameSink((_, _, _, _, _) {}), isTrue);
    },
  );

  test('a busy source retry cannot re-enter a retired profile', () async {
    final first = capture();
    expect(await first.start((_, _, _, _, _) {}), isTrue);
    final waiting = capture();
    expect(await waiting.start((_, _, _, _, _) {}), isFalse);
    final owner = await CaptureResourceLifetime.current().retire();
    owner.releaseAdmission();
    expect(await waiting.start((_, _, _, _, _) {}), isFalse);
    expect(sessions, hasLength(1));
  });
  test(
    'a delayed factory cannot bind new capture to an erased profile',
    () async {
      final old = CaptureResourceLifetime.current();
      final owner = await old.retire();
      owner.releaseAdmission();
      final source = AndroidScreenCapture(
        () {},
        channel: channel,
        isAndroid: true,
        captureLifetime: old,
      );
      captures.add(source);
      expect(await source.start((_, _, _, _, _) {}), isFalse);
      expect(sessions, isEmpty);
      await CaptureResourceLifetime.current().retire();
    },
  );
}
