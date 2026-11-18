// Activity-free Android control-path qualification; all media/device ports
// are synthetic. Run with the adjacent instrumentation builder, not flutter test.
import 'dart:async';
import 'dart:collection';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_media/veil_media.dart';
import 'package:veil_flutter/veil_ffi.dart' show MediaPacketSource;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/android_camera_capture.dart';
import 'package:xveil/state/android_native_call_camera.dart';

import 'package:xveil/state/veil_call_media.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/call_slot.dart';
import 'package:xveil/state/messaging.dart';

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
    bool primaryOnlyPreparation = false,
  }) async {
    final channel = 42 + opened.length;
    opened.add(channel);
    return channel;
  }

  @override
  bool get supportsCallControl => false;
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
  bool setMaxRtpPacketSize(int bytes) => true;
  @override
  bool setAudioPacketOverhead(int bytes) => true;
  @override
  bool setVideoPacketOverhead(int bytes) => true;
  @override
  bool get supportsChannelRebind => false;
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

class _NativeCamera extends AndroidNativeCallCamera {
  _NativeCamera(bool result) : result = Future.value(result);
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

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Call call(String id) => Call(
  callId: id,
  peer: _id(2),
  direction: CallDirection.outgoing,
  media: const CallMedia(audio: true, video: true),
  status: CallStatus.active,
  localPosture: CallPosture.direct,
  peerPosture: CallPosture.direct,
  transport: CallTransportKind.p2p,
  startedAt: DateTime(2026, 11, 17),
  localMediaKey: generateCallMediaKeyContribution(),
  peerMediaKey: generateCallMediaKeyContribution(),
);
Future<void> scenario(
  bool sameCall, {
  bool pluginSuccessor = false,
  bool successor = true,
}) async {
  final transport = _Transport();
  final firstEngine = _Engine(), nextEngine = _Engine();
  final engines = Queue<_Engine>.of([firstEngine, nextEngine]);
  final old = _NativeCamera(true), next = _NativeCamera(!pluginSuccessor);
  final nextPlugin = _PluginCamera(Future.value(true));
  final cameras = Queue<_NativeCamera>.of([old, next]);
  final controller = VeilCallMediaController(
    transport,
    engineFactory: ({required veilChan, required localId, required peerId}) =>
        engines.removeFirst(),
    nativeCameraFactory: cameras.removeFirst,
    cameraCaptureFactory: (_, _) => nextPlugin,
  );
  final release = Completer<void>();
  Future<bool>? sharing;
  Future<void>? ending;
  try {
    check(await controller.start(call('old')), 'initial_start');
    await old.entered.future;
    await pumpEventQueue();
    check(old.running, 'initial_camera');
    old.stopGate = release;
    old.stopEntered = Completer<void>();
    sharing = controller.setScreenShareEnabled(true);
    await old.stopEntered!.future;
    ending = controller.stop();
    await pumpEventQueue();
    check(!firstEngine.disposed, 'native_fence_must_remain');
    if (successor) {
      check(
        await controller.start(call(sameCall ? 'old' : 'new')),
        'successor_start',
      );
    }
    await pumpEventQueue();
    final nextStartedBeforeRelease = next.entered.isCompleted;
    release.complete();
    check(await sharing == false, 'old_share_cancelled');
    await ending;
    await pumpEventQueue();
    if (successor) {
      check(
        nextStartedBeforeRelease,
        'successor_camera_suppressed_by_retired_screen_start',
      );
      check(
        pluginSuccessor
            ? nextPlugin.entered.isCompleted && nextPlugin.stops == 0
            : next.running,
        'successor_camera_survives_old_completion',
      );
    } else {
      check(!next.entered.isCompleted, 'ended_call_must_not_reopen_camera');
    }
    check(firstEngine.disposals == 1, 'retired_engine_disposed_once');
  } finally {
    if (!release.isCompleted) release.complete();
    await sharing;
    await ending;
    await controller.stop();
  }
}

class _HeldPlugin extends _PluginCamera {
  _HeldPlugin() : super(Future.value(true));
  final stopEntered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> stop() async {
    if (!stopEntered.isCompleted) stopEntered.complete();
    await release.future;
    await super.stop();
  }
}

Future<void> publicCallScenario({required bool pluginSuccessor}) async {
  final wire = _Wire(), slot = CallSlot(), transport = _Transport();
  final oldEngine = _RelayEngine(), nextEngine = _RelayEngine();
  final engines = Queue<_Engine>.of([oldEngine, nextEngine]);
  final oldNative = _NativeCamera(false),
      next = _NativeCamera(!pluginSuccessor);
  final natives = Queue<_NativeCamera>.of([oldNative, next]);
  final oldPlugin = _HeldPlugin(),
      newPlugin = _PluginCamera(Future.value(true));
  final plugins = Queue<_PluginCamera>.of([oldPlugin, newPlugin]);
  final controller = VeilCallMediaController(
    transport,
    engineFactory: ({required veilChan, required localId, required peerId}) =>
        engines.removeFirst(),
    nativeCameraFactory: natives.removeFirst,
    cameraCaptureFactory: (_, _) => plugins.removeFirst(),
  );
  final service = CallService(wire, media: controller, callSlot: slot)..start();
  Future<bool>? sharing;
  try {
    await _connect(service, wire, peerPosture: CallPosture.direct);
    await oldPlugin.entered.future;
    await pumpEventQueue();
    sharing = controller.setScreenShareEnabled(true);
    await oldPlugin.stopEntered.future;
    await service.hangup();
    await pumpEventQueue();
    final slotRetained = slot.owner == CallSlotOwner.direct;
    final engineRetained = !oldEngine.disposed;
    await service.placeCall(_id(2), const CallMedia(audio: true, video: true));
    await pumpEventQueue();
    final admittedBeforeRetirement = service.current != null;
    // On the old code the slot has already released. Answer that admitted
    // call to retain the original camera-suppression reproduction as well.
    if (admittedBeforeRetirement) {
      await _connect(service, wire, peerPosture: CallPosture.direct);
      await pumpEventQueue();
    }
    oldPlugin.release.complete();
    check(await sharing == false, 'old_service_share_cancelled');
    await pumpEventQueue();
    if (service.current == null) {
      await _connect(service, wire, peerPosture: CallPosture.direct);
      await pumpEventQueue();
    }
    check(
      slotRetained && engineRetained && !admittedBeforeRetirement,
      'retiring_plugin_must_retain_call_slot_and_engine',
    );
    check(
      service.current?.status == CallStatus.active && next.entered.isCompleted,
      'successor_camera_starts_after_retirement',
    );
    check(
      pluginSuccessor
          ? newPlugin.entered.isCompleted && newPlugin.stops == 0
          : next.running,
      'old_share_must_not_stop_successor_plugin',
    );
  } finally {
    if (!oldPlugin.release.isCompleted) oldPlugin.release.complete();
    await sharing;
    await service.hangup();
    await pumpEventQueue();
    service.dispose();
    await controller.stop();
  }
}

Future<void> ordinaryCamera() async {
  final wire = _Wire(), camera = _NativeCamera(true);
  final controller = VeilCallMediaController(
    _Transport(),
    engineFactory: ({required veilChan, required localId, required peerId}) =>
        _RelayEngine(),
    nativeCameraFactory: () => camera,
  );
  final slot = CallSlot();
  final service = CallService(wire, media: controller, callSlot: slot)..start();
  try {
    await _connect(service, wire, peerPosture: CallPosture.direct);
    await pumpEventQueue();
    check(
      camera.running && service.current?.cameraOn == true,
      'ordinary_camera',
    );
    await service.hangup();
    await pumpEventQueue();
    check(!camera.running && slot.owner == null, 'ordinary_teardown');
  } finally {
    service.dispose();
    await controller.stop();
  }
}

Future<void> pendingProjection() async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const screenChannel = MethodChannel('xveil/screen_capture');
  final firstEntered = Completer<void>(), secondEntered = Completer<void>();
  final firstReply = Completer<bool>(), secondReply = Completer<bool>();
  var screenStarts = 0;
  messenger.setMockMethodCallHandler(screenChannel, (c) async {
    if (c.method == 'start') {
      screenStarts++;
      if (screenStarts == 1) {
        firstEntered.complete();
        return firstReply.future;
      }
      secondEntered.complete();
      return secondReply.future;
    }
    return null;
  });
  final engines = Queue<_Engine>.of([_Engine(), _Engine()]);
  final old = _NativeCamera(true), next = _NativeCamera(true);
  final natives = Queue<_NativeCamera>.of([old, next]);
  final controller = VeilCallMediaController(
    _Transport(),
    engineFactory: ({required veilChan, required localId, required peerId}) =>
        engines.removeFirst(),
    // A failed projection may legitimately restore the camera. Keep that
    // dependency available so a mutant fails the projection assertion,
    // rather than exhausting a fixture queue during recovery.
    nativeCameraFactory: () =>
        natives.isEmpty ? _NativeCamera(true) : natives.removeFirst(),
  );
  Future<bool>? oldShare, newShare;
  Future<void>? ending;
  try {
    check(
      await controller.start(call('old-projection')),
      'projection_initial_start',
    );
    await old.entered.future;
    await pumpEventQueue();
    oldShare = controller.setScreenShareEnabled(true);
    await firstEntered.future;
    ending = controller.stop();
    await pumpEventQueue();
    check(
      await controller.start(call('new-projection')),
      'projection_successor_start',
    );
    await pumpEventQueue();
    newShare = controller.setScreenShareEnabled(true);
    firstReply.complete(true);
    await pumpEventQueue();
    final successorRequestedConsent = secondEntered.isCompleted;
    final successorCameraStopped = natives.isEmpty && !next.running;
    // Release every controlled reply before assertions, including mutants.
    secondReply.complete(true);
    check(await oldShare == false, 'projection_old_start_cancelled');
    await ending;
    final newStarted = await newShare;
    check(
      successorRequestedConsent,
      'new_projection_must_not_join_retired_future',
    );
    check(successorCameraStopped, 'camera_stopped_for_new_projection');
    check(newStarted == true, 'new_projection_survives_old_start_reply');
    await controller.setScreenShareEnabled(false);
  } finally {
    if (!firstReply.isCompleted) firstReply.complete(false);
    if (!secondReply.isCompleted) secondReply.complete(false);
    await oldShare;
    await newShare;
    await ending;
    await controller.stop();
    messenger.setMockMethodCallHandler(screenChannel, null);
  }
}

Future<void> retainedProjection() async {
  const channel = MethodChannel('xveil/screen_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var starts = 0, stops = 0;
  messenger.setMockMethodCallHandler(channel, (call) async {
    if (call.method == 'start') {
      starts++;
      return true;
    }
    if (call.method == 'stop') stops++;
    return null;
  });
  final engines = Queue<_Engine>.of([_Engine(), _Engine()]);
  final camera = _NativeCamera(true);
  var cameraRequests = 0;
  final controller = VeilCallMediaController(
    _Transport(),
    engineFactory: ({required veilChan, required localId, required peerId}) =>
        engines.removeFirst(),
    nativeCameraFactory: () {
      cameraRequests++;
      return camera;
    },
  );
  try {
    check(
      await controller.start(call('retained-projection')),
      'retained_call_start',
    );
    await camera.entered.future;
    await pumpEventQueue();
    check(await controller.setScreenShareEnabled(true), 'retained_share_start');
    check(await controller.repairRoute(), 'retained_route_rebuild');
    await pumpEventQueue();
    check(
      starts == 1 && stops == 0 && cameraRequests == 1 && engines.isEmpty,
      'same_call_rebuild_must_rebind_consent_without_new_capture',
    );
    await controller.stop();
    check(stops == 1, 'hangup_retires_retained_projection');
  } finally {
    await controller.stop();
    messenger.setMockMethodCallHandler(channel, null);
  }
}

Future<void> main() async {
  AutomatedTestWidgetsFlutterBinding();
  SharedPreferences.setMockInitialValues({});
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final name in [
    'media_permissions',
    'call_foreground',
    'call_network',
    'call_audio_route',
  ]) {
    messenger.setMockMethodCallHandler(
      MethodChannel('xveil/$name'),
      (_) async => true,
    );
  }
  messenger.setMockMethodCallHandler(
    const MethodChannel('xveil/native_call_video'),
    (_) async => null,
  );
  final cases = <String, Future<void> Function()>{
    'new_call': () => scenario(false),
    'same_call': () => scenario(true),
    'new_plugin': () => scenario(false, pluginSuccessor: true),
    'public_native': () => publicCallScenario(pluginSuccessor: false),
    'public_plugin': () => publicCallScenario(pluginSuccessor: true),
    'ordinary_camera': ordinaryCamera,
    'end_without_successor': () => scenario(false, successor: false),
    'pending_projection': pendingProjection,
    'retained_projection': retainedProjection,
  };
  final outcomes = <String, Object?>{};
  for (final entry in cases.entries) {
    try {
      await entry.value().timeout(const Duration(seconds: 10));
      outcomes[entry.key] = 'pass';
    } catch (e, st) {
      outcomes[entry.key] = {'error': e.toString(), 'stack': st.toString()};
    }
  }
  await const MethodChannel(
    'xveil/qa_result',
  ).invokeMethod<void>('result', outcomes);
}
