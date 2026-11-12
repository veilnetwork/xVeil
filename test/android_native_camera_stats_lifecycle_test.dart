import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/android_native_call_camera.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (reuseOwner, stopOld) in [
    (true, true),
    (false, true),
    (false, false),
  ]) {
    test(
      'late front-camera stats cannot clear back preview, reuse=$reuseOwner stopOld=$stopOld',
      () async {
        const channel = MethodChannel('xveil/camera_stats_lifecycle_test');
        final entered = Completer<void>();
        final oldReply = Completer<Map<String, Object?>>();
        var holdStats = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              switch (call.method) {
                case 'start':
                  final id = (call.arguments as Map)['cameraId'];
                  return <String, Object?>{
                    'textureId': id == 'front' ? 1 : 2,
                    'width': 640,
                    'height': 480,
                    'previewRotation': 0,
                    'mirror': id == 'front',
                    'fps': 30,
                    'cameraId': id,
                    'facing': id,
                  };
                case 'stats':
                  if (holdStats) {
                    if (!entered.isCompleted) entered.complete();
                    return oldReply.future;
                  }
                  return <String, Object?>{'camera_running': true, 'frames': 1};
                case 'stop':
                  return null;
              }
              return null;
            });
        final front = AndroidNativeCallCamera(channel: channel);
        final back = reuseOwner
            ? front
            : AndroidNativeCallCamera(channel: channel);
        addTearDown(() async {
          if (!oldReply.isCompleted) {
            oldReply.complete({'camera_running': false});
          }
          await back.stop();
          if (!reuseOwner) await front.stop();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
          androidNativeCallCameraPreview.value = null;
        });
        Future<bool> start(AndroidNativeCallCamera owner, String id) =>
            owner.start(
              engineAddress: 1234,
              width: 640,
              height: 480,
              fps: 30,
              cameraId: id,
            );

        expect(await start(front, 'front'), isTrue);
        expect(androidNativeCallCameraPreview.value?.mirror, isTrue);
        holdStats = true;
        final pending = front.refreshStats();
        await entered.future;
        if (stopOld) await front.stop();
        holdStats = false;
        expect(await start(back, 'back'), isTrue);
        final current = androidNativeCallCameraPreview.value;
        expect(current?.cameraId, 'back');
        expect(current?.mirror, isFalse);
        oldReply.complete({'camera_running': false});
        await pending;
        expect(androidNativeCallCameraPreview.value, same(current));
        expect(back.isRunning, isTrue);
        expect(back.diagnostics['camera_facing'], 'back');
        if (!reuseOwner && stopOld) {
          expect(front.isRunning, isFalse);
          expect(front.diagnostics, isEmpty);
        }
      },
    );
  }

  test('current stopped-camera stats still remove its own preview', () async {
    const channel = MethodChannel('xveil/camera_stats_current_test');
    var running = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'start' => <String, Object?>{
              'textureId': 3,
              'width': 640,
              'height': 480,
              'previewRotation': 0,
              'mirror': false,
              'fps': 30,
              'cameraId': 'back',
              'facing': 'back',
            },
            'stats' => <String, Object?>{'camera_running': running},
            _ => null,
          };
        });
    final camera = AndroidNativeCallCamera(channel: channel);
    addTearDown(() async {
      await camera.stop();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      androidNativeCallCameraPreview.value = null;
    });
    expect(
      await camera.start(engineAddress: 1234, width: 640, height: 480, fps: 30),
      isTrue,
    );
    expect(androidNativeCallCameraPreview.value, isNotNull);
    running = false;
    await camera.refreshStats();
    expect(camera.isRunning, isFalse);
    expect(androidNativeCallCameraPreview.value, isNull);
  });
}
