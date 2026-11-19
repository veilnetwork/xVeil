import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:veil_flutter/veil_flutter.dart' show VeilException;
import 'package:veil_media/veil_media.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/veil_call_media.dart';
import 'package:xveil/state/android_native_call_camera.dart';
import 'package:xveil/state/call_microphone_state.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int value) => NodeId(Uint8List.fromList(List.filled(32, value)));

class _Transport implements VeilFlutterTransport {
  final closed = <int>[];
  @override
  Future<NodeId> peerFacingNodeId({
    Duration timeout = const Duration(seconds: 2),
  }) async => _id(1);
  @override
  Future<int> openMediaChannel(
    Uint8List dstNode, {
    required Uint8List txKey,
    required Uint8List rxKey,
    bool direct = false,
    bool relay = false,
    bool primaryOnlyPreparation = false,
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
  void closeMediaChannel(int channel) => closed.add(channel);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OpeningTransport extends _Transport {
  final opened = Completer<void>();
  @override
  Future<int> openMediaChannel(Uint8List peer, {
    required Uint8List txKey, required Uint8List rxKey,
    bool direct = false, bool relay = false,
    bool primaryOnlyPreparation = false,
  }) async {
    opened.complete();
    return 42;
  }
}

class _CameraAdmissionTransport extends _Transport {
  bool refuse = false;
  bool throwOnRefusal = false;

  @override
  int setMediaScreenSharing(int channel, bool enabled) {
    if (!refuse) return 0;
    if (throwOnRefusal) throw StateError('synthetic screen mode refusal');
    return -1;
  }
}

class _Engine implements VeilMediaEngine {
  @override
  bool get supportsNoiseSuppression => true;
  final noiseSuppression = <bool>[];
  bool rejectNoiseSuppression = false;
  @override
  bool setNoiseSuppression(bool enabled) {
    if (rejectNoiseSuppression) return false;
    noiseSuppression.add(enabled);
    return true;
  }

  _Engine({
    this.nativeStarted = false,
    this.capture = 0,
    this.playout = 1,
    this.muteAccepted = true,
  });
  final bool nativeStarted;
  final int capture;
  final int playout;
  bool muteAccepted;
  bool throwOnMute = false;
  final mutes = <bool>[];
  bool disposed = false;
  bool rejectVideoAdmission = false;
  int pauseAttempts = 0;
  int videoStarts = 0;
  @override
  bool get supportsLowRateVideo => false;
  @override
  bool get supportsVideoSendPause => rejectVideoAdmission;
  @override
  bool setVideoSendPaused(bool paused) {
    pauseAttempts++;
    return false;
  }

  @override
  bool startVideo({
    bool send = true,
    bool recv = true,
    int maxBitrateKbps = 150,
    num maxFps = 15,
  }) {
    videoStarts++;
    return false;
  }

  @override
  bool startAudio({bool send = true, bool recv = true}) => nativeStarted;
  @override
  Map<String, dynamic> getStats() => {
    'audio_capture_start_result': capture,
    'audio_playout_start_result': playout,
  };
  @override
  void setMicMuted(bool muted) => mutes.add(muted);
  @override
  bool trySetMicMuted(bool muted) {
    mutes.add(muted);
    if (throwOnMute) throw StateError('device disappeared');
    return muteAccepted;
  }

  @override
  bool setIndependentTransportFeedback(bool enabled) => true;
  @override
  bool stopAudio() => true;
  @override
  bool stopVideo() => true;
  @override
  void dispose() {
    disposed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Call _call({
  bool video = false,
  String callId = 'receive-only-start',
  NodeId? peer,
  bool direct = false,
}) => Call(
  callId: callId,
  peer: peer ?? _id(2),
  direction: CallDirection.incoming,
  media: CallMedia(audio: true, video: video),
  status: CallStatus.connecting,
  localPosture: direct ? CallPosture.direct : CallPosture.anonymous,
  peerPosture: direct ? CallPosture.direct : CallPosture.anonymous,
  transport: direct ? CallTransportKind.p2p : CallTransportKind.onion,
  startedAt: DateTime(2026, 11, 1),
  localMediaKey: generateCallMediaKeyContribution(),
  peerMediaKey: generateCallMediaKeyContribution(),
);

class _LivenessEngine extends _Engine {
  _LivenessEngine(this.packets) : super(nativeStarted: true, capture: 1);
  int packets;

  @override
  Map<String, dynamic> getStats() => {
    ...super.getStats(),
    'rx_pkts': packets,
    'worker_stalled': 0,
  };
}

class _UpgradeEngine extends _Engine {
  _UpgradeEngine() : super(nativeStarted: true, capture: 1);
  final videoStarted = Completer<void>();

  @override
  bool startVideo({
    bool send = true,
    bool recv = true,
    int maxBitrateKbps = 150,
    num maxFps = 15,
  }) {
    videoStarts++;
    if (!videoStarted.isCompleted) videoStarted.complete();
    if (disposed) throw StateError('retired engine');
    return true;
  }
}

class _RepairingTransport extends _Transport {
  int repairs = 0;

  @override
  int repairMediaChannel(int channel) {
    repairs++;
    return 0;
  }
}

class _HandoverTransport extends _RepairingTransport {
  final qualifying = Completer<int>();
  final echo = Completer<bool>();
  final opened = <int>[];
  final directOpenFailures = <String>[];
  int directOpenAttempts = 0;
  int peerAdmissionChecks = 0;
  final probeRequests = <int>[];
  bool failRelayOpen = false;
  bool? proofAvailable;

  @override
  Future<int> openMediaChannel(
    Uint8List peer, {
    required Uint8List txKey,
    required Uint8List rxKey,
    bool direct = false,
    bool relay = false,
    bool primaryOnlyPreparation = false,
  }) async {
    if (direct) {
      directOpenAttempts++;
      if (directOpenFailures.isNotEmpty) {
        throw VeilException(
          'direct media open failed: ${directOpenFailures.removeAt(0)}',
        );
      }
    }
    if (relay && failRelayOpen) throw StateError('relay open unavailable');
    final channel = opened.length + 42;
    opened.add(channel);
    return channel;
  }

  @override
  Future<({bool admitted, bool hasCert})> peerPnetStatus(Uint8List peer) async {
    peerAdmissionChecks++;
    return (admitted: true, hasCert: true);
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
  Future<bool> qualifyMediaRoute(int channel) {
    probeRequests.add(channel);
    final proven = proofAvailable;
    if (proven != null) return Future.value(proven);
    qualifying.complete(channel);
    return echo.future;
  }
}

class _HandoverEngine extends _Engine {
  _HandoverEngine() : super(nativeStarted: true, capture: 1);

  int received = 0;
  bool stalled = false;
  final rebound = <int>[];

  @override
  Map<String, dynamic> getStats() => {
    ...super.getStats(),
    'rx_pkts': received,
    'audio_rx_pkts': received,
    'audio_rx_native_age_ms': 40,
    'worker_stalled': stalled ? 1 : 0,
  };

  @override
  bool get supportsChannelRebind => true;

  @override
  bool get supportsReceiveChannelOverlap => false;

  @override
  bool rebindChannel(int channel, {bool retainPreviousReceiver = false}) {
    rebound.add(channel);
    return true;
  }

  @override
  bool setMaxRtpPacketSize(int bytes) => true;
}

class _CameraChoiceEngine extends _UpgradeEngine {
  final cameraStarts = <String?>[];
  String? activeCamera;
  String? rejected;
  bool throwOnRejected = false;
  bool stopAccepted = true;
  bool rejectAll = false;
  bool rejectVideo = false;
  @override
  bool startVideo({
    bool send = true,
    bool recv = true,
    int maxBitrateKbps = 150,
    num maxFps = 15,
  }) {
    final started = super.startVideo(
      send: send,
      recv: recv,
      maxBitrateKbps: maxBitrateKbps,
      maxFps: maxFps,
    );
    return started && !rejectVideo;
  }

  @override
  List<MediaDevice> listVideoInputs() => const [
    MediaDevice(id: 'old-camera', label: 'Previous camera', kind: 'camera'),
    MediaDevice(id: 'new-camera', label: 'New camera', kind: 'camera'),
  ];
  @override
  bool startCamera({
    int width = 352,
    int height = 198,
    int fps = 15,
    String? deviceId,
  }) {
    cameraStarts.add(deviceId);
    if (rejectAll || deviceId == rejected) {
      if (throwOnRejected) throw StateError('fixture camera unavailable');
      return false;
    }
    activeCamera = deviceId;
    return true;
  }

  @override
  bool stopCamera() {
    if (!stopAccepted) return false;
    activeCamera = null;
    return true;
  }

  @override
  void dispose() {
    activeCamera = null;
    super.dispose();
  }
}

class _CaptureStateEngine extends _CameraChoiceEngine {
  Object? captureState = 1;
  Map<String, dynamic> captureEvidence = {};

  @override
  Map<String, dynamic> getStats() => {
    ...super.getStats(),
    if (captureState != null) 'camera_capturing': captureState,
    ...captureEvidence,
  };

  @override
  bool startCamera({
    int width = 352,
    int height = 198,
    int fps = 15,
    String? deviceId,
  }) {
    final ok = super.startCamera(
      width: width,
      height: height,
      fps: fps,
      deviceId: deviceId,
    );
    if (ok) captureState = 1;
    return ok;
  }
}

class _ScreenChoiceEngine extends _CameraChoiceEngine {
  final screenStarts = <String?>[];
  final retiredScreenCalls = <String>[];
  final refusedScreens = <String>{};
  final throwingScreens = <String>{};
  bool screenStopAccepted = true, throwScreenStop = false;
  int screenStops = 0;
  String? activeScreen;

  @override
  bool startScreen({int width = 640, int fps = 15, String? sourceId}) {
    screenStarts.add(sourceId);
    if (disposed) {
      retiredScreenCalls.add('start');
      throw StateError('retired fixture engine');
    }
    if (throwingScreens.contains(sourceId)) {
      throw StateError('source unavailable');
    }
    if (refusedScreens.contains(sourceId)) return false;
    activeScreen = sourceId;
    return true;
  }

  @override
  bool stopScreen() {
    screenStops++;
    if (disposed) {
      retiredScreenCalls.add('stop');
      throw StateError('retired fixture engine');
    }
    if (throwScreenStop) throw StateError('source cleanup refused');
    if (!screenStopAccepted) return false;
    activeScreen = null;
    return true;
  }

  @override
  void dispose() {
    activeScreen = null;
    super.dispose();
  }
}

class _ScreenChoiceController extends VeilCallMediaController {
  _ScreenChoiceController(super.transport, {super.engineFactory});
  Completer<List<CallMediaDevice>>? nextList;
  final listEntered = Completer<void>();
  static const screens = [
    CallMediaDevice(
      id: 'display-1',
      label: 'First display',
      kind: CallMediaDeviceKind.screen,
    ),
    CallMediaDevice(
      id: 'window-2',
      label: 'A window',
      kind: CallMediaDeviceKind.window,
    ),
    CallMediaDevice(
      id: 'display-3',
      label: 'Another display',
      kind: CallMediaDeviceKind.screen,
    ),
  ];

  @override
  Future<List<CallMediaDevice>> listScreens() {
    final held = nextList;
    nextList = null;
    if (held == null) return Future.value(screens);
    listEntered.complete();
    return held.future;
  }
}

class _PreviewReadEngine extends _CaptureStateEngine {
  _PreviewReadEngine({required this.remoteFails, required this.localFails});
  bool remoteFails;
  bool localFails;
  int localReads = 0;
  int remoteReads = 0;
  final localFrame = VeilVideoFrame(rgba: Uint8List(16), width: 2, height: 2);
  final remoteFrame = VeilVideoFrame(rgba: Uint8List(16), width: 2, height: 2);

  @override
  VeilVideoFrame? getVideoFrame() {
    remoteReads++;
    if (remoteFails) throw StateError('synthetic remote frame refusal');
    return remoteFrame;
  }

  @override
  VeilVideoFrame? getLocalVideoFrame() {
    localReads++;
    if (localFails) throw StateError('synthetic local frame refusal');
    return localFrame;
  }
}

class _CameraCallWire implements MessagingService {
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

Future<void> _connectCameraCall(
  CallService service,
  _CameraCallWire wire, {
  bool video = true,
}) async {
  await service.placeCall(_id(2), CallMedia(audio: true, video: video));
  // Observe actual media admission, rather than assuming a fixed number of
  // event-loop turns also completes asynchronous preference/key setup.
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
    await active.future.timeout(const Duration(seconds: 5));
  } finally {
    await subscription.cancel();
  }
  expect(service.current?.status, CallStatus.active);
}

class _RestoreStageEngine extends _Engine {
  _RestoreStageEngine(this.stage, this.label)
    : super(nativeStarted: true, capture: 1);
  final String stage, label;
  final entered = Completer<void>();
  final retiredCalls = <String>[];
  final selectedInputs = <String>[], selectedOutputs = <String>[];
  int audioStarts = 0;

  void touch(String operation) {
    if (disposed) {
      retiredCalls.add(operation);
      throw StateError('closed fixture engine');
    }
    if (operation == stage && !entered.isCompleted) entered.complete();
  }

  @override
  List<MediaDevice> listAudioInputs() {
    touch('input');
    return [
      MediaDevice(id: '$label-input', label: 'saved input', kind: 'input'),
    ];
  }

  @override
  List<MediaDevice> listAudioOutputs() {
    touch('output');
    return [
      MediaDevice(id: '$label-output', label: 'saved output', kind: 'output'),
    ];
  }

  @override
  bool selectAudioInput(String id) {
    touch('select input');
    selectedInputs.add(id);
    return true;
  }

  @override
  bool selectAudioOutput(String id) {
    touch('select output');
    selectedOutputs.add(id);
    return true;
  }

  @override
  void setMicMuted(bool muted) {
    touch('mute');
    super.setMicMuted(muted);
  }

  @override
  bool startAudio({bool send = true, bool recv = true}) {
    touch('start audio');
    audioStarts++;
    return super.startAudio(send: send, recv: recv);
  }
}

class _AudioChoiceCameraEngine extends _RestoreStageEngine {
  _AudioChoiceCameraEngine() : super('none', 'choice');
  @override
  int get nativeAddress => 1;
  @override
  bool startVideo({
    bool send = true,
    bool recv = true,
    int maxBitrateKbps = 150,
    num maxFps = 15,
  }) => true;
}

class _ClosingCamera extends AndroidNativeCallCamera {
  final stopping = Completer<void>(), released = Completer<void>();
  bool running = false;
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
  }) async => running = true;
  @override
  Future<void> stop() async {
    running = false;
    if (!stopping.isCompleted) stopping.complete();
    await released.future;
  }
}

class _OutputChoiceEngine extends _Engine {
  _OutputChoiceEngine({this.hasDefault = true})
    : super(nativeStarted: true, capture: 1);
  final bool hasDefault;
  final selected = <String>[];
  String? rejected;

  @override
  List<MediaDevice> listAudioOutputs() => [
    const MediaDevice(id: '0', label: 'digital output', kind: 'output'),
    const MediaDevice(id: '2', label: 'chosen speaker', kind: 'output'),
    if (hasDefault)
      const MediaDevice(
        id: 'system-default',
        label: 'System default',
        kind: 'output',
      ),
  ];

  @override
  bool selectAudioOutput(String id) {
    selected.add(id);
    return id != rejected;
  }
}

class _InputChoiceEngine extends _Engine {
  _InputChoiceEngine({this.hasDefault = true})
    : super(nativeStarted: true, capture: 1);
  final bool hasDefault;
  final selected = <String>[];
  String? rejected;
  String activeInput = '2'; // An index retained by the native ADM.

  @override
  List<MediaDevice> listAudioInputs() => [
    const MediaDevice(id: '0', label: 'monitor input', kind: 'input'),
    const MediaDevice(id: '2', label: 'chosen microphone', kind: 'input'),
    if (hasDefault)
      const MediaDevice(
        id: 'system-default',
        label: 'System default',
        kind: 'input',
      ),
  ];

  @override
  bool selectAudioInput(String id) {
    selected.add(id);
    if (id == rejected) return false;
    activeInput = id;
    return true;
  }
}

class _PreflightTransport extends _Transport {
  final identityEntered = Completer<void>();
  final identityReady = Completer<void>();
  bool delayIdentity = false;
  int identityReads = 0;
  final openedChannels = <int>[];

  @override
  Future<NodeId> peerFacingNodeId({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (++identityReads == 1 && delayIdentity) {
      identityEntered.complete();
      await identityReady.future;
    }
    return _id(1);
  }

  @override
  Future<int> openMediaChannel(
    Uint8List dstNode, {
    required Uint8List txKey,
    required Uint8List rxKey,
    bool direct = false,
    bool relay = false,
    bool primaryOnlyPreparation = false,
  }) async {
    final channel = 200 + openedChannels.length;
    openedChannels.add(channel);
    return channel;
  }
}

class _PreflightPreferences extends InMemorySharedPreferencesStore {
  _PreflightPreferences({this.failRead = false})
    : super.withData({
        'flutter.call.capture.microphone.${Platform.operatingSystem}':
            'saved input',
      });

  final entered = Completer<void>();
  final ready = Completer<void>();
  final bool failRead;

  @override
  Future<Map<String, Object>> getAll() async {
    // Profile-bound preferences reload the plugin cache after the first read.
    // The gate signals arrival once; subsequent reads use the same open gate.
    if (!entered.isCompleted) entered.complete();
    await ready.future;
    if (failRead) throw StateError('fixture preferences unavailable');
    return super.getAll();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    diagnosticJournal.clear();
  });

  test('failed desktop camera keeps numeric source evidence at startup', () async {
    final engine = _CaptureStateEngine()
      ..rejectAll = true
      ..captureEvidence = {
        'camera_capture_status': 6,
        'camera_capture_hresult': -1,
        'camera_capture_reads': 0,
        'camera_capture_samples': 0,
        'camera_capture_frames': 0,
        'camera_capture_dropped': 0,
        'camera_driver_path': 'PRIVATE_CAMERA_PATH',
      };
    final controller = VeilCallMediaController(
      _Transport(),
      engineFactory: ({required veilChan, required localId, required peerId}) => engine,
    );
    try {
      expect(await controller.start(_call(video: true)), isTrue);
      expect(controller.startedWithoutCamera, isTrue);
      if (kDiagnosticReportEnabled) {
        final report = diagnosticJournal.toJson();
        final evidence = report['last_evidence'] as Map;
        expect((evidence['cameraStart'] as Map)['values'], {
          'success': 0, 'origin': CameraStartOrigin.callStart.index,
          'cameraCaptureStatus': 6, 'cameraCaptureHresult': -1,
          'cameraCaptureReads': 0, 'cameraCaptureSamples': 0,
          'cameraCaptureFrames': 0, 'cameraCaptureDropped': 0,
        });
        expect(jsonEncode(report), isNot(contains('PRIVATE_CAMERA_PATH')));
      } else {
        expect(diagnosticJournal.toJson()['events'], isEmpty);
      }
    } finally {
      await controller.stop();
    }
  }, skip: Platform.isAndroid ? 'Desktop native-camera path' : false);

  for (final remoteFails in [false, true]) {
    test(
      'frame reads stay independent after remote failure=$remoteFails',
      () async {
        final polls = <void Function()>[];
        final statsPolls = <void Function()>[];
        await runZoned(
          () async {
            final engine = _PreviewReadEngine(
              remoteFails: remoteFails,
              localFails: !remoteFails,
            );
            final controller = VeilCallMediaController(
              _Transport(),
              engineFactory:
                  ({required veilChan, required localId, required peerId}) =>
                      engine,
            );
            try {
              expect(await controller.start(_call(video: true)), isTrue);
              expect(polls, hasLength(1));
              for (var i = 0; i < 3; i++) {
                polls.single();
              }
              expect(engine.remoteReads, 3);
              expect(
                engine.localReads,
                3,
                reason: 'a remote read error must not suppress self preview',
              );
              expect(
                remoteVideoFrame.value,
                remoteFails ? isNull : same(engine.remoteFrame),
              );
              expect(
                localVideoFrame.value,
                remoteFails ? same(engine.localFrame) : isNull,
              );
              if (kDiagnosticReportEnabled) {
                expect(statsPolls, hasLength(1));
                statsPolls.single();
                final values = ((diagnosticJournal.toJson()['last_evidence'] as Map)['videoPreview'] as Map)['values'] as Map;
                expect(values['enabled'], 1);
                expect(values['localPreviewFrames'], remoteFails ? 3 : 0);
                expect(values['remotePreviewReadErrors'], remoteFails ? 3 : 0);
                expect(values['localPreviewReadErrors'], remoteFails ? 0 : 3);
                expect(values.containsKey('localPreviewAgeMs'), remoteFails);
              }
              engine.remoteFails = false;
              engine.localFails = false;
              polls.single();
              expect(localVideoFrame.value, same(engine.localFrame));
              expect(remoteVideoFrame.value, same(engine.remoteFrame));
              expect(engine.disposed, isFalse);
            } finally {
              await controller.stop();
            }
          },
          zoneSpecification: ZoneSpecification(
            createPeriodicTimer: (self, parent, zone, interval, callback) {
              final timer = parent.createPeriodicTimer(zone, interval, callback)
                ..cancel();
              if (interval == const Duration(milliseconds: 12)) {
                polls.add(() => zone.runUnary(callback, timer));
              } else if (interval == const Duration(seconds: 1)) {
                statsPolls.add(() => zone.runUnary(callback, timer));
              }
              return timer;
            },
          ),
        );
      },
    );
  }

  for (final state in <Object?>[0, -1, 1, null, 0.0, '0']) {
    test(
      'desktop capture end posture: ${state.runtimeType}/$state',
      () async {
        SharedPreferences.setMockInitialValues({
          'call.capture.camera.${Platform.operatingSystem}': 'old-camera',
        });
        final polls = <void Function()>[];
        await runZoned(
          () async {
            final wire = _CameraCallWire();
            final engine = _CaptureStateEngine();
            final controller = VeilCallMediaController(
              _Transport(),
              engineFactory:
                  ({required veilChan, required localId, required peerId}) =>
                      engine,
            );
            final service = CallService(wire, media: controller)..start();
            var failures = 0;
            final subscription = controller.cameraUnavailable.listen(
              (_) => failures++,
            );
            try {
              await _connectCameraCall(service, wire);
              expect(service.current?.status, CallStatus.active);
              expect(engine.cameraStarts, isNotEmpty);
              expect(service.current?.cameraOn, isTrue);
              final callId = service.current!.callId;
              engine.captureState = state;
              if (state is int && state == 0) {
                engine.captureEvidence = {
                  'camera_capture_status': 7,
                  'camera_capture_hresult': 0xc00d3ea2,
                  'camera_capture_reads': 4,
                  'camera_capture_samples': 3,
                  'camera_capture_frames': 3,
                  'camera_capture_dropped': 0,
                  'camera_driver_path': 'PRIVATE_CAMERA_PATH',
                };
              }
              expect(polls, isNotEmpty);
              for (var tick = 0; tick < 2; tick++) {
                for (final poll in polls.toList()) {
                  poll();
                }
                await pumpEventQueue();
              }
              final ended = state is int && state == 0;
              expect(service.current?.callId, callId);
              expect(service.current?.status, CallStatus.active);
              expect(service.current?.cameraOn, !ended);
              expect(failures, ended ? 1 : 0);
              expect(controller.startedWithoutCamera, ended);
              if (ended) {
                expect(wire.sent.last.capture?.video, isFalse);
                if (kDiagnosticReportEnabled) {
                  final report = diagnosticJournal.toJson();
                  final evidence = report['last_evidence'] as Map;
                  expect((evidence['cameraStopped'] as Map)['values'], {
                    'cameraCapturing': 0,
                    'cameraCaptureStatus': 7,
                    'cameraCaptureHresult': 0xc00d3ea2,
                    'cameraCaptureReads': 4,
                    'cameraCaptureSamples': 3,
                    'cameraCaptureFrames': 3,
                    'cameraCaptureDropped': 0,
                  });
                  final encoded = jsonEncode(report);
                  expect(encoded, isNot(contains('old-camera')));
                  expect(encoded, isNot(contains(callId)));
                  expect(encoded, isNot(contains(_id(2).hex)));
                  expect(encoded, isNot(contains('PRIVATE_CAMERA_PATH')));
                }
                await service.setCameraEnabled(true);
                for (final poll in polls.toList()) {
                  poll();
                }
                await pumpEventQueue();
                expect(service.current?.cameraOn, isTrue);
                expect(controller.startedWithoutCamera, isFalse);
                expect(failures, 1);
                expect(engine.disposed, isFalse);
                await service.setCameraEnabled(false);
                engine.captureState = 0;
                for (final poll in polls.toList()) {
                  poll();
                }
                await pumpEventQueue();
                expect(service.current?.cameraOn, isFalse);
                expect(
                  failures,
                  1,
                  reason: 'intentional OFF is not a new failure',
                );
              }
            } finally {
              service.dispose();
              await subscription.cancel();
              await controller.stop();
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
      skip: Platform.isAndroid ? 'Desktop capture state' : false,
    );
  }

  for (final upgrade in [false, true]) {
    for (final throws in [false, true]) {
      test(
        'camera control admission preserves actual posture '
        'upgrade=$upgrade throws=$throws',
        () async {
          SharedPreferences.setMockInitialValues({
            'call.capture.camera.${Platform.operatingSystem}': 'old-camera',
          });
          final wire = _CameraCallWire();
          final transport = _CameraAdmissionTransport();
          final engine = _CameraChoiceEngine();
          final controller = VeilCallMediaController(
            transport,
            engineFactory:
                ({required veilChan, required localId, required peerId}) =>
                    engine,
          );
          final service = CallService(wire, media: controller)..start();
          try {
            await _connectCameraCall(service, wire, video: !upgrade);
            if (!upgrade) await service.setCameraEnabled(false);
            final starts = engine.cameraStarts.length;
            transport
              ..refuse = true
              ..throwOnRefusal = throws;
            await service.setCameraEnabled(true);
            await pumpEventQueue();
            expect(engine.cameraStarts.length, starts);
            expect(engine.activeCamera, isNull);
            expect(service.current?.status, CallStatus.active);
            expect(service.current?.media.video, isTrue);
            expect(service.current?.cameraOn, isFalse);
            expect(
              wire.sent.where((s) => s.capture != null).last.capture?.video,
              isFalse,
            );
            if (kDiagnosticReportEnabled) {
              final report = diagnosticJournal.toJson();
              final evidence = report['last_evidence'] as Map;
              expect(
                (evidence['cameraStart'] as Map)['values'],
                {
                  'success': 0,
                  'origin': CameraStartOrigin.channelAdmission.index,
                },
              );
              final encoded = jsonEncode(report);
              for (final private in [
                'synthetic screen mode refusal',
                'old-camera',
                service.current!.callId,
                _id(2).hex,
              ]) {
                expect(encoded, isNot(contains(private)));
              }
            }
            transport.refuse = false;
            await service.setCameraEnabled(true);
            await pumpEventQueue();
            expect(service.current?.cameraOn, isTrue);
            expect(engine.activeCamera, 'old-camera');
            expect(engine.cameraStarts.length, starts + 1);
          } finally {
            service.dispose();
            await controller.stop();
          }
        },
        skip: Platform.isAndroid ? 'Desktop camera control' : false,
      );
    }
  }

  for (final phase in ['initial', 'toggle']) {
    for (final throws in [false, true]) {
      test(
        'desktop camera refusal clears actual call posture ($phase/$throws)',
        () async {
          SharedPreferences.setMockInitialValues({
            'call.capture.camera.${Platform.operatingSystem}': 'old-camera',
          });
          final wire = _CameraCallWire();
          final engine = _CameraChoiceEngine()
            ..rejectAll = phase == 'initial'
            ..throwOnRejected = throws;
          final controller = VeilCallMediaController(
            _Transport(),
            engineFactory:
                ({required veilChan, required localId, required peerId}) =>
                    engine,
          );
          final service = CallService(wire, media: controller)..start();
          try {
            await _connectCameraCall(service, wire);
            if (phase == 'toggle') {
              await service.setCameraEnabled(false);
              engine.rejectAll = true;
              await service.setCameraEnabled(true);
              await pumpEventQueue();
            }
            expect(engine.activeCamera, isNull);
            expect(
              service.current?.status,
              CallStatus.active,
              reason: 'camera failure must preserve audio/receive',
            );
            expect(service.current?.cameraOn, isFalse);
            expect(wire.sent.last.capture?.video, isFalse);
            if (kDiagnosticReportEnabled) {
              final report = diagnosticJournal.toJson();
              final evidence = report['last_evidence'] as Map;
              expect((evidence['cameraStart'] as Map)['values'], {
                'success': 0,
                'origin':
                    (phase == 'initial'
                            ? CameraStartOrigin.callStart
                            : CameraStartOrigin.toggle)
                        .index,
              });
              final encoded = jsonEncode(report);
              for (final private in [
                'old-camera',
                'fixture camera unavailable',
                service.current!.callId,
                _id(2).hex,
              ]) {
                expect(encoded, isNot(contains(private)));
              }
            }
          } finally {
            service.dispose();
            await controller.stop();
          }
        },
        skip: Platform.isAndroid ? 'Desktop camera refusal' : false,
      );
    }
  }

  for (final mode in [
    'video-refusal',
    'switch-recovered',
    'switch-failed',
    'rebuild-failed',
  ]) {
    test(
      'desktop camera failure evidence respects $mode',
      () async {
        SharedPreferences.setMockInitialValues({
          'call.capture.camera.${Platform.operatingSystem}': 'old-camera',
        });
        final wire = _CameraCallWire();
        final engine = _CameraChoiceEngine()
          ..rejectVideo = mode == 'video-refusal';
        final replacement = _CameraChoiceEngine()..rejectAll = true;
        var creations = 0;
        final controller = VeilCallMediaController(
          _Transport(),
          engineFactory:
              ({required veilChan, required localId, required peerId}) =>
                  creations++ == 0 ? engine : replacement,
        );
        final service = CallService(wire, media: controller)..start();
        try {
          await _connectCameraCall(service, wire);
          if (mode.startsWith('switch-')) {
            expect(service.current?.cameraOn, isTrue);
            engine.rejected = 'new-camera';
            engine.rejectAll = mode == 'switch-failed';
            expect(await service.selectCamera('new-camera'), isFalse);
          } else if (mode == 'rebuild-failed') {
            expect(service.current?.cameraOn, isTrue);
            expect(await controller.start(service.current!), isTrue);
          }
          await pumpEventQueue();
          expect(service.current?.status, CallStatus.active);
          expect(service.current?.cameraOn, mode == 'switch-recovered');
          if (mode == 'switch-recovered') {
            expect(engine.activeCamera, 'old-camera');
            expect(
              wire.sent.where((s) => s.capture?.video == false),
              isEmpty,
              reason: 'a recovered selection must ignore its queued failure',
            );
          } else {
            expect(wire.sent.last.capture?.video, isFalse);
          }
        } finally {
          service.dispose();
          await controller.stop();
        }
      },
      skip: Platform.isAndroid ? 'Desktop camera failure' : false,
    );
  }

  for (final refusal in ['stop', 'start', 'throw']) {
    test(
      'failed desktop camera switch ($refusal) preserves the previous choice',
      () async {
        final key = 'call.capture.camera.${Platform.operatingSystem}';
        SharedPreferences.setMockInitialValues({key: 'old-camera'});
        final engine = _CameraChoiceEngine();
        final controller = VeilCallMediaController(
          _Transport(),
          engineFactory:
              ({required veilChan, required localId, required peerId}) =>
                  engine,
        );
        try {
          expect(await controller.start(_call(video: true)), isTrue);
          expect(engine.activeCamera, 'old-camera');
          final starts = engine.cameraStarts.length;
          engine.stopAccepted = refusal != 'stop';
          engine.rejected = 'new-camera';
          engine.throwOnRejected = refusal == 'throw';
          expect(await controller.selectCamera('new-camera'), isFalse);
          expect(engine.activeCamera, 'old-camera');
          expect(
            (await SharedPreferences.getInstance()).getString(key),
            'old-camera',
          );
          expect(
            (await controller.listCameras()).singleWhere((d) => d.selected).id,
            'old-camera',
          );
          if (refusal == 'stop') expect(engine.cameraStarts.length, starts);
          if (kDiagnosticReportEnabled && refusal != 'stop') {
            final events = diagnosticJournal.toJson()['events'] as List;
            final camera = events
                .where((e) => (e as Map)['event'] == 'cameraStart')
                .toList();
            expect(camera.map((e) => (e as Map)['values']), [
              {'success': 1, 'origin': CameraStartOrigin.callStart.index},
              {'success': 0, 'origin': CameraStartOrigin.deviceSelection.index},
              {'success': 1, 'origin': CameraStartOrigin.recovery.index},
            ]);
            final report = jsonEncode(diagnosticJournal.toJson());
            for (final private in [
              'old-camera',
              'new-camera',
              'fixture camera unavailable',
            ]) {
              expect(report, isNot(contains(private)));
            }
          }
        } finally {
          engine.stopAccepted = true;
          await controller.stop();
        }
      },
      skip: Platform.isAndroid ? 'Desktop native-camera path' : false,
    );
  }

  for (final mode in [
    'success',
    'camera-off',
    'rollback-unavailable',
    'stopped-call',
  ]) {
    test(
      'desktop camera selection handles $mode',
      () async {
        final key = 'call.capture.camera.${Platform.operatingSystem}';
        SharedPreferences.setMockInitialValues({key: 'old-camera'});
        final engine = _CameraChoiceEngine();
        final controller = VeilCallMediaController(
          _Transport(),
          engineFactory:
              ({required veilChan, required localId, required peerId}) =>
                  engine,
        );
        try {
          expect(await controller.start(_call(video: true)), isTrue);
          expect(engine.activeCamera, 'old-camera');
          if (mode == 'camera-off') await controller.setCameraEnabled(false);
          if (mode == 'rollback-unavailable') engine.rejectAll = true;
          final starts = engine.cameraStarts.length;
          final selecting = controller.selectCamera('new-camera');
          if (mode == 'stopped-call') await controller.stop();
          final success = mode == 'success' || mode == 'camera-off';
          expect(await selecting, success);
          expect(
            (await SharedPreferences.getInstance()).getString(key),
            success ? 'new-camera' : 'old-camera',
          );
          if (mode == 'success') expect(engine.activeCamera, 'new-camera');
          if (mode == 'camera-off' || mode == 'stopped-call') {
            expect(engine.cameraStarts.length, starts);
            expect(engine.activeCamera, isNull);
          }
          if (mode == 'rollback-unavailable') {
            expect(engine.cameraStarts.skip(starts), [
              'new-camera',
              'old-camera',
            ]);
            expect(engine.activeCamera, isNull);
          }
        } finally {
          await controller.stop();
        }
      },
      skip: Platform.isAndroid ? 'Desktop native-camera path' : false,
    );
  }

  for (final change in [
    'current',
    'hangup',
    'next-call',
    'same-call-engine',
    'new-selection',
    'share-ended',
    'profile',
  ]) {
    test(
      'screen selection discovery respects $change owner',
      () async {
        final wire = _CameraCallWire(), engines = <_ScreenChoiceEngine>[];
        final controller = _ScreenChoiceController(
          _Transport(),
          engineFactory:
              ({required veilChan, required localId, required peerId}) {
                final engine = _ScreenChoiceEngine();
                engines.add(engine);
                return engine;
              },
        );
        final service = CallService(wire, media: controller)..start();
        final list = Completer<List<CallMediaDevice>>();
        Future<bool>? selecting;
        try {
          await _connectCameraCall(service, wire);
          await service.setCameraEnabled(false);
          expect(await service.selectScreen('display-1'), isTrue);
          await service.setScreenShareEnabled(true);
          expect(service.current?.screenOn, isTrue);
          expect(engines.single.activeScreen, 'display-1');
          controller.nextList = list;
          selecting = service.selectScreen('window-2');
          await controller.listEntered.future;
          if (change == 'hangup' || change == 'next-call') {
            await service.hangup();
            await pumpEventQueue();
            expect(engines.first.disposed, isTrue);
            if (change == 'next-call') {
              await _connectCameraCall(service, wire);
              await service.setCameraEnabled(false);
            }
          } else if (change == 'same-call-engine') {
            expect(await controller.start(service.current!), isTrue);
            expect(engines.first.disposed, isTrue);
          } else if (change == 'share-ended') {
            await service.setScreenShareEnabled(false);
            expect(service.current?.screenOn, isFalse);
          } else if (change == 'profile') {
            SharedPreferences.setMockInitialValues({
              'profile-fixture': 'replacement',
            });
          }
          if ([
            'next-call',
            'same-call-engine',
            'new-selection',
          ].contains(change)) {
            expect(await service.selectScreen('display-3'), isTrue);
            if (change == 'next-call') {
              await service.setScreenShareEnabled(true);
            }
            expect(engines.last.activeScreen, 'display-3');
          }
          final before = [
            for (final e in engines)
              {'starts': List.of(e.screenStarts), 'stops': e.screenStops},
          ];
          list.complete(_ScreenChoiceController.screens);
          final result = await selecting;
          await pumpEventQueue();
          final allowed = change == 'current' || change == 'share-ended';
          expect(result, allowed);
          if (change == 'current') {
            expect(engines.last.activeScreen, 'window-2');
          } else {
            expect([
              for (final e in engines)
                {'starts': e.screenStarts, 'stops': e.screenStops},
            ], before);
          }
          expect([for (final e in engines) ...e.retiredScreenCalls], isEmpty);
          if (change == 'share-ended') {
            await service.setScreenShareEnabled(true);
            expect(
              engines.last.activeScreen,
              'window-2',
              reason: 'selection with sharing off is a valid future choice',
            );
          }
          if ([
            'next-call',
            'same-call-engine',
            'new-selection',
          ].contains(change)) {
            expect(service.current?.screenOn, isTrue);
            expect(engines.last.activeScreen, 'display-3');
          }
        } finally {
          if (!list.isCompleted) list.complete(_ScreenChoiceController.screens);
          await selecting;
          service.dispose();
          await controller.stop();
        }
      },
      skip: !Platform.isMacOS ? 'macOS screen-source controller path' : false,
    );
  }

  for (final refusal in [
    'stop',
    'stop-throws',
    'new',
    'new-throws',
    'both',
    'restore-throws',
  ]) {
    test(
      'screen selection preserves actual source on $refusal refusal',
      () async {
        final wire = _CameraCallWire(), engine = _ScreenChoiceEngine();
        final controller = _ScreenChoiceController(
          _Transport(),
          engineFactory:
              ({required veilChan, required localId, required peerId}) =>
                  engine,
        );
        final service = CallService(wire, media: controller)..start();
        try {
          await _connectCameraCall(service, wire);
          await service.setCameraEnabled(false);
          expect(await service.selectScreen('display-1'), isTrue);
          await service.setScreenShareEnabled(true);
          expect(service.current?.screenOn, isTrue);
          engine.screenStarts.clear();
          engine.screenStopAccepted = refusal != 'stop';
          engine.throwScreenStop = refusal == 'stop-throws';
          if (refusal == 'new-throws') engine.throwingScreens.add('window-2');
          if (['new', 'both', 'restore-throws'].contains(refusal)) {
            engine.refusedScreens.add('window-2');
          }
          if (refusal == 'both') engine.refusedScreens.add('display-1');
          if (refusal == 'restore-throws') {
            engine.throwingScreens.add('display-1');
          }
          expect(await service.selectScreen('window-2'), isFalse);
          await pumpEventQueue();
          final stopped = refusal == 'both' || refusal == 'restore-throws';
          expect(service.current?.status, CallStatus.active);
          expect(service.current?.screenOn, !stopped);
          expect(service.current?.cameraOn, isFalse);
          expect(engine.activeScreen, stopped ? null : 'display-1');
          expect(
            engine.screenStarts,
            refusal.startsWith('stop') ? isEmpty : ['window-2', 'display-1'],
          );
          expect(engine.disposed, isFalse);
          if (stopped) {
            expect(
              wire.sent
                  .lastWhere((s) => s.type == CallSignalType.renegotiate)
                  .media
                  ?.screen,
              isFalse,
            );
          }
        } finally {
          service.dispose();
          await controller.stop();
        }
      },
      skip: !Platform.isMacOS ? 'macOS screen-source controller path' : false,
    );
  }

  for (final rebuild in [false, true]) {
    test(
      'screen selection stopped event ignores recovered source rebuild=$rebuild',
      () async {
        final wire = _CameraCallWire(), engines = <_ScreenChoiceEngine>[];
        final controller = _ScreenChoiceController(
          _Transport(),
          engineFactory:
              ({required veilChan, required localId, required peerId}) {
                final engine = _ScreenChoiceEngine();
                engines.add(engine);
                return engine;
              },
        );
        final service = CallService(wire, media: controller)..start();
        var delayedStops = 0;
        final delayed = controller.screenShareStopped.listen(
          (_) => delayedStops++,
        );
        delayed.pause();
        try {
          await _connectCameraCall(service, wire);
          await service.setCameraEnabled(false);
          expect(await service.selectScreen('display-1'), isTrue);
          await service.setScreenShareEnabled(true);
          engines.last.refusedScreens.addAll(['window-2', 'display-1']);
          expect(await service.selectScreen('window-2'), isFalse);
          await pumpEventQueue();
          expect(service.current?.screenOn, isFalse);
          engines.last.refusedScreens.clear();
          await service.setScreenShareEnabled(true);
          if (rebuild) expect(await controller.start(service.current!), isTrue);
          expect(service.current?.screenOn, isTrue);
          expect(engines.last.activeScreen, 'display-1');
          delayed.resume();
          await pumpEventQueue();
          expect(
            delayedStops,
            0,
            reason: 'retained stop must not describe the recovered source',
          );
          expect(service.current?.screenOn, isTrue);
          expect(engines.last.activeScreen, 'display-1');
        } finally {
          await delayed.cancel();
          service.dispose();
          await controller.stop();
        }
      },
      skip: !Platform.isMacOS ? 'macOS screen-source controller path' : false,
    );
  }

  for (final replaceProfile in [false, true]) {
    test('camera preference owner replace=$replaceProfile', () async {
      final key = 'call.capture.camera.${Platform.operatingSystem}';
      SharedPreferences.setMockInitialValues({key: 'old-camera'});
      final engine = _CameraChoiceEngine();
      final controller = VeilCallMediaController(
        _Transport(),
        engineFactory:
            ({required veilChan, required localId, required peerId}) => engine,
      );
      try {
        expect(await controller.start(_call(video: true)), isTrue);
        final selecting = controller.selectCamera('new-camera');
        if (replaceProfile) {
          SharedPreferences.setMockInitialValues({'profile-fixture': 'new'});
        }
        expect(await selecting, !replaceProfile);
        expect(
          engine.activeCamera,
          replaceProfile ? 'old-camera' : 'new-camera',
        );
        expect(
          (await SharedPreferences.getInstance()).getString(key),
          replaceProfile ? null : 'new-camera',
        );
      } finally {
        await controller.stop();
      }
    });
  }

  for (final output in [false, true]) {
    for (final action in ['current', 'hangup', 'profile', 'profile-live']) {
      test('audio selection lifetime output=$output action=$action', () async {
        final engine = _AudioChoiceCameraEngine(), camera = _ClosingCamera();
        final controller = VeilCallMediaController(
          _Transport(),
          engineFactory:
              ({required veilChan, required localId, required peerId}) =>
                  engine,
          androidCameraCapture: true,
          nativeCameraFactory: () => camera,
        );
        final key = output
            ? 'call.playout.speaker.${Platform.operatingSystem}'
            : 'call.capture.microphone.${Platform.operatingSystem}';
        Future<void>? ending;
        try {
          expect(
            await controller.start(
              _call(video: true).copyWith(cameraOn: false),
            ),
            isTrue,
          );
          await controller.setCameraEnabled(true);
          expect(camera.isRunning, isTrue);
          final selecting = output
              ? controller.selectSpeaker('choice-output')
              : controller.selectMicrophone('choice-input');
          if (action == 'hangup' || action == 'profile') {
            ending = controller.stop();
          }
          if (action.startsWith('profile')) {
            SharedPreferences.setMockInitialValues({'profile-fixture': 'new'});
          }
          // The list API's actual await is enough: no mocked discovery delay.
          // The camera fence leaves the old native engine live during hangup.
          final accepted = await selecting;
          if (ending != null) await camera.stopping.future;
          expect(engine.disposed, isFalse);
          expect(
            {
              'accepted': accepted,
              'selected': output
                  ? engine.selectedOutputs
                  : engine.selectedInputs,
              'saved': (await SharedPreferences.getInstance()).getString(key),
            },
            {
              'accepted': action == 'current',
              'selected': action == 'current'
                  ? [output ? 'choice-output' : 'choice-input']
                  : <String>[],
              'saved': action == 'current'
                  ? (output ? 'saved output' : 'saved input')
                  : null,
            },
          );
        } finally {
          if (!camera.released.isCompleted) camera.released.complete();
          await ending;
          await controller.stop();
        }
      });
    }
  }

  for (final output in [false, true]) {
    test(
      'optional preference failure preserves native routing output=$output',
      () async {
        final original = SharedPreferencesStorePlatform.instance;
        final unavailable = _PreflightPreferences(failRead: true)
          ..ready.complete();
        SharedPreferencesStorePlatform.instance = unavailable;
        SharedPreferences.resetStatic();
        final engine = _RestoreStageEngine('none', 'choice');
        final controller = VeilCallMediaController(
          _Transport(),
          engineFactory:
              ({required veilChan, required localId, required peerId}) =>
                  engine,
        );
        try {
          expect(await controller.start(_call()), isTrue);
          final selected = output
              ? await controller.selectSpeaker('choice-output')
              : await controller.selectMicrophone('choice-input');
          expect(
            selected,
            isFalse,
          ); // Existing failed-preference result contract.
          expect(
            output ? engine.selectedOutputs : engine.selectedInputs,
            [output ? 'choice-output' : 'choice-input'],
            reason:
                'optional persistence must not skip the live native selection',
          );
        } finally {
          await controller.stop();
          SharedPreferencesStorePlatform.instance = original;
          SharedPreferences.resetStatic();
        }
      },
    );
  }

  for (final preference in [
    null,
    'chosen microphone',
    'unplugged microphone',
  ]) {
    test(
      'microphone restore resolves a role instead of a stale index: $preference',
      () async {
        final key = 'call.capture.microphone.${Platform.operatingSystem}';
        SharedPreferences.setMockInitialValues({key: ?preference});
        final engine = _InputChoiceEngine();
        final controller = VeilCallMediaController(
          _Transport(),
          engineFactory:
              ({required veilChan, required localId, required peerId}) =>
                  engine,
        );
        try {
          expect(await controller.start(_call()), isTrue);
          final expected = preference == 'chosen microphone'
              ? '2'
              : 'system-default';
          expect(engine.activeInput, expected);
          expect(engine.selected, [expected]);
          expect(
            (await controller.listMicrophones())
                .where((d) => d.selected)
                .map((d) => d.id),
            [expected],
          );
          expect(
            (await SharedPreferences.getInstance()).getString(key),
            preference,
            reason: 'temporary absence must not forget the explicit preference',
          );
        } finally {
          await controller.stop();
        }
      },
    );
  }

  test(
    'returning to the system microphone clears only an accepted choice',
    () async {
      final key = 'call.capture.microphone.${Platform.operatingSystem}';
      SharedPreferences.setMockInitialValues({key: 'chosen microphone'});
      final engine = _InputChoiceEngine();
      final controller = VeilCallMediaController(
        _Transport(),
        engineFactory:
            ({required veilChan, required localId, required peerId}) => engine,
      );
      try {
        expect(await controller.start(_call()), isTrue);
        engine.rejected = 'system-default';
        expect(await controller.selectMicrophone('system-default'), isFalse);
        expect(
          (await SharedPreferences.getInstance()).getString(key),
          'chosen microphone',
        );
        expect(engine.activeInput, '2');
        engine.rejected = null;
        expect(await controller.selectMicrophone('system-default'), isTrue);
        expect(
          (await SharedPreferences.getInstance()).containsKey(key),
          isFalse,
        );
        expect(
          (await controller.listMicrophones())
              .singleWhere((d) => d.selected)
              .id,
          'system-default',
        );
      } finally {
        await controller.stop();
      }
    },
  );

  test('an input without role metadata does not claim numeric zero', () async {
    final engine = _InputChoiceEngine(hasDefault: false);
    final controller = VeilCallMediaController(
      _Transport(),
      engineFactory: ({required veilChan, required localId, required peerId}) =>
          engine,
    );
    try {
      expect(await controller.start(_call()), isTrue);
      expect(engine.selected, isEmpty);
      expect(
        (await controller.listMicrophones()).where((d) => d.selected),
        isEmpty,
      );
    } finally {
      await controller.stop();
    }
  });

  for (final preference in [null, 'chosen speaker', 'unplugged speaker']) {
    test('speaker restore uses the actual choice: $preference', () async {
      final key = 'call.playout.speaker.${Platform.operatingSystem}';
      SharedPreferences.setMockInitialValues({
        key: ?preference,
      });
      final engine = _OutputChoiceEngine();
      final controller = VeilCallMediaController(
        _Transport(),
        engineFactory:
            ({required veilChan, required localId, required peerId}) => engine,
      );
      try {
        expect(await controller.start(_call()), isTrue);
        final expected = preference == 'chosen speaker'
            ? '2'
            : 'system-default';
        expect(engine.selected, [expected]);
        expect(
          (await controller.listSpeakers())
              .where((device) => device.selected)
              .map((device) => device.id),
          [expected],
        );
      } finally {
        await controller.stop();
      }
    });
  }

  test(
    'returning to system output clears the saved device preference',
    () async {
      final key = 'call.playout.speaker.${Platform.operatingSystem}';
      SharedPreferences.setMockInitialValues({key: 'chosen speaker'});
      final engine = _OutputChoiceEngine();
      final controller = VeilCallMediaController(
        _Transport(),
        engineFactory:
            ({required veilChan, required localId, required peerId}) => engine,
      );
      try {
        expect(await controller.start(_call()), isTrue);
        engine.rejected = 'system-default';
        expect(await controller.selectSpeaker('system-default'), isFalse);
        expect(
          (await SharedPreferences.getInstance()).getString(key),
          'chosen speaker',
        );
        expect(
          (await controller.listSpeakers()).singleWhere((d) => d.selected).id,
          '2',
        );
        engine.rejected = null;
        expect(await controller.selectSpeaker('system-default'), isTrue);
        expect(
          (await SharedPreferences.getInstance()).containsKey(key),
          isFalse,
        );
        expect(
          (await controller.listSpeakers()).singleWhere((d) => d.selected).id,
          'system-default',
        );
      } finally {
        await controller.stop();
      }
    },
  );

  test(
    'an engine without output-role metadata cannot claim device zero',
    () async {
      final engine = _OutputChoiceEngine(hasDefault: false);
      final controller = VeilCallMediaController(
        _Transport(),
        engineFactory:
            ({required veilChan, required localId, required peerId}) => engine,
      );
      try {
        expect(await controller.start(_call()), isTrue);
        expect(engine.selected, isEmpty);
        expect(
          (await controller.listSpeakers()).where((d) => d.selected),
          isEmpty,
        );
      } finally {
        await controller.stop();
      }
    },
  );

  for (final stage in [
    'preferences',
    'failed-preferences',
    'network',
    'permission',
    'identity',
  ]) {
    for (final action in ['none', 'hangup', 'next-call']) {
      test(
        'media preflight cancellation at $stage with $action',
        () async {
          const network = MethodChannel('xveil/call_network');
          const permissions = MethodChannel('xveil/media_permissions');
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          final store = SharedPreferencesStorePlatform.instance;
          final loadingPreferences = stage.endsWith('preferences');
          final prefs = _PreflightPreferences(
            failRead: stage == 'failed-preferences',
          );
          if (loadingPreferences) {
            SharedPreferences.resetStatic();
            SharedPreferencesStorePlatform.instance = prefs;
          }
          final entered = Completer<void>(), ready = Completer<void>();
          final networkChanges = <bool>[];
          var permissionRequests = 0;
          messenger.setMockMethodCallHandler(network, (request) async {
            final active = (request.arguments as Map)['active'] as bool;
            networkChanges.add(active);
            if (stage == 'network' && active && !entered.isCompleted) {
              entered.complete();
              await ready.future;
            }
            return active;
          });
          messenger.setMockMethodCallHandler(permissions, (request) async {
            if (request.method != 'request') return 'authorized';
            permissionRequests++;
            if (stage == 'permission' && !entered.isCompleted) {
              entered.complete();
              await ready.future;
            }
            return true;
          });
          final transport = _PreflightTransport()
            ..delayIdentity = stage == 'identity';
          final engines = <_RestoreStageEngine>[];
          final controller = VeilCallMediaController(
            transport,
            engineFactory:
                ({required veilChan, required localId, required peerId}) {
                  final engine = _RestoreStageEngine('none', 'current');
                  engines.add(engine);
                  return engine;
                },
          );
          final starting = controller.start(_call());
          Future<void>? ending;
          Future<bool>? next;
          try {
            await (loadingPreferences
                    ? prefs.entered.future
                    : stage == 'identity'
                    ? transport.identityEntered.future
                    : entered.future)
                .timeout(const Duration(seconds: 5));
            if (action != 'none') ending = controller.stop();
            if (action == 'next-call') {
              next = controller.start(_call(callId: 'successor-call'));
              // Drain already-ready work while the explicit first-stage gate
              // stays closed; this is not a latency threshold.
              await Future<void>.delayed(Duration.zero);
            }
            if (!prefs.ready.isCompleted) prefs.ready.complete();
            if (!ready.isCompleted) ready.complete();
            if (!transport.identityReady.isCompleted) {
              transport.identityReady.complete();
            }
            expect(await starting, action == 'none');
            await ending;
            if (next != null) expect(await next, isTrue);
            final expectedOpens = action == 'hangup' ? 0 : 1;
            final earlyHangup =
                action == 'hangup' &&
                (loadingPreferences || stage == 'network');
            expect(
              {
                'opened': transport.openedChannels.length,
                'engines': engines.length,
                'networkHeld':
                    controller.diagnostics['call_network_activity_active'],
                if (action == 'hangup')
                  'networkReleased':
                      networkChanges.isEmpty || !networkChanges.last,
                if (earlyHangup) 'permissionRequests': permissionRequests,
              },
              {
                'opened': expectedOpens,
                'engines': expectedOpens,
                'networkHeld': action != 'hangup',
                if (action == 'hangup') 'networkReleased': true,
                if (earlyHangup) 'permissionRequests': 0,
              },
              reason: 'retired preflight cannot open a route or retain a grant',
            );
            if (stage == 'preferences' && engines.isNotEmpty) {
              expect(
                engines.single.selectedInputs,
                ['current-input'],
                reason: 'the successor must await the shared preference load',
              );
            }
            if (stage == 'failed-preferences' && engines.isNotEmpty) {
              expect(engines.single.selectedInputs, isEmpty);
              expect(
                engines.single.audioStarts,
                1,
                reason:
                    'an optional preference read failure is not a call failure',
              );
            }
          } finally {
            if (!prefs.ready.isCompleted) prefs.ready.complete();
            if (!ready.isCompleted) ready.complete();
            if (!transport.identityReady.isCompleted) {
              transport.identityReady.complete();
            }
            try {
              await starting;
              await ending;
              await next;
            } finally {
              try {
                await controller.stop();
              } finally {
                messenger.setMockMethodCallHandler(network, null);
                messenger.setMockMethodCallHandler(permissions, null);
                SharedPreferencesStorePlatform.instance = store;
                SharedPreferences.resetStatic();
              }
            }
          }
        },
        skip: !Platform.isMacOS
            ? 'macOS fixture uses the real platform activity/permission branch'
            : false,
      );
    }
  }

  for (final stage in ['input', 'output', 'mute']) {
    for (final action in ['none', 'hangup', 'next-call', 'same-call-engine']) {
      test(
        'audio startup owner after $stage and $action',
        () async {
          SharedPreferences.setMockInitialValues({
            if (stage == 'input')
              'call.capture.microphone.${Platform.operatingSystem}':
                  'saved input',
            if (stage == 'output')
              'call.playout.speaker.${Platform.operatingSystem}':
                  'saved output',
          });
          final old = _RestoreStageEngine(stage, 'old');
          final fresh = _RestoreStageEngine('none', 'new');
          var creates = 0;
          final controller = VeilCallMediaController(
            _Transport(),
            engineFactory:
                ({required veilChan, required localId, required peerId}) =>
                    creates++ == 0 ? old : fresh,
          );
          bool? outcome;
          Object? error;
          final starting = controller
              .start(_call())
              .then<void>(
                (ok) => outcome = ok,
                onError: (Object failure) {
                  error = failure;
                },
              );
          Future<void>? ending;
          Future<bool>? next;
          try {
            await old.entered.future.timeout(const Duration(seconds: 5));
            if (action == 'hangup' || action == 'next-call') {
              ending = controller.stop();
            }
            if (action == 'next-call' || action == 'same-call-engine') {
              next = controller.start(
                _call(
                  callId: action == 'next-call'
                      ? 'successor-call'
                      : 'receive-only-start',
                ),
              );
            }
            await starting;
            await ending;
            if (next != null) {
              expect(await next, true);
              expect(fresh.audioStarts, 1);
              expect(fresh.disposed, false);
            }
            expect(
              old.retiredCalls,
              isEmpty,
              reason: 'an old continuation must not touch a disposed engine',
            );
            expect(
              error,
              isNull,
              reason: 'a retired startup returns false cleanly',
            );
            expect(outcome, action == 'none');
            if (action == 'none') {
              expect(old.audioStarts, 1);
              if (stage == 'input') {
                expect(old.selectedInputs, ['old-input']);
              }
              if (stage == 'output') {
                expect(old.selectedOutputs, ['old-output']);
              }
            } else {
              expect(old.audioStarts, 0);
            }
          } finally {
            await starting;
            await ending;
            await next;
            await controller.stop();
          }
        },
        skip: Platform.isAndroid || Platform.isIOS
            ? 'desktop device enumeration fixture; no phone hardware opened'
            : false,
      );
    }
  }

  for (final mode in ['confirmed', 'no echo', 'no longer needed', 'hangup']) {
    test('refresh live relay with peer proof: $mode', () async {
      final transport = _HandoverTransport();
      final engine = _HandoverEngine();
      var engines = 0;
      final controller = VeilCallMediaController(
        transport,
        engineFactory: ({required veilChan, required localId, required peerId}) {
          engines++;
          return engine;
        },
      );
      Future<bool>? refreshing;
      try {
        final call = _call(
          direct: true,
        ).copyWith(transport: CallTransportKind.relay);
        expect(await controller.start(call), isTrue);
        var stillNeeded = true;
        refreshing = controller.refreshRelayRoute(
          canCommit: () async => stillNeeded,
        );
        await Future.any([
          transport.qualifying.future.then((_) {}),
          refreshing.then((_) => fail('The candidate must be probed')),
        ]);
        expect(transport.opened, [42, 43]);
        expect(transport.closed, isEmpty);
        expect(engine.rebound, isEmpty);
        expect(controller.activeTransport, CallTransportKind.relay);

        if (mode == 'hangup') await controller.stop();
        stillNeeded = mode != 'no longer needed';
        transport.echo.complete(mode != 'no echo');
        expect(await refreshing, mode == 'confirmed');
        expect(transport.probeRequests, [43]);
        expect(engines, 1);
        expect(engine.rebound, mode == 'confirmed' ? [43] : isEmpty);
        if (mode != 'hangup') {
          expect(engine.disposed, isFalse);
          expect(controller.activeTransport, CallTransportKind.relay);
          if (mode != 'confirmed') expect(transport.closed, [43]);
        }
        await controller.stop();
        expect(transport.closed, unorderedEquals([42, 43]));
      } finally {
        if (!transport.echo.isCompleted) transport.echo.complete(false);
        await refreshing;
        await controller.stop();
      }
    });
  }

  for (final retrySucceeds in [false, true]) {
    test('relay retry reuses one opened candidate: $retrySucceeds', () async {
      final transport = _HandoverTransport()..proofAvailable = false;
      final engine = _HandoverEngine();
      final controller = VeilCallMediaController(
        transport,
        engineFactory:
            ({required veilChan, required localId, required peerId}) => engine,
      );
      try {
        expect(await controller.start(_call(direct: true)), isTrue);
        expect(await controller.switchRoute(CallTransportKind.relay), isFalse);
        expect(transport.opened, [42, 43]);
        expect(transport.probeRequests, [43, 43, 43]);
        expect(controller.activeTransport, CallTransportKind.p2p);
        expect(engine.rebound, isEmpty);

        transport.proofAvailable = retrySucceeds;
        expect(
          await controller.switchRoute(CallTransportKind.relay),
          retrySucceeds,
        );
        expect(transport.opened, [42, 43]);
        if (retrySucceeds) {
          expect(transport.probeRequests, [43, 43, 43, 43]);
          expect(transport.closed, isNot(contains(43)));
          expect(engine.rebound, [43]);
          expect(controller.activeTransport, CallTransportKind.relay);
        } else {
          expect(transport.probeRequests, List.filled(6, 43));
          expect(transport.closed, [43]);
          expect(engine.rebound, isEmpty);
          transport.proofAvailable = true;
          expect(await controller.switchRoute(CallTransportKind.relay), isTrue);
          expect(transport.opened, [42, 43, 44]);
          expect(transport.probeRequests.last, 44);
          expect(engine.rebound, [44]);
        }
      } finally {
        await controller.stop();
      }
    });
  }

  test('an unused relay candidate expires after the retry window', () async {
    final transport = _HandoverTransport()..proofAvailable = false;
    final controller = VeilCallMediaController(
      transport,
      engineFactory:
          ({required veilChan, required localId, required peerId}) =>
              _HandoverEngine(),
    );
    try {
      expect(await controller.start(_call(direct: true)), isTrue);
      fakeAsync((async) {
        bool? result;
        unawaited(controller.switchRoute(CallTransportKind.relay).then((ok) {
          result = ok;
        }));
        async.flushMicrotasks();
        expect(result, isFalse);
        async.elapse(kCallRelayCandidateRetry);
        expect(transport.closed, isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(transport.closed, [43]);
      });
      expect(controller.activeTransport, CallTransportKind.p2p);
    } finally {
      await controller.stop();
    }
  });

  test('hangup closes a retained relay candidate before another call', () async {
    final transport = _HandoverTransport()..proofAvailable = false;
    final engines = [_HandoverEngine(), _HandoverEngine()];
    var created = 0;
    final controller = VeilCallMediaController(
      transport,
      engineFactory:
          ({required veilChan, required localId, required peerId}) =>
              engines[created++],
    );
    try {
      expect(await controller.start(_call(direct: true)), isTrue);
      expect(await controller.switchRoute(CallTransportKind.relay), isFalse);
      expect(transport.closed, isEmpty);
      await controller.stop();
      expect(transport.closed, unorderedEquals([42, 43]));

      expect(await controller.start(_call(direct: true, peer: _id(3))), isTrue);
      transport.proofAvailable = true;
      expect(await controller.switchRoute(CallTransportKind.relay), isTrue);
      expect(transport.opened, [42, 43, 44, 45]);
      expect(engines.last.rebound, [45]);
    } finally {
      await controller.stop();
    }
  });

  const inactiveDirectSession = 'direct media session is not active';

  test(
    'an initial media start retries a direct session still registering',
    () async {
      final transport = _HandoverTransport()
        ..directOpenFailures.add(inactiveDirectSession);
      final controller = VeilCallMediaController(
        transport,
        engineFactory:
            ({required veilChan, required localId, required peerId}) =>
                _HandoverEngine(),
      );
      try {
        expect(await controller.start(_call(direct: true)), isTrue);
        expect(transport.directOpenAttempts, 2);
        expect(transport.peerAdmissionChecks, 1);
        expect(controller.activeTransport, CallTransportKind.p2p);
      } finally {
        await controller.stop();
      }
    },
  );

  for (final error in [
    inactiveDirectSession,
    'direct session probe failed',
    'direct session probe timed out',
  ]) {
    test('live media repair after $error', () async {
      final transport = _HandoverTransport();
      final engines = [_HandoverEngine(), _HandoverEngine()];
      var created = 0;
      final controller = VeilCallMediaController(
        transport,
        engineFactory:
            ({required veilChan, required localId, required peerId}) =>
                engines[created++],
      );
      try {
        expect(await controller.start(_call(direct: true)), isTrue);
        transport.directOpenFailures.add(error);
        expect(await controller.repairRoute(), isTrue);
        final inactive = error == inactiveDirectSession;
        expect(transport.directOpenAttempts, inactive ? 2 : 3);
        expect(transport.peerAdmissionChecks, inactive ? 0 : 1);
        expect(
          controller.activeTransport,
          inactive ? CallTransportKind.relay : CallTransportKind.p2p,
        );
        expect(transport.opened, [42, 43]);
        expect(transport.closed, [42]);
        expect(engines.first.disposed, isTrue);
        expect(engines.last.disposed, isFalse);
      } finally {
        await controller.stop();
      }
    });
  }

  test('an agreed relay can be reopened after a failed media rebuild', () async {
    final transport = _HandoverTransport();
    final engines = [_HandoverEngine(), _HandoverEngine()];
    var created = 0;
    final controller = VeilCallMediaController(
      transport,
      engineFactory:
          ({required veilChan, required localId, required peerId}) =>
              engines[created++],
    );
    try {
      final call = _call(direct: true).copyWith(
        transport: CallTransportKind.relay,
      );
      expect(await controller.start(call), isTrue);
      transport.failRelayOpen = true;
      expect(await controller.repairRoute(), isFalse);
      expect(controller.activeTransport, isNull);
      expect(engines.first.disposed, isTrue);

      transport.failRelayOpen = false;
      expect(await controller.switchRoute(CallTransportKind.relay), isTrue);
      expect(controller.activeTransport, CallTransportKind.relay);
      expect(transport.opened, [42, 43]);
      expect(transport.closed, [42]);
      expect(engines.last.disposed, isFalse);
    } finally {
      await controller.stop();
    }
  });

  for (final audio in [false, true]) {
    test(
      'reads live receive stats during relay qualification, audio=$audio',
      () async {
        final transport = _HandoverTransport();
        final engine = _HandoverEngine();
        final controller = VeilCallMediaController(
          transport,
          engineFactory:
              ({required veilChan, required localId, required peerId}) => engine,
        );
        final read = audio
            ? controller.readLatestAudioRxAt
            : controller.readLatestMediaRxAt;
        Future<bool>? switching;
        try {
          expect(await controller.start(_call(direct: true)), isTrue);
          expect(await read(), isNull);
          switching = controller.switchRoute(CallTransportKind.relay);
          await transport.qualifying.future.timeout(const Duration(seconds: 5));
          expect(controller.isRepairingReceiveSession, isTrue);
          expect(controller.activeTransport, CallTransportKind.p2p);

          engine.received = 1;
          engine.stalled = true;
          expect(await read(), isNull);
          engine.stalled = false;
          final receivedAt = await read();
          expect(receivedAt, isNotNull, reason: 'the original engine is alive');
          if (!audio) expect(await read(), receivedAt);
          expect(transport.echo.isCompleted, isFalse);

          await controller.stop();
          expect(await read(), isNull);
        } finally {
          await controller.stop();
          transport.echo.complete(false);
          await switching;
        }
      },
    );
  }

  test(
    'retired relay qualification cannot block repair in the next call',
    () async {
      final transport = _HandoverTransport();
      final original = _HandoverEngine();
      final successor = _Engine(nativeStarted: true, capture: 1);
      var engines = 0;
      final controller = VeilCallMediaController(
        transport,
        engineFactory: ({required veilChan, required localId, required peerId}) =>
            engines++ == 0 ? original : successor,
      );
      Future<bool>? retiring, queued;
      try {
        expect(await controller.start(_call(direct: true)), isTrue);
        retiring = controller.switchRoute(CallTransportKind.relay);
        final candidate = await transport.qualifying.future.timeout(
          const Duration(seconds: 5),
        );
        // Also place a second command behind the retiring qualification. A
        // reused call ID must not let that command reach a different peer.
        queued = controller.switchRoute(CallTransportKind.relay);
        await controller.stop();
        expect(await controller.start(_call(peer: _id(3))), isTrue);
        expect(original.disposed, isTrue);
        expect(await controller.repairRoute(), isTrue);
        expect(transport.repairs, 1);
        expect(controller.isRepairingReceiveSession, isFalse);

        transport.echo.complete(true);
        expect(await retiring, isFalse);
        expect(await queued, isFalse);
        expect(transport.closed, [transport.opened.first, candidate]);
        expect(controller.activeTransport, CallTransportKind.onion);
        expect(successor.disposed, isFalse);
      } finally {
        await controller.stop();
        if (!transport.echo.isCompleted) transport.echo.complete(false);
        await retiring;
        await queued;
      }
    },
  );

  for (final replacement in [false, true]) {
    test(
      'late video upgrade cannot survive hangup (new call=$replacement)',
      () async {
        final old = _UpgradeEngine();
        final fresh = _Engine(nativeStarted: true, capture: 1);
        var creates = 0;
        final controller = VeilCallMediaController(
          _Transport(),
          engineFactory:
              ({required veilChan, required localId, required peerId}) =>
                  creates++ == 0 ? old : fresh,
        );
        Future<bool>? upgrade, next;
        Future<void>? ending;
        try {
          expect(await controller.start(_call()), true);
          upgrade = controller.setVideoEnabled(true);
          // startVideo proves the request reached native mounting. Its following
          // audio-route await yields before the old Call snapshot is published.
          await old.videoStarted.future.timeout(const Duration(seconds: 5));
          ending = controller.stop();
          if (replacement) next = controller.start(_call(callId: 'next-call'));
          await ending;
          final upgraded = await upgrade;
          if (replacement) {
            expect(
              await next!,
              true,
              reason: 'a stale upgrade must not overwrite the next call owner',
            );
            expect(fresh.disposed, false);
            expect(controller.activeTransport, CallTransportKind.onion);
          } else {
            expect(controller.activeTransport, isNull);
          }
          expect(
            upgraded,
            false,
            reason: 'hangup retires the pending video activation',
          );
          expect(old.disposed, true);
        } finally {
          await ending;
          await upgrade;
          await next;
          await controller.stop();
        }
      },
    );
  }

  for (final change in [
    'hangup',
    'new-call',
    'same-call-engine',
    'same-id-other-peer',
    'none',
  ]) {
    test(
      'video permission result respects current media owner after $change',
      () async {
        const permissions = MethodChannel('xveil/media_permissions');
        final entered = Completer<void>(), permission = Completer<bool>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(permissions, (request) async {
              if ((request.arguments as Map)['type'] == 'video') {
                if (!entered.isCompleted) entered.complete();
                return permission.future;
              }
              return true;
            });
        final old = _UpgradeEngine(), fresh = _UpgradeEngine();
        var creates = 0;
        final transport = _RepairingTransport();
        final controller = VeilCallMediaController(
          transport,
          engineFactory:
              ({required veilChan, required localId, required peerId}) =>
                  creates++ == 0 ? old : fresh,
        );
        Future<bool>? upgrade;
        try {
          expect(await controller.start(_call()), true);
          upgrade = controller.setVideoEnabled(true);
          await entered.future.timeout(const Duration(seconds: 5));
          if (change == 'none') {
            expect(await controller.repairRoute(), true);
            expect(
              transport.repairs,
              1,
              reason: 'a permission prompt must not hold the repair queue',
            );
          }
          if (change == 'hangup') await controller.stop();
          if (change == 'new-call' ||
              change == 'same-call-engine' ||
              change == 'same-id-other-peer') {
            expect(
              await controller.start(
                _call(
                  peer: change == 'same-id-other-peer' ? _id(3) : null,
                  callId: change == 'new-call'
                      ? 'replacement-call'
                      : 'receive-only-start',
                ),
              ),
              true,
            );
          }
          permission.complete(true);
          final continuing = change == 'none' || change == 'same-call-engine';
          expect(await upgrade, continuing);
          expect(
            old.videoStarts,
            change == 'none' ? 1 : 0,
            reason:
                'permission for an obsolete session must never target its engine',
          );
          expect(
            fresh.videoStarts,
            change == 'same-call-engine' ? 1 : 0,
            reason:
                'a same-call repair must not lose the requested video upgrade',
          );
          if (change == 'none') {
            expect(await controller.setVideoEnabled(true), true);
            expect(
              old.videoStarts,
              1,
              reason: 'a completed upgrade is already mounted',
            );
          }
          if (change != 'hangup') {
            expect(controller.activeTransport, CallTransportKind.onion);
          }
        } finally {
          if (!permission.isCompleted) permission.complete(false);
          await upgrade;
          await controller.stop();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(permissions, null);
        }
      },
      skip: !(Platform.isMacOS || Platform.isIOS || Platform.isAndroid)
          ? 'permission-channel fixture needs an Apple or Android host'
          : false,
    );
  }


  for (final cancel in [false, true]) {
    test('capture waits for stored processing choice; cancel=$cancel', () async {
      final ready = Completer<void>();
      final transport = _OpeningTransport();
      final engine = _Engine(nativeStarted: true, capture: 1);
      var creates = 0;
      final controller = VeilCallMediaController(transport,
        audioProcessingReady: ready.future,
        engineFactory: ({required veilChan, required localId, required peerId}) {
          creates++;
          return engine;
        },
      );
      final start = controller.start(_call());
      try {
        await transport.opened.future;
        // Yield one event-loop turn so the immediate route/permission futures
        // drain. The held storage gate, not elapsed time, controls readiness.
        await Future<void>.delayed(Duration.zero);
        expect(creates, 0);
        if (cancel) await controller.stop();
        controller.setNoiseSuppression(false);
        ready.complete();
        expect(await start, !cancel);
        expect(creates, cancel ? 0 : 1);
        if (!cancel) expect(engine.noiseSuppression, [false]);
      } finally {
        if (!ready.isCompleted) ready.complete();
        await start;
        await controller.stop();
      }
    });
  }

  test(
    'noise choice survives live toggles and engine rebuild; refusal is not remembered',
    () async {
      final engines = [
        _Engine(nativeStarted: true, capture: 1),
        _Engine(nativeStarted: true, capture: 1),
      ];
      var creates = 0;
      final controller = VeilCallMediaController(
        _Transport(),
        engineFactory:
            ({required veilChan, required localId, required peerId}) =>
                engines[creates++],
      );
      try {
        expect(controller.setNoiseSuppression(false), isTrue);
        expect(await controller.start(_call()), isTrue);
        expect(engines[0].noiseSuppression, [false]);
        expect(controller.setNoiseSuppression(true), isTrue);
        engines[0].rejectNoiseSuppression = true;
        expect(controller.setNoiseSuppression(false), isFalse);
        expect(await controller.start(_call()), isTrue);
        expect(engines[0].disposed, isTrue);
        expect(engines[1].noiseSuppression, [true]);
      } finally {
        await controller.stop();
      }
    },
  );

  test(
    'same-call engine rebuild preserves the last real liveness receipt',
    () async {
      final engines = [
        _LivenessEngine(100),
        _LivenessEngine(0),
        _LivenessEngine(0),
      ];
      var creates = 0;
      final controller = VeilCallMediaController(
        _Transport(),
        engineFactory:
            ({required veilChan, required localId, required peerId}) =>
                engines[creates++],
      );
      final call = _call();
      try {
        expect(await controller.start(call), isTrue);
        final received = await controller.readLatestMediaRxAt();
        expect(received, isNotNull);
        expect(await controller.start(call), isTrue);
        expect(engines.first.disposed, isTrue);
        expect(
          controller.lastMediaRxAt,
          received,
          reason: 'local repair must not make the last peer activity older',
        );
        expect(
          await controller.readLatestMediaRxAt(),
          received,
          reason: 'the replacement has no packets; rebuilding is no new proof',
        );

        await controller.stop();
        expect(controller.lastMediaRxAt, isNull);
        expect(await controller.start(_call(callId: 'another-call')), isTrue);
        expect(
          await controller.readLatestMediaRxAt(),
          isNull,
          reason: 'a new call must not inherit the prior call receipt',
        );
      } finally {
        await controller.stop();
      }
    },
  );

  for (final outcome in [
    'denied',
    'capture-refused',
    'capture-threw',
    'permission-threw',
  ]) {
    test(
      'late microphone $outcome disables capture posture without stopping receive',
      () async {
        final permission = Completer<bool>();
        final engine = _Engine(nativeStarted: true, capture: 1);
        final controller = VeilCallMediaController(
          _Transport(),
          engineFactory:
              ({required veilChan, required localId, required peerId}) =>
                  engine,
          microphonePermissionFactory: (_) =>
              CallMicrophonePermission(permission.future),
        );
        final unavailable = <String>[];
        final sub = controller.microphoneUnavailable.listen(unavailable.add);
        try {
          expect(await controller.start(_call()), isTrue);
          expect(
            engine.mutes.last,
            isTrue,
            reason: 'pending permission gates capture',
          );
          engine.muteAccepted = outcome != 'capture-refused';
          engine.throwOnMute = outcome == 'capture-threw';
          if (outcome == 'permission-threw') {
            permission.completeError(
              StateError('private permission provider failure'),
            );
          } else {
            permission.complete(outcome != 'denied');
          }
          await pumpEventQueue();
          expect(controller.startedWithoutMicrophone, isTrue);
          expect(unavailable, ['receive-only-start']);
          expect(engine.disposed, isFalse);
          if (outcome == 'capture-refused' || outcome == 'capture-threw') {
            engine.muteAccepted = true;
            engine.throwOnMute = false;
            expect(await controller.setMicMuted(false), isTrue);
            expect(controller.startedWithoutMicrophone, isFalse);
            expect(engine.mutes.last, isFalse);
          }
        } finally {
          await controller.stop();
          await sub.cancel();
        }
      },
    );
  }

  for (final end in ['stop', 'new-call', 'new-engine']) {
    test('late denial cannot affect $end', () async {
      final permission = Completer<bool>();
      final first = _Engine(nativeStarted: true, capture: 1);
      final replacement = _Engine(nativeStarted: true, capture: 1);
      var creates = 0;
      var requests = 0;
      final controller = VeilCallMediaController(
        _Transport(),
        engineFactory:
            ({required veilChan, required localId, required peerId}) =>
                creates++ == 0 ? first : replacement,
        microphonePermissionFactory: (_) => CallMicrophonePermission(
          requests++ == 0 ? permission.future : Future.value(true),
        ),
      );
      final unavailable = <String>[];
      final sub = controller.microphoneUnavailable.listen(unavailable.add);
      try {
        expect(await controller.start(_call()), isTrue);
        if (end == 'stop') {
          await controller.stop();
        } else {
          expect(
            await controller.start(
              _call(callId: end == 'new-call' ? 'new' : 'receive-only-start'),
            ),
            isTrue,
          );
        }
        final calls = first.mutes.length;
        permission.complete(false);
        await pumpEventQueue();
        expect(first.mutes, hasLength(calls));
        expect(unavailable, isEmpty);
        expect(controller.startedWithoutMicrophone, isFalse);
      } finally {
        await controller.stop();
        await sub.cancel();
      }
    });
  }

  test(
    'late successful grant keeps receive active and permits later mute retry',
    () async {
      final permission = Completer<bool>();
      final engine = _Engine(nativeStarted: true, capture: 1);
      final controller = VeilCallMediaController(
        _Transport(),
        engineFactory:
            ({required veilChan, required localId, required peerId}) => engine,
        microphonePermissionFactory: (_) =>
            CallMicrophonePermission(permission.future),
      );
      final unavailable = <String>[];
      final sub = controller.microphoneUnavailable.listen(unavailable.add);
      try {
        expect(await controller.start(_call()), isTrue);
        permission.complete(true);
        await pumpEventQueue();
        expect(engine.mutes.last, isFalse);
        expect(controller.startedWithoutMicrophone, isFalse);
        expect(unavailable, isEmpty);
        expect(await controller.setMicMuted(true), isTrue);
        expect(await controller.setMicMuted(false), isTrue);
      } finally {
        await controller.stop();
        await sub.cancel();
      }
    },
  );
  for (final unmute in [false, true]) {
    test(
      'refused ${unmute ? "unmute" : "mute"} does not reopen capture on route rebuild',
      () async {
        final first = _Engine(nativeStarted: true, capture: 1);
        final replacement = _Engine(nativeStarted: true, capture: 1);
        var creates = 0;
        final controller = VeilCallMediaController(
          _Transport(),
          engineFactory:
              ({required veilChan, required localId, required peerId}) =>
                  creates++ == 0 ? first : replacement,
        );
        try {
          expect(await controller.start(_call()), isTrue);
          if (unmute) expect(await controller.setMicMuted(true), isTrue);
          first.muteAccepted = false;
          expect(await controller.setMicMuted(!unmute), isFalse);
          expect(await controller.start(_call()), isTrue);
          expect(first.disposed, isTrue);
          expect(replacement.mutes.first, isTrue);
        } finally {
          await controller.stop();
        }
      },
    );
  }

  for (final muted in [true, false]) {
    for (final throws in [false, true]) {
      test(
        'mid-call mute=$muted reports device refusal (throws=$throws)',
        () async {
          final engine = _Engine(nativeStarted: true, capture: 1);
          final controller = VeilCallMediaController(
            _Transport(),
            engineFactory:
                ({required veilChan, required localId, required peerId}) =>
                    engine,
          );
          try {
            expect(await controller.start(_call()), isTrue);
            if (!muted) await controller.setMicMuted(true);
            engine.muteAccepted = false;
            engine.throwOnMute = throws;
            // Dynamic dispatch lets the same regression run against the previous
            // void-returning API and demonstrate its missing failure result.
            final dynamic media = controller;
            expect(await media.setMicMuted(muted), isFalse);
            expect(controller.startedWithoutMicrophone, !muted);
            expect(
              engine.disposed,
              isFalse,
              reason: 'working receive audio stays up',
            );
            engine.muteAccepted = true;
            engine.throwOnMute = false;
            expect(await media.setMicMuted(muted), isTrue);
            expect(controller.startedWithoutMicrophone, isFalse);
          } finally {
            await controller.stop();
          }
        },
      );
    }
  }

  test(
    'real controller keeps an audio-only call with working output and failed capture',
    () async {
      final transport = _Transport();
      final engine = _Engine();
      final controller = VeilCallMediaController(
        transport,
        engineFactory:
            ({required veilChan, required localId, required peerId}) => engine,
      );
      try {
        expect(await controller.start(_call()), isTrue);
        expect(controller.startedWithoutMicrophone, isTrue);
        expect(engine.mutes.last, isTrue);
        expect(engine.disposed, isFalse);
      } finally {
        await controller.stop();
      }
      expect(engine.disposed, isTrue);
      expect(transport.closed, [42]);
      expect(controller.startedWithoutMicrophone, isFalse);
    },
  );

  test(
    'receive-only audio survives rejected video startup and deferred admission',
    () async {
      for (final deferred in [false, true]) {
        final engine = _Engine()..rejectVideoAdmission = deferred;
        final controller = VeilCallMediaController(
          _Transport(),
          engineFactory:
              ({required veilChan, required localId, required peerId}) =>
                  engine,
        );
        try {
          expect(await controller.start(_call(video: true)), isTrue);
          expect(controller.startedWithoutMicrophone, isTrue);
          expect(engine.videoStarts, deferred ? 0 : 1);
          expect(engine.pauseAttempts, deferred ? greaterThan(0) : 0);
        } finally {
          await controller.stop();
        }
      }
    },
  );

  test('successful capture keeps the normal microphone posture', () async {
    final engine = _Engine(nativeStarted: true, capture: 1);
    final controller = VeilCallMediaController(
      _Transport(),
      engineFactory: ({required veilChan, required localId, required peerId}) =>
          engine,
    );
    try {
      expect(await controller.start(_call()), isTrue);
      expect(controller.startedWithoutMicrophone, isFalse);
      expect(engine.mutes, [false]);
    } finally {
      await controller.stop();
    }
  });

  test(
    'real controller rejects output failure and refused receive-only mute',
    () async {
      for (final engine in [
        _Engine(playout: 0),
        _Engine(capture: -1),
        _Engine(muteAccepted: false),
      ]) {
        final controller = VeilCallMediaController(
          _Transport(),
          engineFactory:
              ({required veilChan, required localId, required peerId}) =>
                  engine,
        );
        try {
          expect(await controller.start(_call()), isFalse);
          expect(controller.startedWithoutMicrophone, isFalse);
        } finally {
          await controller.stop();
        }
        expect(engine.disposed, isTrue);
      }
    },
  );
}
