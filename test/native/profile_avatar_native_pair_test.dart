// Opt-in real SDK, two fresh sovereign identities, private loopback QUIC.
// No fake transport/inbound injection or production relay configuration.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/log.dart';
import 'package:xveil/data/identity/veil_identity.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/data/transport/veil_native.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/data/veil_stack.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/profile_avatar.dart';
import 'package:xveil/state/messaging_core.dart';
import 'package:xveil/state/ratchet_persistence.dart';

Future<int> _port({bool udp = false}) async {
  if (udp) {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final port = socket.port;
    socket.close();
    return port;
  }
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Uint8List _picture(int color) {
  final pixels = image.Image(width: 48, height: 48);
  image.fill(pixels, color: image.ColorRgb8(color, 70, 255 - color));
  return encodeAvatarPixels(image.encodePng(pixels))!;
}

class _Peer {
  _Peer(this.root, this.lib, this.profileLabels, this.clock);
  final Map<String, int> profileLabels;
  final Stopwatch clock;
  final frameEvidence = <Map<String, Object>>[];
  final Directory root;
  final DynamicLibrary lib;
  final listenPorts = <int>[];
  final metricPorts = <int>[];
  HiddenVolumeStorage? storage;
  RealVeilStack? stack;
  MessagingService? messaging;
  StreamSubscription<InboundMessage>? tap;
  late NodeId id;
  int profileFrames = 0, authenticatedProfileFrames = 0;
  int savedRatchetKeys = 0;

  VeilFlutterTransport get transport =>
      stack!.transport as VeilFlutterTransport;

  Future<void> open({bool fresh = false}) async {
    await root.create(recursive: true);
    storage ??= HiddenVolumeStorage.async(
      workerSpaceOpener('${root.path}/store.hv'),
    );
    expect(
      await storage!.open(
        password: 'native-avatar-fixture',
        createIfMissing: fresh,
      ),
      isTrue,
    );
    final phrase = fresh ? veilGeneratePhrase() : null;
    if (fresh) expect(phrase, isNotNull);
    final metrics = await _port();
    metricPorts.add(metrics);
    stack = await RealVeilStack.startDeniable(
      storage: storage!,
      runtimeDirBase: '${root.path}/runtime',
      lib: lib,
      listenPort: await _port(udp: true),
      debugMetricsPort: metrics,
      identityPhrase: phrase,
      useBundledSeeds: false,
      meetingPoints: const [],
      anonymous: false,
    );
    listenPorts.add(stack!.listenPort);
    expect(stack!.controller.current.phase, NodePhase.connected);
    // The transport's nodeId names this DEVICE. Contacts address the sovereign
    // identity from the public invite/document, as in the GUI boot bindings.
    id = stack!.myInvite.nodeId;
    final encoded = await readSovereignMaterial(storage!);
    expect(encoded, isNotNull);
    final files = decodeSovereignIdentity(encoded!);
    expect(files!.keys, containsAll(kRequiredSovereignIdentityFiles));
    expect(
      EmbeddedNode.identityDocumentNodeId(
        files[kIdentityDocumentFile]!,
        lib: lib,
      ),
      id.bytes,
    );
    transport.identityAddress = id.bytes;
    expect(await transport.peerFacingNodeId(), id);
    expect(stack!.peerAuthorization, isNotNull);
    final ratchet = ratchetPersistenceFor(stack, storage!);
    expect(ratchet, isNotNull);
    // The production stack already restores authorization and ratchet state
    // before connecting the application. Do not import a second time here.
    messaging = MessagingService(transport, storage!, anonymous: false)
      ..ratchet = ratchet
      ..selfIdentityHex = () async => id.hex;
    tap = transport.messages().listen((message) {
      final envelope = WireEnvelope.decode(message.payload);
      if (envelope.kind == WireKind.profileAvatar) {
        profileFrames++;
        if (message.provenance.isAuthenticated) authenticatedProfileFrames++;
        if (frameEvidence.length < 64) {
          frameEvidence.add({
            'elapsed_ms': clock.elapsedMilliseconds,
            'profile': envelope.body == '?'
                ? 0
                : (profileLabels[envelope.body] ?? -1),
            'provenance': message.provenance.name,
          });
        }
      }
    });
    messaging!.start();
  }

  Future<void> close() async {
    final errors = <String>[];
    Future<void> leg(String label, Future<void> Function() action) async {
      try {
        await action().timeout(const Duration(seconds: 30));
      } catch (_) {
        errors.add(label);
      }
    }

    await leg('messaging', () async => messaging?.dispose());
    await leg('ratchet snapshot', () async {
      if (storage != null) {
        savedRatchetKeys = (await storage!.ratchetConversationKeys()).length;
      }
    });
    await leg('tap', () async => tap?.cancel());
    final closing = stack;
    await leg('stack', () async => closing?.dispose());
    if (closing != null) {
      expect(closing.controller.current.phase, NodePhase.stopped);
    }
    await leg('storage', () async => storage?.close());
    messaging = null;
    stack = null;
    tap = null;
    expect(errors, isEmpty);
    final runtime = Directory('${root.path}/runtime');
    if (await runtime.exists()) expect(await runtime.list().toList(), isEmpty);
  }
}

Future<void> _until(Future<bool> Function() ready, String stage) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(seconds: 90)) {
    if (await ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException(stage);
}

void main() {
  final enabled = Platform.environment['XVEIL_AVATAR_PAIR_NATIVE'] == '1';
  test(
    'sovereign peers exchange avatars and resume after a native restart',
    () async {
      final root = await Directory.systemTemp.createTemp('xv-avatar-pair-');
      await File('${root.path}/owner.pid').writeAsString('$pid');
      final oldLog = devLogDirectoryOverride;
      devLogDirectoryOverride = root.path;
      final libPath = Platform.environment['VEIL_FFI_DYLIB']!;
      expect(ensureVeilClientLoaded(dylibPath: libPath), isTrue);
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final lib = DynamicLibrary.open(libPath);
      final clock = Stopwatch()..start();
      final profileLabels = <String, int>{};
      final peers = [
        for (var i = 0; i < 2; i++)
          _Peer(Directory('${root.path}/$i'), lib, profileLabels, clock),
      ];
      void stage(String label) => stderr.writeln(
        jsonEncode({
          'avatar_native_stage': label,
          'elapsed_ms': clock.elapsedMilliseconds,
        }),
      );
      var completed = false;
      try {
        for (var i = 0; i < peers.length; i++) {
          stage('opening-$i');
          await peers[i].open(fresh: true);
        }
        final a = peers[0], b = peers[1];
        expect(a.id, isNot(b.id));
        final aRaw = await a.messaging!.setSelfAvatar(_picture(30));
        final bRaw = await b.messaging!.setSelfAvatar(_picture(210));
        profileLabels[aRaw] = 1;
        profileLabels[bRaw] = 2;
        stage('connecting');
        await b.transport.joinInvite(await a.transport.createInvite());
        await _until(
          () async =>
              (await a.transport.peers()).any((p) => p.isActive) &&
              (await b.transport.peers()).any((p) => p.isActive),
          'carrier',
        );
        await a.messaging!.sendRequest(b.id, 'native-avatar-contact');
        await _until(
          () async =>
              (await b.storage!.getContact(a.id))?.status ==
              ContactStatus.pendingIncoming,
          'contact request',
        );
        await b.messaging!.acceptContact(a.id);
        await _until(
          () async =>
              (await a.storage!.getContact(b.id))?.status ==
              ContactStatus.accepted,
          'contact acceptance',
        );
        stage('requesting');
        await Future.wait([
          a.messaging!.requestPeerAvatar(b.id),
          b.messaging!.requestPeerAvatar(a.id),
        ]);
        await _until(
          () async =>
              await a.messaging!.loadAvatar(peer: b.id) == bRaw &&
              await b.messaging!.loadAvatar(peer: a.id) == aRaw,
          'initial avatars',
        );
        stage('initial-avatars');
        final updated = await a.messaging!.setSelfAvatar(_picture(120));
        profileLabels[updated] = 3;
        await a.messaging!.announceSelfAvatar();
        await _until(
          () async => await b.messaging!.loadAvatar(peer: a.id) == updated,
          'updated avatar',
        );
        final cleared = await b.messaging!.setSelfAvatar(null);
        profileLabels[cleared] = 4;
        await b.messaging!.announceSelfAvatar();
        await _until(
          () async => await a.messaging!.loadAvatar(peer: b.id) == cleared,
          'cleared avatar',
        );
        expect(ProfileAvatar.decode(cleared)!.bytes, isNull);
        stage('update-and-clear');
        final bId = b.id;
        await b.close();
        expect(b.savedRatchetKeys, greaterThan(0));
        stage('reopening');
        await b.open();
        expect(b.id, bId);
        expect(await b.messaging!.loadAvatar(), cleared);
        expect(await b.messaging!.loadAvatar(peer: a.id), updated);
        expect(
          (await b.storage!.getContact(a.id))?.status,
          ContactStatus.accepted,
        );
        await b.transport.joinInvite(await a.transport.createInvite());
        await _until(
          () async => (await b.transport.peers()).any((p) => p.isActive),
          'reconnected carrier',
        );
        final afterRestart = await a.messaging!.setSelfAvatar(_picture(170));
        profileLabels[afterRestart] = 5;
        stage('announcing-after-restart');
        final receivedBefore = b.profileFrames;
        await a.messaging!.announceSelfAvatar();
        await _until(
          () async => b.profileFrames > receivedBefore,
          'first avatar frame after restart',
        );
        final firstPush = b.frameEvidence.lastWhere(
          (row) => row['profile'] == 5,
        );
        if (firstPush['provenance'] == SenderProvenance.claimed.name) {
          expect(
            await b.messaging!.loadAvatar(peer: a.id),
            updated,
            reason: 'a cold unproven push must not change the cached avatar',
          );
        }
        int signedNewValues() => b.frameEvidence
            .where(
              (row) =>
                  row['profile'] == 5 &&
                  row['provenance'] == SenderProvenance.signed.name,
            )
            .length;
        final repliesBefore = signedNewValues();
        stage('pulling-after-restart');
        // Opening a mounted IdentityAvatar requests its peer's current value.
        // Do not count the earlier push/cache hit as this request's answer.
        await b.messaging!.requestPeerAvatar(a.id);
        await _until(
          () async =>
              signedNewValues() > repliesBefore &&
              await b.messaging!.loadAvatar(peer: a.id) == afterRestart,
          'authenticated requested avatar after restart',
        );
        await a.messaging!.sendText(b.id, 'native-avatar-restart-control');
        final controls = (await a.storage!.loadMessages(
          b.id.hex,
        )).where((m) => m.body == 'native-avatar-restart-control').toList();
        expect(controls, hasLength(1));
        final textId = controls.single.id;
        await _until(
          () async =>
              (await b.storage!.loadMessages(a.id.hex))
                  .where(
                    (m) =>
                        m.id == textId &&
                        m.body == 'native-avatar-restart-control',
                  )
                  .length ==
              1,
          'message after restart',
        );
        for (final peer in peers) {
          expect(peer.profileFrames, greaterThan(0));
          expect(peer.authenticatedProfileFrames, greaterThan(0));
        }
        stage('passed');
        completed = true;
      } finally {
        final cleanupErrors = <String>[];
        for (final peer in peers.reversed) {
          try {
            await peer.close();
          } catch (_) {
            cleanupErrors.add('peer');
          }
        }
        for (final peer in peers) {
          for (final port in peer.listenPorts.toSet()) {
            try {
              final probe = await RawDatagramSocket.bind(
                InternetAddress.loopbackIPv4,
                port,
              );
              probe.close();
            } catch (_) {
              cleanupErrors.add('quic listener');
            }
          }
          for (final port in peer.metricPorts.toSet()) {
            try {
              final probe = await ServerSocket.bind(
                InternetAddress.loopbackIPv4,
                port,
              );
              await probe.close();
            } catch (_) {
              cleanupErrors.add('metrics listener');
            }
          }
        }
        stderr.writeln(
          jsonEncode({
            'avatar_native_result': completed,
            'profile_frames': [for (final p in peers) p.profileFrames],
            'authenticated_profile_frames': [
              for (final p in peers) p.authenticatedProfileFrames,
            ],
            'frame_evidence': [for (final p in peers) p.frameEvidence],
            'ratchet_keys': [for (final p in peers) p.savedRatchetKeys],
            'cleanup_errors': cleanupErrors,
          }),
        );
        if (cleanupErrors.isEmpty) await root.delete(recursive: true);
        devLogDirectoryOverride = oldLog;
        expect(cleanupErrors, isEmpty);
      }
    },
    skip: enabled
        ? false
        : 'set XVEIL_AVATAR_PAIR_NATIVE=1 and both native libraries',
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
