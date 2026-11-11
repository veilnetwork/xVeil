import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:veil_media/veil_media.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/veil_call_media.dart';
import 'package:xveil/state/call_microphone_state.dart';

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
  }) async => 42;
  @override
  bool get supportsCallControl => false;
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
  }) async {
    opened.complete();
    return 42;
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
}) => Call(
  callId: callId,
  peer: peer ?? _id(2),
  direction: CallDirection.incoming,
  media: CallMedia(audio: true, video: video),
  status: CallStatus.connecting,
  localPosture: CallPosture.anonymous,
  peerPosture: CallPosture.anonymous,
  transport: CallTransportKind.onion,
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

class _CameraChoiceEngine extends _UpgradeEngine {
  final cameraStarts = <String?>[];
  String? activeCamera;
  String? rejected;
  bool throwOnRejected = false;
  bool stopAccepted = true;
  bool rejectAll = false;
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
    entered.complete();
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
