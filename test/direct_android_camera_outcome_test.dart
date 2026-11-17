import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_media/veil_media.dart';
import 'package:veil_flutter/veil_ffi.dart' show MediaPacketSource;
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
  final opened = <int>[];
  final closed = <int>[];
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
  }) async {
    final channel = 42 + opened.length;
    opened.add(channel);
    return channel;
  }

  @override
  bool get supportsCallControl => false;
  @override
  int setMediaScreenSharing(int channel, bool enabled) => 0;
  @override
  bool hasCallControl(int channel) => false;
  @override
  int mediaRecvCount(Uint8List peer) => 0;
  @override
  void closeMediaChannel(int channel) => closed.add(channel);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Engine implements VeilMediaEngine {
  bool disposed = false;
  bool refuseStats = false;
  int videoStarts = 0;
  int audioStops = 0;
  int disposals = 0;
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
  bool stopAudio() {
    audioStops++;
    return true;
  }

  @override
  void dispose() {
    disposals++;
    disposed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RelayEngine extends _Engine {
  @override
  bool setMaxRtpPacketSize(int bytes) => true;
  @override
  bool setAudioPacketOverhead(int bytes) => true;
  @override
  bool setVideoPacketOverhead(int bytes) => true;
  @override
  bool get supportsChannelRebind => false;
}

class _AudioOutcomeRelayEngine extends _RelayEngine {
  _AudioOutcomeRelayEngine({
    this.capture = 0,
    this.playout = 1,
    this.muteAccepted = true,
  });
  int capture;
  final int playout;
  final bool muteAccepted;
  final mutes = <bool>[];
  @override
  bool startAudio({bool send = true, bool recv = true}) =>
      capture == 1 && playout == 1;
  @override
  Map<String, dynamic> getStats() => {
    ...super.getStats(),
    'audio_capture_start_result': capture,
    'audio_playout_start_result': playout,
  };
  @override
  bool trySetMicMuted(bool muted) {
    mutes.add(muted);
    return muteAccepted && (muted || capture == 1);
  }
}

class _RepairTransport extends _Transport {
  Completer<void>? nextIdentity;
  final identityEntered = Completer<void>();
  final relayOpens = <bool>[];
  final directOpens = <bool>[];
  @override
  Future<int> openMediaChannel(
    Uint8List dst, {
    required Uint8List txKey,
    required Uint8List rxKey,
    bool direct = false,
    bool relay = false,
  }) {
    relayOpens.add(relay);
    directOpens.add(direct);
    return super.openMediaChannel(
      dst,
      txKey: txKey,
      rxKey: rxKey,
      direct: direct,
      relay: relay,
    );
  }

  @override
  Future<NodeId> peerFacingNodeId({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final gate = nextIdentity;
    nextIdentity = null;
    if (gate != null) {
      identityEntered.complete();
      await gate.future;
    }
    return _id(1);
  }

  @override
  Future<bool> configureMediaRouteProbes(
    int channel, {
    required NodeId directPeer,
    required NodeId relayPeer,
  }) async => true;
  @override
  int setRelayMediaBatching(int channel, bool on, {bool compact = false}) => 0;
  @override
  Map<String, int>? mediaChannelStats(int channel) => const {};
  @override
  Map<String, Object?>? mediaPacketCost(
    int channel, {
    required int packetBytes,
    MediaPacketSource source = MediaPacketSource.audio,
  }) => null;
}

class _ObservedRepair extends VeilCallMediaController {
  _ObservedRepair(
    super.transport, {
    required CallMediaEngineFactory engineFactory,
    required AndroidNativeCallCamera Function() nativeCameraFactory,
    required AndroidCameraCapture Function(bool, String?) cameraCaptureFactory,
  }) : super(
         engineFactory: engineFactory,
         androidCameraCapture: true,
         nativeCameraFactory: nativeCameraFactory,
         cameraCaptureFactory: cameraCaptureFactory,
       );
  final repairCompleted = Completer<bool>();
  @override
  Future<bool> repairRoute() async {
    final result = await super.repairRoute();
    if (!repairCompleted.isCompleted) repairCompleted.complete(result);
    return result;
  }
}

class _NativeCamera extends AndroidNativeCallCamera {
  _NativeCamera(bool result) : result = Future.value(result);
  _NativeCamera.held(this.result);
  final Future<bool> result;
  final entered = Completer<void>();
  bool running = false;
  int stops = 0;
  Completer<void>? stopGate;
  Completer<void>? stopEntered;
  void Function()? onStop;
  String? requestedId;
  @override
  Future<List<AndroidNativeCameraDevice>> listDevices() async => const [
    AndroidNativeCameraDevice(
      id: 'camera-fixture',
      label: 'Front',
      facing: 'front',
    ),
    AndroidNativeCameraDevice(
      id: 'back-fixture',
      label: 'Back',
      facing: 'back',
    ),
  ];
  @override
  bool get isRunning => running;
  @override
  String? get cameraId => running ? requestedId ?? 'camera-fixture' : null;
  @override
  Future<bool> start({
    required int engineAddress,
    required int width,
    required int height,
    required int fps,
    String? cameraId,
  }) async {
    entered.complete();
    requestedId = cameraId;
    return running = await result;
  }

  @override
  Future<void> stop() {
    stops++;
    running = false;
    final gate = stopGate;
    stopGate = null;
    final listener = onStop;
    onStop = null;
    listener?.call();
    if (gate != null) {
      stopEntered!.complete();
      return gate.future;
    }
    return Future<void>.value();
  }
}

class _PluginCamera extends AndroidCameraCapture {
  _PluginCamera(this.result, {this.id = 'camera-fixture'});
  final Future<bool> result;
  final String id;
  final entered = Completer<void>();
  int stops = 0;
  @override
  String? get cameraId => id;
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

Future<void> _connect(
  CallService service,
  _Wire wire, {
  CallPosture peerPosture = CallPosture.anonymous,
}) async {
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
        posture: peerPosture,
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

  for (final outcome in [
    'receive-only',
    'already-muted',
    'healthy',
    'output-failure',
    'mute-refusal',
  ]) {
    test('rebuilt audio reports capture posture after $outcome', () async {
      final wire = _Wire(), transport = _RepairTransport();
      final old = _RelayEngine();
      final next = _AudioOutcomeRelayEngine(
        capture: outcome == 'healthy' ? 1 : 0,
        playout: outcome == 'output-failure' ? 0 : 1,
        muteAccepted: outcome != 'mute-refusal',
      );
      var creates = 0;
      final controller = _ObservedRepair(
        transport,
        engineFactory:
            ({required veilChan, required localId, required peerId}) =>
                creates++ == 0 ? old : next,
        nativeCameraFactory: () => _NativeCamera(true),
        cameraCaptureFactory: (_, _) => _PluginCamera(Future.value(true)),
      );
      final service = CallService(wire, media: controller)..start();
      try {
        await _connect(service, wire, peerPosture: CallPosture.direct);
        await pumpEventQueue();
        if (outcome == 'already-muted') await service.setMicEnabled(false);
        wire.sent.clear();
        final callId = service.current!.callId;
        wire.onCallSignal!(
          _id(2),
          CallSignal(
            callId: callId,
            type: CallSignalType.health,
            mediaRepairRequested: true,
            sentAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        final repaired = await controller.repairCompleted.future;
        await pumpEventQueue();
        final failed = outcome == 'output-failure' || outcome == 'mute-refusal';
        expect(repaired, !failed);
        if (failed) {
          expect(service.current?.isLive, isNot(true));
          expect(wire.sent.any((s) => s.type == CallSignalType.end), isTrue);
          return;
        }
        expect(service.current?.status, CallStatus.active);
        expect(service.current?.callId, callId);
        expect(controller.activeTransport, CallTransportKind.relay);
        expect(service.current?.cameraOn, isTrue);
        expect(next.disposed, isFalse);
        expect(service.current?.micOn, outcome == 'healthy');
        expect(controller.startedWithoutMicrophone, outcome != 'healthy');
        expect(transport.relayOpens, [true, true]);
        expect(transport.directOpens, [false, false]);
        if (outcome == 'receive-only') {
          final captures = wire.sent.where((s) => s.capture != null);
          expect(captures, isNotEmpty);
          expect(captures.last.capture!.audio, isFalse);
          expect(captures.last.capture!.video, isTrue);
          expect(next.mutes.last, isTrue);
          next.capture = 1;
          await service.setMicEnabled(true);
          await pumpEventQueue();
          expect(service.current?.micOn, isTrue);
          expect(controller.startedWithoutMicrophone, isFalse);
          expect(wire.sent.last.capture?.audio, isTrue);
        }
      } finally {
        service.dispose();
        await controller.stop();
      }
    });
  }

  for (final mode in [
    'normal-native',
    'normal-plugin',
    'fence-native',
    'fence-plugin',
    'startup-native',
    'startup-plugin',
    'startup-error-native',
    'startup-error-plugin',
    'normal-lookup-failure',
    'pending-native',
    'reentrant-native',
    'normal-failure',
    'new-call',
    'hangup',
  ]) {
    test('pending route repair preserves $mode session', () async {
      final wire = _Wire(), transport = _RepairTransport();
      final created = <_RelayEngine>[];
      final old = _NativeCamera(true);
      final native = !mode.endsWith('plugin');
      final cameras = Queue<_NativeCamera>.of([
        old,
        _NativeCamera(native),
        _NativeCamera(native),
        _NativeCamera(native),
      ]);
      final plugins = <_PluginCamera>[];
      final controller = _ObservedRepair(
        transport,
        engineFactory:
            ({required veilChan, required localId, required peerId}) {
              if (mode == 'normal-failure' && created.isNotEmpty) return null;
              final engine = _RelayEngine();
              created.add(engine);
              return engine;
            },
        nativeCameraFactory: cameras.removeFirst,
        cameraCaptureFactory: (_, _) {
          final camera = _PluginCamera(Future.value(true));
          plugins.add(camera);
          return camera;
        },
      );
      final service = CallService(wire, media: controller)..start();
      final release = Completer<void>(), identity = Completer<void>();
      Future<bool>? repairing;
      Future<bool>? latest;
      try {
        await _connect(
          service,
          wire,
          peerPosture: CallPosture.direct,
        ).timeout(const Duration(seconds: 5));
        await old.entered.future;
        await pumpEventQueue();
        expect(service.current?.transport, CallTransportKind.relay);
        expect(controller.activeTransport, CallTransportKind.relay);
        final first = service.current!;
        old.stopGate = release;
        old.stopEntered = Completer<void>();
        if (mode == 'reentrant-native') {
          old.onStop = () {
            latest = controller.start(service.current!);
          };
        }
        wire.onCallSignal!(
          _id(2),
          CallSignal(
            callId: first.callId,
            type: CallSignalType.health,
            mediaRepairRequested: true,
            sentAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        repairing = controller.repairCompleted.future;
        await old.stopEntered!.future;
        if (mode.startsWith('startup') || mode == 'normal-lookup-failure') {
          transport.nextIdentity = identity;
          release.complete();
          await transport.identityEntered.future;
        }
        if (mode == 'pending-native') {
          transport.nextIdentity = identity;
          latest = controller.start(service.current!);
          await transport.identityEntered.future;
        }
        if (mode.startsWith('fence') ||
            mode.startsWith('startup') ||
            mode == 'reentrant-native') {
          if (mode == 'reentrant-native') {
            expect(await latest, isTrue);
          } else {
            expect(await controller.start(service.current!), isTrue);
          }
          await pumpEventQueue();
          expect(created.length, 2);
          expect(created.last.disposed, isFalse);
        } else if (mode == 'new-call' || mode == 'hangup') {
          await service.hangup();
          if (mode == 'new-call') {
            await _connect(service, wire, peerPosture: CallPosture.direct);
            expect(service.current?.callId, isNot(first.callId));
          }
        }
        if (!release.isCompleted) release.complete();
        if (mode != 'pending-native' && !identity.isCompleted) {
          if (mode.startsWith('startup-error') ||
              mode == 'normal-lookup-failure') {
            identity.completeError(
              StateError('synthetic retired lookup refusal'),
            );
          } else {
            identity.complete();
          }
        }
        final result = await repairing;
        await pumpEventQueue();
        if (mode == 'pending-native') {
          expect(service.current?.status, CallStatus.active);
          expect(
            controller.activeTransport,
            isNull,
            reason: 'the newer start still owns a held identity lookup',
          );
          identity.complete();
          expect(await latest, isTrue);
          await pumpEventQueue();
        }
        final live =
            mode != 'hangup' &&
            mode != 'normal-failure' &&
            mode != 'normal-lookup-failure';
        expect(
          {
            'repair_result': result,
            'call_live': service.current?.status == CallStatus.active,
            'engine_count': created.length,
            'old_disposals': created.first.disposals,
            'current_disposals': created.length > 1
                ? created.last.disposals
                : null,
            'closed_channels': transport.closed,
            'active_transport': controller.activeTransport,
            'repairing': controller.diagnostics['media_repairing'],
            'all_opens_relay': transport.relayOpens.every((value) => value),
            'no_direct_opens': !transport.directOpens.any((value) => value),
          },
          {
            'repair_result': mode != 'new-call' && live,
            'call_live': live,
            'engine_count': live ? 2 : 1,
            'old_disposals': 1,
            'current_disposals': live ? 0 : null,
            'closed_channels': mode == 'normal-failure' ? [42, 43] : [42],
            'active_transport': live ? CallTransportKind.relay : null,
            'repairing': false,
            'all_opens_relay': true,
            'no_direct_opens': true,
          },
        );
        if (mode.endsWith('plugin')) {
          expect(plugins, hasLength(1));
          expect(plugins.single.stops, 0);
        }
      } finally {
        if (!release.isCompleted) release.complete();
        if (!identity.isCompleted) identity.complete();
        await repairing;
        await latest;
        service.dispose();
        await controller.stop();
      }
    });
  }

  for (final operation in ['select', 'off']) {
    for (final successor in ['none', 'native', 'plugin']) {
      test(
        'detached camera $operation fences its engine successor=$successor',
        () async {
          final wire = _Wire(), transport = _Transport();
          final firstEngine = _Engine(), nextEngine = _Engine();
          final engines = Queue<_Engine>.of([firstEngine, nextEngine]);
          final old = _NativeCamera(true),
              next = _NativeCamera(successor == 'native');
          final cameras = Queue<_NativeCamera>.of([old, next]);
          final fallback = _PluginCamera(Future.value(true));
          final controller = VeilCallMediaController(
            transport,
            engineFactory:
                ({required veilChan, required localId, required peerId}) =>
                    engines.removeFirst(),
            androidCameraCapture: true,
            nativeCameraFactory: cameras.removeFirst,
            cameraCaptureFactory: (_, _) => fallback,
          );
          final service = CallService(wire, media: controller)..start();
          final release = Completer<void>();
          Future<Object?>? changing;
          Future<void>? ending;
          Future<void>? endingNext;
          try {
            await _connect(service, wire);
            await old.entered.future;
            await pumpEventQueue();
            final first = service.current!;
            old.stopGate = release;
            old.stopEntered = Completer<void>();
            changing = operation == 'select'
                ? service.selectCamera('back-fixture')
                : service.setCameraEnabled(false);
            await old.stopEntered!.future;
            var completed = false;
            ending = controller.stop().then((_) {
              completed = true;
            });
            await pumpEventQueue();
            final oldDisposedWhileHeld = firstEngine.disposed;
            final oldCompletedWhileHeld = completed;
            if (successor != 'none') {
              final nextCall = Call(
                callId: 'detached-camera-successor',
                peer: first.peer,
                direction: first.direction,
                media: first.media,
                status: first.status,
                localPosture: first.localPosture,
                peerPosture: first.peerPosture,
                transport: first.transport,
                startedAt: first.startedAt,
                localMediaKey: first.localMediaKey,
                peerMediaKey: first.peerMediaKey,
              );
              expect(await controller.start(nextCall), isTrue);
              await pumpEventQueue();
              var nextCompleted = false;
              endingNext = controller.stop().then((_) {
                nextCompleted = true;
              });
              await pumpEventQueue();
              expect(
                nextEngine.disposed,
                isTrue,
                reason: 'only the first engine owns the held fence',
              );
              expect(
                nextCompleted,
                isTrue,
                reason: 'another engine must not wait for unrelated retirement',
              );
            }
            expect(
              {
                'disposed_while_native_stop_held': oldDisposedWhileHeld,
                'stop_completed_while_native_stop_held': oldCompletedWhileHeld,
                'audio_stopped': firstEngine.audioStops > 0,
              },
              {
                'disposed_while_native_stop_held': false,
                'stop_completed_while_native_stop_held': false,
                'audio_stopped': true,
              },
            );
            release.complete();
            await changing;
            await ending;
            await endingNext;
            expect(firstEngine.disposals, 1);
            expect(firstEngine.disposed, isTrue);
            expect(nextEngine.disposals, successor == 'none' ? 0 : 1);
          } finally {
            if (!release.isCompleted) release.complete();
            await changing;
            await ending;
            await endingNext;
            service.dispose();
            await controller.stop();
          }
        },
      );
    }

    test(
      'reentrant $operation stop registers its fence before callback',
      () async {
        final wire = _Wire(), engine = _Engine(), old = _NativeCamera(true);
        final controller = VeilCallMediaController(
          _Transport(),
          engineFactory:
              ({required veilChan, required localId, required peerId}) =>
                  engine,
          androidCameraCapture: true,
          nativeCameraFactory: () => old,
        );
        final service = CallService(wire, media: controller)..start();
        final release = Completer<void>();
        Future<Object?>? changing;
        Future<void>? ending;
        try {
          await _connect(service, wire);
          await old.entered.future;
          await pumpEventQueue();
          old.stopGate = release;
          old.stopEntered = Completer<void>();
          old.onStop = () {
            ending = controller.stop();
          };
          changing = operation == 'select'
              ? service.selectCamera('back-fixture')
              : service.setCameraEnabled(false);
          await old.stopEntered!.future;
          expect(ending, isNotNull);
          await pumpEventQueue();
          expect(
            engine.disposed,
            isFalse,
            reason: 'reentrant teardown must see the just-entered retirement',
          );
          release.complete();
          await changing;
          await ending;
          expect(engine.disposals, 1);
        } finally {
          if (!release.isCompleted) release.complete();
          await changing;
          await ending;
          service.dispose();
          await controller.stop();
        }
      },
    );
  }

  test(
    'synchronous native stop failure is observed and releases retirement',
    () async {
      final wire = _Wire(), engine = _Engine(), old = _NativeCamera(true);
      final controller = VeilCallMediaController(
        _Transport(),
        engineFactory:
            ({required veilChan, required localId, required peerId}) => engine,
        androidCameraCapture: true,
        nativeCameraFactory: () => old,
      );
      final service = CallService(wire, media: controller)..start();
      Future<void>? ending;
      try {
        await _connect(service, wire);
        await old.entered.future;
        await pumpEventQueue();
        old.onStop = () {
          ending = controller.stop();
          throw StateError('synthetic synchronous stop refusal');
        };
        await expectLater(
          service.selectCamera('back-fixture'),
          throwsStateError,
        );
        await ending;
        expect(engine.disposals, 1);
        await controller.stop();
        expect(engine.disposals, 1);
      } finally {
        await ending;
        service.dispose();
        await controller.stop();
      }
    },
  );

  for (final successor in ['none', 'native', 'plugin']) {
    for (final sameCall in [true, if (successor != 'none') false]) {
      test(
        'session stop keeps owned resources successor=$successor same-call=$sameCall',
        () async {
          const network = MethodChannel('xveil/call_network');
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(
            network,
            (call) async => (call.arguments as Map)['active'],
          );
          final wire = _Wire(), transport = _Transport();
          final oldEngine = _Engine(), newEngine = _Engine();
          final engines = Queue<_Engine>.of([oldEngine, newEngine]);
          final old = _NativeCamera(true),
              next = _NativeCamera(successor == 'native');
          final cameras = Queue<_NativeCamera>.of([old, next]);
          final fallback = _PluginCamera(Future.value(true));
          final controller = VeilCallMediaController(
            transport,
            engineFactory:
                ({required veilChan, required localId, required peerId}) =>
                    engines.removeFirst(),
            androidCameraCapture: true,
            nativeCameraFactory: cameras.removeFirst,
            cameraCaptureFactory: (_, _) => fallback,
          );
          final service = CallService(wire, media: controller)..start();
          final release = Completer<void>();
          Future<void>? ending;
          try {
            await _connect(service, wire);
            await old.entered.future;
            await pumpEventQueue();
            expect(
              controller.diagnostics['call_network_activity_active'],
              isTrue,
            );
            final first = service.current!;
            old.stopGate = release;
            old.stopEntered = Completer<void>();
            ending = controller.stop();
            await old.stopEntered!.future;
            final stoppedAudioBeforeReply = oldEngine.audioStops > 0;
            if (successor != 'none') {
              final nextCall = sameCall
                  ? first
                  : Call(
                      callId: 'replacement-session',
                      peer: first.peer,
                      direction: first.direction,
                      media: first.media,
                      status: first.status,
                      localPosture: first.localPosture,
                      peerPosture: first.peerPosture,
                      transport: first.transport,
                      startedAt: first.startedAt,
                      localMediaKey: first.localMediaKey,
                      peerMediaKey: first.peerMediaKey,
                    );
              expect(await controller.start(nextCall), isTrue);
              await pumpEventQueue();
              expect(newEngine.disposed, isFalse);
            }
            final oldDisposedBeforeReply = oldEngine.disposed;
            release.complete();
            await ending;
            await pumpEventQueue();
            final active = successor != 'none';
            expect(
              {
                'old_audio_stopped_before_fence': stoppedAudioBeforeReply,
                'old_disposed_before_fence': oldDisposedBeforeReply,
                'old_disposals': oldEngine.disposals,
                'new_disposals': newEngine.disposals,
                'new_native_stops': next.stops,
                'new_plugin_stops': fallback.stops,
                'closed_channels': transport.closed,
                'running': controller.diagnostics['running'],
                'network_held':
                    controller.diagnostics['call_network_activity_active'],
              },
              {
                'old_audio_stopped_before_fence': true,
                'old_disposed_before_fence': false,
                'old_disposals': 1,
                'new_disposals': 0,
                'new_native_stops': 0,
                'new_plugin_stops': 0,
                'closed_channels': [42],
                'running': active,
                'network_held': active,
              },
            );
            if (successor == 'native') expect(next.running, isTrue);
            if (successor == 'plugin') {
              expect(fallback.entered.isCompleted, isTrue);
            }
          } finally {
            if (!release.isCompleted) release.complete();
            await ending;
            service.dispose();
            await controller.stop();
            messenger.setMockMethodCallHandler(network, null);
          }
        },
      );
    }
  }

  for (final replacement in ['same-call', 'new-call', 'stop']) {
    test('pending session rebuild respects $replacement intent', () async {
      final wire = _Wire(), transport = _Transport();
      final oldEngine = _Engine(),
          nextEngine = _Engine(),
          unexpected = _Engine();
      final engines = Queue<_Engine>.of([oldEngine, nextEngine, unexpected]);
      final old = _NativeCamera(true);
      final cameras = Queue<_NativeCamera>.of([
        old,
        _NativeCamera(true),
        _NativeCamera(true),
      ]);
      final controller = VeilCallMediaController(
        transport,
        engineFactory:
            ({required veilChan, required localId, required peerId}) =>
                engines.removeFirst(),
        androidCameraCapture: true,
        nativeCameraFactory: cameras.removeFirst,
      );
      final service = CallService(wire, media: controller)..start();
      final release = Completer<void>();
      Future<bool>? rebuilding;
      try {
        await _connect(service, wire);
        await old.entered.future;
        await pumpEventQueue();
        final call = service.current!;
        old.stopGate = release;
        old.stopEntered = Completer<void>();
        rebuilding = controller.start(call);
        await old.stopEntered!.future;
        if (replacement == 'stop') {
          await controller.stop();
        } else {
          final next = replacement == 'same-call'
              ? call
              : Call(
                  callId: 'replacement-rebuild',
                  peer: call.peer,
                  direction: call.direction,
                  media: call.media,
                  status: call.status,
                  localPosture: call.localPosture,
                  peerPosture: call.peerPosture,
                  transport: call.transport,
                  startedAt: call.startedAt,
                  localMediaKey: call.localMediaKey,
                  peerMediaKey: call.peerMediaKey,
                );
          expect(await controller.start(next), isTrue);
          await pumpEventQueue();
        }
        final prematureDisposal = oldEngine.disposed;
        release.complete();
        final resumed = await rebuilding;
        await pumpEventQueue();
        expect(
          {
            'retired_start_result': resumed,
            'old_freed_before_native_fence': prematureDisposal,
            'old_disposals': oldEngine.disposals,
            'next_disposals': nextEngine.disposals,
            'unused_engines': engines.length,
            'closed_channels': transport.closed,
            'running': controller.diagnostics['running'],
          },
          {
            'retired_start_result': false,
            'old_freed_before_native_fence': false,
            'old_disposals': 1,
            'next_disposals': 0,
            'unused_engines': replacement == 'stop' ? 2 : 1,
            'closed_channels': [42],
            'running': replacement != 'stop',
          },
        );
      } finally {
        if (!release.isCompleted) release.complete();
        await rebuilding;
        service.dispose();
        await controller.stop();
      }
    });
  }

  for (final operation in ['select', 'off']) {
    for (final replacement in ['none', 'native', 'plugin']) {
      test('camera $operation drain preserves $replacement successor', () async {
        final wire = _Wire(), engine = _Engine();
        final old = _NativeCamera(true);
        final next = _NativeCamera(replacement != 'plugin');
        final fallback = _PluginCamera(Future.value(true), id: 'back-fixture');
        final cameras = Queue<_NativeCamera>.of([
          old,
          next,
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
        final release = Completer<void>();
        Future<Object?>? pending;
        try {
          await _connect(service, wire);
          await old.entered.future;
          await pumpEventQueue();
          expect(old.running, isTrue);
          old.stopGate = release;
          old.stopEntered = Completer<void>();
          pending = operation == 'select'
              ? service.selectCamera('back-fixture')
              : service.setCameraEnabled(false);
          await old.stopEntered!.future;
          if (replacement != 'none') {
            if (operation == 'select') await service.setCameraEnabled(false);
            await service.setCameraEnabled(true);
            await pumpEventQueue();
            expect(service.current?.cameraOn, isTrue);
            if (replacement == 'plugin') {
              expect(fallback.entered.isCompleted, isTrue);
              expect(fallback.stops, 0);
            } else {
              expect(next.running, isTrue);
            }
          }
          release.complete();
          final result = await pending;
          await pumpEventQueue();
          expect(service.current?.status, CallStatus.active);
          if (replacement == 'none') {
            if (operation == 'select') {
              expect(result, isTrue);
              expect(next.cameraId, 'back-fixture');
            } else {
              expect(service.current?.cameraOn, isFalse);
              expect(next.entered.isCompleted, isFalse);
            }
          } else {
            expect(
              fallback.stops,
              0,
              reason:
                  'the old native stop cannot detach or stop a new plugin source',
            );
            expect(next.stops, 0);
            expect(service.current?.cameraOn, isTrue);
            if (operation == 'select') {
              expect(
                result,
                isFalse,
                reason:
                    'the old selection was superseded by the newer camera intent',
              );
            }
          }
        } finally {
          if (!release.isCompleted) release.complete();
          await pending;
          service.dispose();
          await controller.stop();
        }
      });
    }
  }

  for (final nativeReplacement in [true, false]) {
    test(
      'camera retirement is joined before rebuild native=$nativeReplacement',
      () async {
        final wire = _Wire();
        final old = _NativeCamera(true);
        final replacement = _NativeCamera(nativeReplacement);
        final fallback = _PluginCamera(Future.value(true), id: 'back-fixture');
        final cameras = Queue<_NativeCamera>.of([
          old,
          replacement,
          _NativeCamera(true),
        ]);
        final oldEngine = _Engine(), newEngine = _Engine();
        final engines = Queue<_Engine>.of([oldEngine, newEngine]);
        final controller = VeilCallMediaController(
          _Transport(),
          engineFactory:
              ({required veilChan, required localId, required peerId}) =>
                  engines.removeFirst(),
          androidCameraCapture: true,
          nativeCameraFactory: cameras.removeFirst,
          cameraCaptureFactory: (_, _) => fallback,
        );
        final service = CallService(wire, media: controller)..start();
        final release = Completer<void>();
        Future<bool>? selecting;
        Future<bool>? rebuilding;
        try {
          await _connect(service, wire);
          await old.entered.future;
          await pumpEventQueue();
          old.stopGate = release;
          old.stopEntered = Completer<void>();
          selecting = service.selectCamera('back-fixture');
          await old.stopEntered!.future;
          rebuilding = controller.start(service.current!);
          await pumpEventQueue();
          expect(
            oldEngine.disposed,
            isFalse,
            reason: 'the old engine still owns the pending native stop',
          );
          expect(newEngine.videoStarts, 0);
          release.complete();
          expect(await selecting, isFalse);
          expect(await rebuilding, isTrue);
          await pumpEventQueue();
          expect(oldEngine.disposed, isTrue);
          expect(newEngine.disposed, isFalse);
          expect(fallback.stops, 0);
          if (nativeReplacement) {
            expect(replacement.running, isTrue);
          } else {
            expect(fallback.entered.isCompleted, isTrue);
          }
          expect(
            fallback.stops,
            0,
            reason: 'a choice from the old engine cannot stop the new source',
          );
          expect(replacement.stops, 0);
          expect(service.current?.cameraOn, isTrue);
        } finally {
          if (!release.isCompleted) release.complete();
          await selecting;
          await rebuilding;
          service.dispose();
          await controller.stop();
        }
      },
    );
  }

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
