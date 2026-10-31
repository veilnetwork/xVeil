import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_media/veil_media.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/veil_call_media.dart';

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

class _Engine implements VeilMediaEngine {
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

Call _call({bool video = false}) => Call(
  callId: 'receive-only-start',
  peer: _id(2),
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
