// Opt-in physical-camera integration. No application window or user profile.
// Requires a verified media DLL and the synthetic 42/43 callback transport shim.
import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
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

class _LoopbackChannel implements VeilFlutterTransport {
  final closed = <int>[];
  @override
  Future<NodeId> peerFacingNodeId({
    Duration timeout = const Duration(seconds: 2),
  }) async => _id(1);
  @override
  Future<int> openMediaChannel(
    Uint8List peer, {
    required Uint8List txKey,
    required Uint8List rxKey,
    bool direct = false,
    bool relay = false,
  }) async => 42;
  @override
  bool get supportsCallControl => false;
  @override
  bool hasCallControl(int channel) => false;
  @override
  Future<bool> configureMediaRouteProbes(
    int channel, {
    required NodeId directPeer,
    required NodeId relayPeer,
  }) async => true;
  @override
  Map<String, int>? mediaChannelStats(int channel) => const {};
  @override
  int mediaRecvCount(Uint8List peer) => 0;
  @override
  int setMediaScreenSharing(int channel, bool enabled) => 0;
  @override
  void closeMediaChannel(int channel) => closed.add(channel);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _until(bool Function() condition) async {
  final deadline = Stopwatch()..start();
  while (!condition()) {
    if (deadline.elapsed > const Duration(seconds: 12)) {
      fail('Native video did not progress within the stand deadline');
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

void main() {
  const enabled = bool.fromEnvironment('XVEIL_NATIVE_WINDOWS_CAMERA_TEST');
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final direct in [false, true]) {
    test(
      'real Windows engine reaches application preview and codec (direct=$direct)',
      () async {
        // The global plugin backend is replaced by an in-memory store before any
        // profile preference access. Only synthetic device-selection state is used.
        SharedPreferences.setMockInitialValues({});
        final stubPath = Platform.environment['XVEIL_CAMERA_STUB_DLL'];
        expect(stubPath, isNotNull);
        // Refuse a real core: the explicitly synthetic shim owns channels 42/43.
        final stub = DynamicLibrary.open(stubPath!);
        final packetCount = stub
            .lookupFunction<Int64 Function(), int Function()>(
              'probe_packet_count',
            );
        final packetsBefore = packetCount();
        final channel = _LoopbackChannel();
        VeilMediaEngine? sender;
        final controller = VeilCallMediaController(
          channel,
          engineFactory:
              ({required veilChan, required localId, required peerId}) {
                sender = VeilMediaEngine.create(
                  veilChan: veilChan,
                  localId: localId,
                  peerId: peerId,
                );
                return sender;
              },
        );
        VeilMediaEngine? receiver;
        var localFrames = 0;
        var remoteFrames = 0;
        void onLocal() {
          if (localVideoFrame.value != null) localFrames++;
        }

        localVideoFrame.addListener(onLocal);
        try {
          receiver = VeilMediaEngine.create(
            veilChan: 43,
            localId: _id(2).bytes,
            peerId: _id(1).bytes,
          );
          expect(receiver, isNotNull);
          expect(receiver!.startVideo(send: false, recv: true), isTrue);
          final call = Call(
            callId: 'camera-native-application-control',
            peer: _id(2),
            direction: CallDirection.outgoing,
            media: const CallMedia(audio: true, video: true),
            status: CallStatus.connecting,
            localPosture: direct ? CallPosture.direct : CallPosture.anonymous,
            peerPosture: direct ? CallPosture.direct : CallPosture.anonymous,
            transport: direct ? CallTransportKind.p2p : CallTransportKind.onion,
            startedAt: DateTime.utc(2026, 11, 16),
            // The synthetic peer receives video but captures neither medium.
            peerCapture: const CallMedia(audio: false, video: false),
            micOn: false,
            cameraOn: true,
            localMediaKey: generateCallMediaKeyContribution(),
            peerMediaKey: generateCallMediaKeyContribution(),
          );
          expect(await controller.start(call), isTrue);
          expect(controller.startedWithoutCamera, isFalse);
          await _until(() {
            if (receiver!.getVideoFrame() != null) remoteFrames++;
            return localFrames >= 10 && remoteFrames >= 10;
          });
          final firstLocal = localFrames;
          final firstRemote = remoteFrames;
          await controller.setCameraEnabled(false);
          await controller.setCameraEnabled(true);
          expect(controller.startedWithoutCamera, isFalse);
          await _until(() {
            if (receiver!.getVideoFrame() != null) remoteFrames++;
            return localFrames >= firstLocal + 10 &&
                remoteFrames >= firstRemote + 10;
          });
          expect(sender!.getStats()['mic_muted'], 1);
          expect(sender!.getStats()['camera_capturing'], 1);
          expect(packetCount(), greaterThan(packetsBefore));
          // Counts and dimensions only. No device IDs, labels or image/audio data.
          // ignore: avoid_print -- numeric stand result only.
          print(
            jsonEncode({
              'applicationPreviewFrames': localFrames,
              'directProfile': direct,
              'remoteDecodedFrames': remoteFrames,
              'previewWidth': localVideoFrame.value!.width,
              'previewHeight': localVideoFrame.value!.height,
              'restartProgress': true,
              'nativePackets': packetCount() - packetsBefore,
              'microphoneMuted': true,
            }),
          );
        } finally {
          localVideoFrame.removeListener(onLocal);
          await controller.stop();
          receiver?.dispose();
        }
        expect(channel.closed, [42]);
        expect(localVideoFrame.value, isNull);
      },
      skip: !Platform.isWindows || !enabled
          ? 'Opt-in Windows physical camera control'
          : false,
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }
}
