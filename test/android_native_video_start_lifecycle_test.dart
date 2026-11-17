import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/android_native_call_video.dart';

class _ReplyGate {
  final entered = Completer<void>();
  final release = Completer<void>();
}

class _ManualTimer implements Timer {
  _ManualTimer(this.callback);
  final void Function(Timer) callback;
  bool _active = true;
  int _tick = 0;
  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
  @override
  void cancel() => _active = false;
  void fire() {
    if (!_active) return;
    _tick++;
    callback(this);
  }
}

/// Commands affect the one platform renderer on receipt. Already produced
/// replies can be delayed independently; this preserves MethodChannel FIFO.
class _VideoPlatform {
  static const channel = MethodChannel('xveil/video_start_lifecycle_test');
  final owners = <AndroidNativeCallVideoRenderer>[];
  final pending = <Future<bool>>[];
  final gates = <_ReplyGate>[];
  final starts = <int>[];
  final stops = <int?>[];
  _ReplyGate? nextStart;
  _ReplyGate? nextStop;
  _ReplyGate? nextStats;
  Object? startFailure;
  bool malformedStart = false;
  bool stoppedStats = false;
  int? hardware;
  int texture = 0;
  int statsCalls = 0;

  _VideoPlatform() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handle);
  }

  AndroidNativeCallVideoRenderer owner() {
    final owner = AndroidNativeCallVideoRenderer(channel: channel);
    owners.add(owner);
    return owner;
  }

  _ReplyGate holdStart() {
    final gate = _ReplyGate();
    gates.add(gate);
    return nextStart = gate;
  }

  _ReplyGate holdStop() {
    final gate = _ReplyGate();
    gates.add(gate);
    return nextStop = gate;
  }

  _ReplyGate holdStats() {
    final gate = _ReplyGate();
    gates.add(gate);
    return nextStats = gate;
  }

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'start':
        final engine = (call.arguments as Map)['engine'] as int;
        starts.add(engine);
        hardware = engine;
        final reply = <String, Object?>{'textureId': ++texture};
        final gate = nextStart;
        nextStart = null;
        final failure = startFailure;
        startFailure = null;
        final malformed = malformedStart;
        malformedStart = false;
        if (gate != null) {
          gate.entered.complete();
          await gate.release.future;
        }
        if (failure != null) throw failure;
        return malformed ? <String, Object?>{} : reply;
      case 'stop':
        stops.add(hardware);
        hardware = null;
        final gate = nextStop;
        nextStop = null;
        if (gate != null) {
          gate.entered.complete();
          await gate.release.future;
        }
        return null;
      case 'stats':
        statsCalls++;
        final reply = <String, Object?>{
          'video_texture_running': hardware != null && !stoppedStats,
          'video_texture_id': texture,
          'video_texture_frames': 5,
          'video_texture_width': 640,
          'video_texture_height': 480,
        };
        final gate = nextStats;
        nextStats = null;
        if (gate != null) {
          gate.entered.complete();
          await gate.release.future;
        }
        return reply;
    }
    return null;
  }

  Future<bool> start(AndroidNativeCallVideoRenderer owner, int engine) {
    final result = owner.start(engineAddress: engine);
    pending.add(result);
    return result;
  }

  Future<void> dispose() async {
    for (final gate in gates) {
      if (!gate.release.isCompleted) gate.release.complete();
    }
    await Future.wait(pending);
    for (final owner in owners.reversed) {
      await owner.stop();
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    androidNativeCallVideoTexture.value = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _VideoPlatform platform;
  setUp(() => platform = _VideoPlatform());
  tearDown(() => platform.dispose());

  for (final reuseOwner in [true, false]) {
    for (final outcome in ['success', 'malformed', 'failure']) {
      test(
        'late video $outcome preserves replacement, reuse=$reuseOwner',
        () async {
          final old = platform.owner();
          final next = reuseOwner ? old : platform.owner();
          final gate = platform.holdStart();
          platform.malformedStart = outcome == 'malformed';
          if (outcome == 'failure') {
            platform.startFailure = PlatformException(
              code: 'synthetic_cancelled',
            );
          }
          final pending = platform.start(old, 1);
          await gate.entered.future;
          expect(await platform.start(next, 2), isTrue);
          await next.refreshStats();
          final current = androidNativeCallVideoTexture.value;
          expect(current?.textureId, 2);
          final stops = platform.stops.length;
          gate.release.complete();
          expect(await pending, isFalse);
          expect(androidNativeCallVideoTexture.value, same(current));
          expect(next.isRunning, isTrue);
          expect(platform.hardware, 2);
          expect(platform.stops.length, stops);
          if (!reuseOwner) expect(old.isRunning, isFalse);
        },
      );
    }

    test(
      'late video initial stop cannot start old engine, reuse=$reuseOwner',
      () async {
        final old = platform.owner();
        final next = reuseOwner ? old : platform.owner();
        final gate = platform.holdStop();
        final pending = platform.start(old, 1);
        await gate.entered.future;
        expect(await platform.start(next, 2), isTrue);
        await next.refreshStats();
        final current = androidNativeCallVideoTexture.value;
        gate.release.complete();
        expect(await pending, isFalse);
        expect(platform.starts, [2]);
        expect(platform.hardware, 2);
        expect(androidNativeCallVideoTexture.value, same(current));
      },
    );

    for (final stopped in [false, true]) {
      test(
        'old video stats stopped=$stopped preserve replacement, reuse=$reuseOwner',
        () async {
          final old = platform.owner();
          final next = reuseOwner ? old : platform.owner();
          expect(await platform.start(old, 1), isTrue);
          await pumpEventQueue();
          platform.stoppedStats = stopped;
          final gate = platform.holdStats();
          final polling = old.refreshStats();
          await gate.entered.future;
          platform.stoppedStats = false;
          expect(await platform.start(next, 2), isTrue);
          await next.refreshStats();
          final current = androidNativeCallVideoTexture.value;
          gate.release.complete();
          await polling;
          expect(androidNativeCallVideoTexture.value, same(current));
          expect(platform.hardware, 2);
          expect(next.isRunning, isTrue);
          if (!reuseOwner) expect(old.isRunning, isFalse);
        },
      );
    }
  }

  for (final reuseOwner in [true, false]) {
    test(
      'superseded video completion awaits detach fence, reuse=$reuseOwner',
      () async {
        final old = platform.owner();
        final next = reuseOwner ? old : platform.owner();
        final first = platform.holdStart();
        final pending = platform.start(old, 1);
        await first.entered.future;
        final detach = platform.holdStop();
        final replacing = platform.start(next, 2);
        await detach.entered.future;
        var completed = false;
        final observed = pending.then((value) {
          completed = true;
          return value;
        });
        first.release.complete();
        await pumpEventQueue();
        expect(
          completed,
          isFalse,
          reason:
              'false must not permit engine disposal before old native detach',
        );
        detach.release.complete();
        expect(await observed, isFalse);
        expect(await replacing, isTrue);
        expect(platform.hardware, 2);
      },
    );
  }

  for (final action in ['stop', 'replace']) {
    test(
      'video notifier $action cannot resurrect startup or orphan a timer',
      () async {
        final timers = <_ManualTimer>[];
        await runZoned(
          () async {
            final old = platform.owner(), next = platform.owner();
            Future<void>? stopping;
            Future<bool>? replacing;
            var handled = false;
            void listener() {
              if (handled || androidNativeCallVideoTexture.value == null) {
                return;
              }
              handled = true;
              if (action == 'stop') {
                stopping = old.stop();
              } else {
                replacing = platform.start(next, 2);
              }
            }

            androidNativeCallVideoTexture.addListener(listener);
            try {
              expect(await platform.start(old, 1), isFalse);
              await stopping;
              if (replacing != null) expect(await replacing, isTrue);
              expect(old.isRunning, isFalse);
              expect(platform.hardware, action == 'replace' ? 2 : null);
              expect(
                timers.where((timer) => timer.isActive).length,
                action == 'replace' ? 1 : 0,
              );
            } finally {
              androidNativeCallVideoTexture.removeListener(listener);
              await stopping;
              await replacing;
              await next.stop();
              await old.stop();
            }
            expect(timers.where((timer) => timer.isActive), isEmpty);
          },
          zoneSpecification: ZoneSpecification(
            createPeriodicTimer: (self, parent, zone, duration, callback) {
              final timer = _ManualTimer(callback);
              timers.add(timer);
              return timer;
            },
          ),
        );
      },
    );
  }

  test(
    'old video stats completion cannot reopen the new polling gate',
    () async {
      final timers = <_ManualTimer>[];
      await runZoned(
        () async {
          final owner = platform.owner();
          expect(await platform.start(owner, 1), isTrue);
          await pumpEventQueue();
          final first = platform.holdStats();
          final polling = owner.refreshStats();
          await first.entered.future;
          final second = platform.holdStats();
          expect(await platform.start(owner, 2), isTrue);
          await second.entered.future;
          first.release.complete();
          await polling;
          final calls = platform.statsCalls;
          final timer = timers.singleWhere((timer) => timer.isActive);
          timer.fire();
          timer.fire();
          await pumpEventQueue();
          expect(
            platform.statsCalls,
            calls,
            reason:
                'the new poll is still held; the timer cannot stack another',
          );
          second.release.complete();
          await pumpEventQueue();
          timer.fire();
          await pumpEventQueue();
          expect(
            platform.statsCalls,
            calls + 1,
            reason: 'completed current polling must admit the next timer tick',
          );
          await owner.stop();
          expect(timers.where((timer) => timer.isActive), isEmpty);
        },
        zoneSpecification: ZoneSpecification(
          createPeriodicTimer: (self, parent, zone, duration, callback) {
            final timer = _ManualTimer(callback);
            timers.add(timer);
            return timer;
          },
        ),
      );
    },
  );

  test('stop during video initial drain cancels startup', () async {
    final owner = platform.owner();
    final gate = platform.holdStop();
    final pending = platform.start(owner, 1);
    final stopping = owner.stop();
    await gate.entered.future;
    gate.release.complete();
    await stopping;
    expect(await pending, isFalse);
    expect(platform.starts, isEmpty);
    expect(platform.hardware, isNull);
    expect(androidNativeCallVideoTexture.value, isNull);
  });

  test('retired video owner cannot stop or clear replacement', () async {
    final old = platform.owner(), next = platform.owner();
    expect(await platform.start(old, 1), isTrue);
    expect(await platform.start(next, 2), isTrue);
    await next.refreshStats();
    final current = androidNativeCallVideoTexture.value;
    final stops = platform.stops.length;
    await old.stop();
    expect(androidNativeCallVideoTexture.value, same(current));
    expect(platform.hardware, 2);
    expect(platform.stops.length, stops);
    expect(next.isRunning, isTrue);
  });

  for (final outcome in ['success', 'malformed', 'failure']) {
    test('current video $outcome keeps honest platform ownership', () async {
      final owner = platform.owner();
      platform.malformedStart = outcome == 'malformed';
      if (outcome == 'failure') {
        platform.startFailure = PlatformException(code: 'synthetic_refusal');
      }
      final started = await platform.start(owner, 1);
      expect(started, outcome == 'success');
      expect(owner.isRunning, started);
      expect(platform.hardware, started ? 1 : null);
      expect(androidNativeCallVideoTexture.value != null, started);
      if (started) {
        await owner.refreshStats();
        expect(androidNativeCallVideoTexture.value?.frames, 5);
      }
    });
  }
}
