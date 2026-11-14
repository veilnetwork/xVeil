import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/android_screen_capture.dart';

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
}
