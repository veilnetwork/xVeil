import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_media/veil_media.dart';
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/android_camera_capture.dart';
import 'package:xveil/state/android_native_call_camera.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/veil_call_media.dart';

NodeId _id(int value) => NodeId(Uint8List(32)..fillRange(0, 32, value));

class _Transport implements VeilFlutterTransport {
  @override
  Future<NodeId> peerFacingNodeId({
    Duration timeout = const Duration(seconds: 2),
  }) async => _id(1);
  @override
  Future<int> openMediaChannel(
    Uint8List dst, {
    required Uint8List txKey,
    required Uint8List rxKey,
    bool direct = false,
    bool relay = false,
  }) async => 42;
  @override
  bool get supportsCallControl => false;
  @override
  int setMediaScreenSharing(int channel, bool enabled) => 0;
  @override
  bool hasCallControl(int channel) => false;
  @override
  int mediaRecvCount(Uint8List peer) => 0;
  @override
  void closeMediaChannel(int channel) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Engine implements VeilMediaEngine {
  bool disposed = false;
  bool refuseStats = false;
  int videoStarts = 0;
  @override
  bool get supportsNoiseSuppression => true;
  @override
  bool setNoiseSuppression(bool enabled) => true;
  @override
  bool setIndependentTransportFeedback(bool enabled) => true;
  @override
  bool get supportsLowRateVideo => false;
  @override
  bool get supportsVideoSendPause => false;
  @override
  int get nativeAddress => 1;
  @override
  bool startAudio({bool send = true, bool recv = true}) => true;
  @override
  Map<String, dynamic> getStats() {
    if (refuseStats) throw StateError('synthetic engine stats refusal');
    return {
      'audio_capture_start_result': 1,
      'audio_playout_start_result': 1,
      // Android camera capture belongs to Camera2/plugin, not this engine.
      'camera_capturing': 0,
    };
  }

  @override
  void setMicMuted(bool muted) {}
  @override
  bool trySetMicMuted(bool muted) => true;
  @override
  bool startVideo({
    bool send = true,
    bool recv = true,
    int maxBitrateKbps = 150,
    num maxFps = 15,
  }) {
    videoStarts++;
    return true;
  }

  @override
  bool stopVideo() => true;
  @override
  bool stopAudio() => true;
  @override
  void dispose() => disposed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NativeCamera extends AndroidNativeCallCamera {
  _NativeCamera(bool result) : result = Future.value(result);
  _NativeCamera.held(this.result);
  final Future<bool> result;
  final entered = Completer<void>();
  bool running = false;
  int stops = 0;
  @override
  bool get isRunning => running;
  @override
  String? get cameraId => running ? 'camera-fixture' : null;
  @override
  Future<bool> start({
    required int engineAddress,
    required int width,
    required int height,
    required int fps,
    String? cameraId,
  }) async {
    entered.complete();
    return running = await result;
  }

  @override
  Future<void> stop() async {
    stops++;
    running = false;
  }
}

class _PluginCamera extends AndroidCameraCapture {
  _PluginCamera(this.result);
  final Future<bool> result;
  final entered = Completer<void>();
  int stops = 0;
  @override
  String? get cameraId => 'camera-fixture';
  @override
  Future<bool> startAndroid420(Android420FrameSink sink) async {
    entered.complete();
    return result;
  }

  @override
  Future<void> stop() async => stops++;
}

class _Wire implements MessagingService {
  @override
  bool backgroundStashPaused = false;
  @override
  bool get isAnonymousIdentity => false;
  @override
  void Function(NodeId, CallSignal)? onCallSignal;
  @override
  bool Function(NodeId, CallSignal)? acceptsCallDeviceSignal;
  final sent = <CallSignal>[];
  @override
  Future<NodeId> localDeviceId() async => _id(1);
  @override
  void pinCallReplyDevice(String callId, NodeId identity, NodeId device) {}
  @override
  Future<void> sendCallSignal(NodeId peer, CallSignal signal) async {
    sent.add(signal);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _connect(CallService service, _Wire wire) async {
  await service.placeCall(_id(2), const CallMedia(audio: true, video: true));
  final active = Completer<void>();
  final subscription = service.changes.listen((call) {
    if (call?.status == CallStatus.active && !active.isCompleted) {
      active.complete();
    }
  });
  try {
    wire.onCallSignal!(
      _id(2),
      CallSignal(
        callId: service.current!.callId,
        type: CallSignalType.answer,
        posture: CallPosture.anonymous,
        mediaKey: generateCallMediaKeyContribution(),
      ),
    );
    await active.future;
  } finally {
    await subscription.cancel();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const permissions = MethodChannel('xveil/media_permissions');
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    diagnosticJournal.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissions, (_) async => true);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissions, null);
  });

  test('Android camera denial reports receive-only posture', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          permissions,
          (call) async => (call.arguments as Map)['type'] != 'video',
        );
    final wire = _Wire(), engine = _Engine();
    var opens = 0;
    final camera = _NativeCamera(true);
    final controller = VeilCallMediaController(
      _Transport(),
      engineFactory: ({required veilChan, required localId, required peerId}) =>
          engine,
      androidCameraCapture: true,
      nativeCameraFactory: () {
        opens++;
        return camera;
      },
    );
    final service = CallService(wire, media: controller)..start();
    try {
      await _connect(service, wire);
      await pumpEventQueue();
      expect(opens, 0);
      expect(service.current?.status, CallStatus.active);
      expect(service.current?.media.video, isTrue);
      expect(service.current?.cameraOn, isFalse);
      expect(controller.startedWithoutCamera, isTrue);
      expect(engine.disposed, isFalse);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(permissions, (_) async => true);
      await service.setCameraEnabled(true);
      expect(opens, 1);
      expect(camera.running, isTrue);
      expect(service.current?.cameraOn, isTrue);
    } finally {
      service.dispose();
      await controller.stop();
    }
  });

  for (final initial in [true, false]) {
    for (final outcome in ['native', 'fallback', 'refused', 'exception']) {
      test(
        'Android camera posture initial=$initial outcome=$outcome',
        () async {
          final wire = _Wire(), engine = _Engine();
          final native = _NativeCamera(outcome == 'native');
          final sourceResult = Completer<bool>();
          final fallback = _PluginCamera(sourceResult.future);
          final cameras = Queue<_NativeCamera>.of([
            if (!initial) _NativeCamera(true),
            native,
            _NativeCamera(true),
          ]);
          final controller = VeilCallMediaController(
            _Transport(),
            engineFactory:
                ({required veilChan, required localId, required peerId}) =>
                    engine,
            androidCameraCapture: true,
            nativeCameraFactory: cameras.removeFirst,
            cameraCaptureFactory: (_, _) => fallback,
          );
          final service = CallService(wire, media: controller)..start();
          try {
            await _connect(service, wire);
            Future<void>? toggling;
            if (!initial) {
              await pumpEventQueue();
              await service.setCameraEnabled(false);
              toggling = service.setCameraEnabled(true);
            }
            await native.entered.future;
            if (outcome != 'native') {
              await fallback.entered.future;
              if (outcome == 'exception') {
                sourceResult.completeError(
                  StateError('synthetic source failure'),
                );
              } else {
                sourceResult.complete(outcome == 'fallback');
              }
            }
            await toggling;
            await pumpEventQueue();
            final started = outcome == 'native' || outcome == 'fallback';
            expect(service.current?.status, CallStatus.active);
            expect(service.current?.media.video, isTrue);
            expect(engine.disposed, isFalse);
            expect(service.current?.cameraOn, started);
            expect(controller.startedWithoutCamera, !started);
            if (kDiagnosticReportEnabled) {
              final report = diagnosticJournal.toJson();
              final evidence = report['last_evidence'] as Map;
              expect((evidence['cameraStart'] as Map)['values'], {
                'success': started ? 1 : 0,
                'origin':
                    (initial
                            ? CameraStartOrigin.callStart
                            : CameraStartOrigin.toggle)
                        .index,
              });
              final encoded = jsonEncode(report);
              for (final private in [
                'synthetic source failure',
                'camera-fixture',
                service.current!.callId,
                _id(2).hex,
              ]) {
                expect(encoded, isNot(contains(private)));
              }
            }
            if (!started) {
              expect(fallback.stops, greaterThan(0));
              expect(
                wire.sent.where((s) => s.capture != null).last.capture?.video,
                isFalse,
              );
              await service.setCameraEnabled(true);
              await pumpEventQueue();
              expect(service.current?.cameraOn, isTrue);
              expect(controller.startedWithoutCamera, isFalse);
            }
          } finally {
            if (!sourceResult.isCompleted) sourceResult.complete(false);
            service.dispose();
            await controller.stop();
          }
        },
      );
    }
  }

  for (final stage in ['native', 'fallback']) {
    for (final action in ['off', 'replacement', 'hangup']) {
      for (final outcome in [true, false, if (stage == 'fallback') null]) {
        test('late Android $stage result=$outcome respects $action', () async {
          final wire = _Wire(), engine = _Engine();
          final result = Completer<bool>();
          final oldNative = stage == 'native'
              ? _NativeCamera.held(result.future)
              : _NativeCamera(false);
          final replacement = _NativeCamera(true);
          final fallback = _PluginCamera(
            stage == 'fallback' ? result.future : Future.value(false),
          );
          final cameras = Queue<_NativeCamera>.of([oldNative, replacement]);
          final controller = VeilCallMediaController(
            _Transport(),
            engineFactory:
                ({required veilChan, required localId, required peerId}) =>
                    engine,
            androidCameraCapture: true,
            nativeCameraFactory: cameras.removeFirst,
            cameraCaptureFactory: (_, _) => fallback,
          );
          final service = CallService(wire, media: controller)..start();
          var failures = 0;
          final subscription = controller.cameraUnavailable.listen((_) {
            failures++;
          });
          try {
            await _connect(service, wire);
            await (stage == 'native' ? oldNative.entered : fallback.entered)
                .future;
            if (action == 'hangup') {
              await service.hangup();
            } else {
              await service.setCameraEnabled(false);
              if (action == 'replacement') {
                await service.setCameraEnabled(true);
                await replacement.entered.future;
              }
            }
            final before = kDiagnosticReportEnabled
                ? jsonEncode(
                    (diagnosticJournal.toJson()['last_evidence']
                        as Map)['cameraStart'],
                  )
                : null;
            if (outcome == null) {
              result.completeError(
                StateError('synthetic retired source failure'),
              );
            } else {
              result.complete(outcome);
            }
            await pumpEventQueue();
            expect(failures, 0);
            expect(controller.startedWithoutCamera, isFalse);
            if (kDiagnosticReportEnabled) {
              expect(
                jsonEncode(
                  (diagnosticJournal.toJson()['last_evidence']
                      as Map)['cameraStart'],
                ),
                before,
              );
            }
            if (action == 'hangup') {
              expect(service.current?.isLive, isNot(isTrue));
              expect(engine.disposed, isTrue);
            } else {
              expect(service.current?.status, CallStatus.active);
              expect(service.current?.cameraOn, action == 'replacement');
            }
            if (action == 'replacement') {
              expect(replacement.running, isTrue);
              expect(replacement.stops, 0);
            }
            if (stage == 'native') {
              expect(fallback.entered.isCompleted, isFalse);
              expect(oldNative.running, isFalse);
              expect(oldNative.stops, greaterThan(0));
            } else {
              expect(fallback.stops, greaterThan(0));
            }
          } finally {
            if (!result.isCompleted) result.complete(false);
            service.dispose();
            await controller.stop();
            await subscription.cancel();
          }
        });
      }
    }
  }

  for (final observed in [false, true, null, 0, 'false']) {
    for (final unreadableStats in [false, if (observed == false) true]) {
      test(
        'native Android terminal status is explicit: '
        '${observed.runtimeType}/$observed stats-failure=$unreadableStats',
        () async {
          final polls = <void Function()>[];
          await runZoned(
            () async {
              const channel = MethodChannel(
                'xveil/native_camera_terminal_test',
              );
              Object? running = true;
              var opens = 0;
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .setMockMethodCallHandler(channel, (call) async {
                    switch (call.method) {
                      case 'start':
                        running = true;
                        opens++;
                        return {
                          'textureId': opens,
                          'width': 640,
                          'height': 480,
                          'previewRotation': 0,
                          'mirror': false,
                          'fps': 30,
                          'cameraId': 'camera-fixture',
                          'facing': 'front',
                        };
                      case 'stats':
                    return {'camera_running': ?running};
                      case 'stop':
                        running = false;
                    }
                    return null;
                  });
              final wire = _Wire(), engine = _Engine();
              late AndroidNativeCallCamera source;
              final controller = VeilCallMediaController(
                _Transport(),
                engineFactory:
                    ({required veilChan, required localId, required peerId}) =>
                        engine,
                androidCameraCapture: true,
                nativeCameraFactory: () =>
                    source = AndroidNativeCallCamera(channel: channel),
              );
              final service = CallService(wire, media: controller)..start();
              var failures = 0;
              final subscription = controller.cameraUnavailable.listen((_) {
                failures++;
              });
              void poll() {
                for (final tick in polls.toList()) {
                  tick();
                }
              }

              try {
                await _connect(service, wire);
                await pumpEventQueue();
                expect(source.isRunning, isTrue);
                running = observed;
                await source.refreshStats();
                engine.refuseStats = unreadableStats;
                poll();
                await pumpEventQueue();
                final stopped = observed == false;
                expect(service.current?.status, CallStatus.active);
                expect(engine.disposed, isFalse);
                expect(service.current?.cameraOn, !stopped);
                expect(controller.startedWithoutCamera, stopped);
                expect(failures, stopped ? 1 : 0);
                if (kDiagnosticReportEnabled) {
                  final report = diagnosticJournal.toJson();
                  final evidence = report['last_evidence'] as Map;
                  expect(
                    evidence['cameraStopped'],
                    stopped
                        ? containsPair('values', {'cameraCapturing': 0})
                        : isNull,
                  );
                  final encoded = jsonEncode(report);
                  for (final private in [
                    'synthetic engine stats refusal',
                    'camera-fixture',
                    service.current!.callId,
                    _id(2).hex,
                  ]) {
                    expect(encoded, isNot(contains(private)));
                  }
                }
                poll();
                await pumpEventQueue();
                expect(failures, stopped ? 1 : 0);
                if (stopped) {
                  expect(androidNativeCallCameraPreview.value, isNull);
                  expect(
                    wire.sent
                        .where((s) => s.capture != null)
                        .last
                        .capture
                        ?.video,
                    isFalse,
                  );
                  engine.refuseStats = false;
                  await service.setCameraEnabled(true);
                  await pumpEventQueue();
                  expect(opens, 2);
                  expect(source.isRunning, isTrue);
                  expect(service.current?.cameraOn, isTrue);
                  expect(controller.startedWithoutCamera, isFalse);
                }
                await service.setCameraEnabled(false);
                poll();
                await pumpEventQueue();
                expect(service.current?.cameraOn, isFalse);
                expect(failures, stopped ? 1 : 0);
              } finally {
                service.dispose();
                await controller.stop();
                await subscription.cancel();
                TestDefaultBinaryMessengerBinding
                    .instance
                    .defaultBinaryMessenger
                    .setMockMethodCallHandler(channel, null);
                androidNativeCallCameraPreview.value = null;
              }
            },
            zoneSpecification: ZoneSpecification(
              createPeriodicTimer: (self, parent, zone, interval, callback) {
                final timer = parent.createPeriodicTimer(
                  zone,
                  interval,
                  callback,
                );
                if (interval == const Duration(seconds: 1)) {
                  timer.cancel();
                  polls.add(() => zone.runUnary(callback, timer));
                }
                return timer;
              },
            ),
          );
        },
      );
    }
  }
}
