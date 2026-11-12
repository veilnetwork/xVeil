import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/android_native_call_camera.dart';

class _ReplyGate {
  final entered = Completer<void>();
  final release = Completer<void>();
}

/// Commands take effect when received, not when their asynchronous reply arrives.
/// This preserves MethodChannel's FIFO requests while allowing Camera2 stop fences
/// and already-produced start replies to complete independently.
class _CameraPlatform {
  static const channel = MethodChannel('xveil/camera_start_lifecycle_test');
  final owners = <AndroidNativeCallCamera>[];
  final pending = <Future<bool>>[];
  final gates = <_ReplyGate>[];
  final starts = <String>[];
  _ReplyGate? nextStart;
  _ReplyGate? nextStop;
  Object? startFailure;
  bool malformedStart = false;
  String? hardware;
  int texture = 0;

  _CameraPlatform() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handle);
  }

  AndroidNativeCallCamera owner() {
    final camera = AndroidNativeCallCamera(channel: channel);
    owners.add(camera);
    return camera;
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

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'start':
        final id = (call.arguments as Map)['cameraId'] as String;
        starts.add(id);
        hardware = id;
        final reply = <String, Object?>{
          'textureId': ++texture,
          'width': 640,
          'height': 480,
          'previewRotation': 0,
          'mirror': false,
          'fps': 30,
          'cameraId': id,
          'facing': id,
        };
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
        hardware = null;
        final gate = nextStop;
        nextStop = null;
        if (gate != null) {
          gate.entered.complete();
          await gate.release.future;
        }
        return null;
      case 'stats':
        return <String, Object?>{'camera_running': hardware != null};
    }
    return null;
  }

  Future<bool> start(AndroidNativeCallCamera camera, String id) {
    final result = camera.start(
      engineAddress: 1234,
      width: 640,
      height: 480,
      fps: 30,
      cameraId: id,
    );
    pending.add(result);
    return result;
  }

  Future<void> dispose() async {
    for (final gate in gates) {
      if (!gate.release.isCompleted) gate.release.complete();
    }
    await Future.wait(pending);
    for (final camera in owners.reversed) {
      await camera.stop();
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    androidNativeCallCameraPreview.value = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _CameraPlatform platform;
  setUp(() => platform = _CameraPlatform());
  tearDown(() => platform.dispose());

  for (final reuseOwner in [true, false]) {
    for (final outcome in ['success', 'malformed', 'failure']) {
      test('late $outcome cannot replace capture, reuse=$reuseOwner', () async {
        final old = platform.owner();
        final next = reuseOwner ? old : platform.owner();
        final gate = platform.holdStart();
        platform.malformedStart = outcome == 'malformed';
        if (outcome == 'failure') {
          platform.startFailure = PlatformException(code: 'cancelled');
        }
        final pending = platform.start(old, 'front');
        await gate.entered.future;
        await old.stop();
        expect(await platform.start(next, 'back'), isTrue);
        final current = androidNativeCallCameraPreview.value;
        expect(current?.cameraId, 'back');
        gate.release.complete();
        expect(await pending, isFalse);
        expect(androidNativeCallCameraPreview.value, same(current));
        expect(next.cameraId, 'back');
        expect(platform.hardware, 'back');
        if (!reuseOwner) {
          await old.stop();
          expect(androidNativeCallCameraPreview.value, same(current));
          expect(platform.hardware, 'back');
        }
      });
    }

    test(
      'late initial stop cannot start superseded lens, reuse=$reuseOwner',
      () async {
        final old = platform.owner();
        final next = reuseOwner ? old : platform.owner();
        expect(await platform.start(old, 'front'), isTrue);
        final gate = platform.holdStop();
        final pending = platform.start(old, 'back');
        await gate.entered.future;
        expect(await platform.start(next, 'front'), isTrue);
        final current = androidNativeCallCameraPreview.value;
        gate.release.complete();
        expect(await pending, isFalse);
        expect(platform.starts, ['front', 'front']);
        expect(platform.hardware, 'front');
        expect(androidNativeCallCameraPreview.value, same(current));
      },
    );
  }

  test('stop during initial drain cancels the pending start', () async {
    final camera = platform.owner();
    expect(await platform.start(camera, 'front'), isTrue);
    final gate = platform.holdStop();
    final pending = platform.start(camera, 'back');
    await gate.entered.future;
    final stopping = camera.stop();
    gate.release.complete();
    await stopping;
    expect(await pending, isFalse);
    expect(platform.starts, ['front']);
    expect(platform.hardware, isNull);
    expect(androidNativeCallCameraPreview.value, isNull);
  });

  test('idle owner stop cannot stop another owner', () async {
    final idle = platform.owner();
    final camera = platform.owner();
    expect(await platform.start(camera, 'back'), isTrue);
    final current = androidNativeCallCameraPreview.value;
    await idle.stop();
    expect(platform.hardware, 'back');
    expect(androidNativeCallCameraPreview.value, same(current));
  });

  test('current start and stop own the hardware and preview', () async {
    final camera = platform.owner();
    expect(await platform.start(camera, 'back'), isTrue);
    expect(platform.hardware, 'back');
    expect(camera.cameraId, 'back');
    await camera.stop();
    expect(platform.hardware, isNull);
    expect(camera.diagnostics, isEmpty);
    expect(androidNativeCallCameraPreview.value, isNull);
  });

  for (final reuseOwner in [true, false]) {
    test(
      'retired owner still awaits its native stop fence, reuse=$reuseOwner',
      () async {
        final old = platform.owner();
        final next = reuseOwner ? old : platform.owner();
        expect(await platform.start(old, 'front'), isTrue);
        final gate = platform.holdStop();
        final replacement = platform.start(next, 'back');
        await gate.entered.future;
        var stopped = false;
        final stopping = old.stop().then((_) => stopped = true);
        // Drain runnable microtasks/events; no clock advancement or latency bound.
        await pumpEventQueue();
        expect(stopped, isFalse);
        gate.release.complete();
        await stopping;
        expect(stopped, isTrue);
        expect(await replacement, !reuseOwner);
        if (!reuseOwner) {
          expect(platform.hardware, 'back');
          expect(androidNativeCallCameraPreview.value?.cameraId, 'back');
        }
      },
    );
  }

  test(
    'stale start does not finish before replacement drains its old callbacks',
    () async {
      final old = platform.owner();
      final next = platform.owner();
      final reply = platform.holdStart();
      var finished = false;
      final pending = platform.start(old, 'front').then((value) {
        finished = true;
        return value;
      });
      await reply.entered.future;
      final fence = platform.holdStop();
      final replacement = platform.start(next, 'back');
      await fence.entered.future;
      reply.release.complete();
      await pumpEventQueue();
      expect(finished, isFalse);
      fence.release.complete();
      expect(await pending, isFalse);
      expect(await replacement, isTrue);
      expect(platform.hardware, 'back');
    },
  );

  test('malformed current reply cleans up opened hardware', () async {
    final camera = platform.owner();
    platform.malformedStart = true;
    expect(await platform.start(camera, 'back'), isFalse);
    expect(platform.hardware, isNull);
    expect(camera.diagnostics, isEmpty);
    expect(androidNativeCallCameraPreview.value, isNull);
  });

  test(
    'current platform failure cleans up partially opened hardware',
    () async {
      final camera = platform.owner();
      platform.startFailure = PlatformException(code: 'camera_start');
      expect(await platform.start(camera, 'back'), isFalse);
      expect(platform.hardware, isNull);
      expect(camera.diagnostics, isEmpty);
      expect(androidNativeCallCameraPreview.value, isNull);
    },
  );

  test(
    'preview listener can stop without resurrecting capture state',
    () async {
      final camera = platform.owner();
      Future<void>? stopping;
      void listener() {
        if (androidNativeCallCameraPreview.value != null) {
          stopping = camera.stop();
        }
      }

      androidNativeCallCameraPreview.addListener(listener);
      addTearDown(
        () => androidNativeCallCameraPreview.removeListener(listener),
      );
      expect(await platform.start(camera, 'front'), isFalse);
      await stopping;
      expect(camera.diagnostics, isEmpty);
      expect(platform.hardware, isNull);
      expect(androidNativeCallCameraPreview.value, isNull);
    },
  );

  test('preview listener can replace the owner during publication', () async {
    final old = platform.owner();
    final next = platform.owner();
    Future<bool>? replacement;
    void listener() {
      if (androidNativeCallCameraPreview.value?.cameraId == 'front') {
        replacement = platform.start(next, 'back');
      }
    }

    androidNativeCallCameraPreview.addListener(listener);
    addTearDown(() => androidNativeCallCameraPreview.removeListener(listener));
    expect(await platform.start(old, 'front'), isFalse);
    expect(await replacement, isTrue);
    await old.stop();
    expect(platform.hardware, 'back');
    expect(androidNativeCallCameraPreview.value?.cameraId, 'back');
  });
}
