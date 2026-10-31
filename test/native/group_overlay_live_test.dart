import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/log.dart' show devLogDirectoryOverride;
import 'package:xveil/crypto/blake3.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/node/ratchet_ffi.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/state/group_service.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/peer_authorization_persistence.dart';

import '../support/timed_native_store.dart';

// Opt-in, local TCP only. Twelve actual embedded nodes, native signatures,
// encrypted containers and the ordinary MessagingService fragmentation/ACK path.
// The group itself uses the supported legacy (no membership epoch) format.
// Native node crypto still seals transport frames. No fixture bypasses ratchet
// persistence, group admission, signature checks or application relay dedup.
//
// GROUP_OVERLAY_LIVE=1 VEIL_FFI_DYLIB=... XVEIL_HV_DYLIB=... \
// GROUP_OVERLAY_EVIDENCE=/private/owner-only/directory \
// TMPDIR=/private/tmp/ flutter test test/native/group_overlay_live_test.dart

Future<int> _port() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

class _Member {
  _Member(this.index, this.identity, this.root, this.lib, this.clock);
  final int index;
  final String identity;
  final Directory root;
  final DynamicLibrary lib;
  final Stopwatch clock;
  NativeTiming? observeSystem;
  StreamSubscription<dynamic>? receiveTap;
  EmbeddedNodeController? controller;
  VeilFlutterTransport? transport;
  HiddenVolumeStorage? storage;
  FfiRatchetStateHandle? nativeRatchet;
  PeerAuthorizationPersistence? peerAuthorization;
  MessagingService? messaging;
  GroupService? groups;
  late NodeId id;
  int port = 0;
  bool sendEnabled = false;
  void Function(String, NodeId, String)? observe;

  Future<void> open() async {
    final dir = Directory('${root.path}/$index')..createSync();
    port = await _port();
    final app = '${dir.path}/a.sock';
    final admin = '${dir.path}/n.sock';
    final config = EmbeddedNode.composeConfig(
      identityToml: identity,
      listenTransport: 'tcp://127.0.0.1:$port',
      ipcSocket: app,
      adminSocket: admin,
      useBundledSeeds: false,
      meetingPoints: const [],
      serveDht: Platform.environment['GROUP_OVERLAY_DHT'] != '0',
      lib: lib,
    );
    controller = EmbeddedNodeController(
      appSocketPath: app,
      starter: () =>
          EmbeddedNode.startDeferred(admin, lib: lib)..applyConfig(config),
    );
    await controller!.start();
    expect(controller!.current.phase, NodePhase.connected);
    final signed = EmbeddedNode.signMessage(identity, Uint8List(0), lib: lib);
    id = NodeId(blake3Hash(signed.publicKey));
    final opener = workerSpaceOpener('${dir.path}/s.hv');
    storage = HiddenVolumeStorage.async(({
      required password,
      required create,
    }) async {
      final inner = await opener(password: password, create: create);
      return inner == null
          ? null
          : TimedNativeStore(
              inner,
              clock,
              (values) => observeSystem?.call(values),
            );
    });
    expect(
      await storage!.open(
        password: 'local-overlay-fixture',
        createIfMissing: true,
      ),
      isTrue,
    );
    nativeRatchet = FfiRatchetStateHandle.connect(app, lib: lib);
    expect(nativeRatchet, isNotNull);
    peerAuthorization = PeerAuthorizationPersistence(
      native: nativeRatchet!,
      storage: storage!,
    );
    peerAuthorization!.restore(await storage!.loadPeerAuthorization());
    peerAuthorization!.start();
    final ratchet = TimedNativeRatchet(
      native: nativeRatchet!,
      storage: storage!,
      peerAuthorization: peerAuthorization,
      clock: clock,
      observe: (values) => observeSystem?.call(values),
    );
    await ratchet.restore();
    transport = await VeilFlutterTransport.connect(app);
    nativeRatchet!.bindPeerAuthorizationEvents(transport!.peerAuthorizationChanges);
    expect(await transport!.nodeId(), id);
    messaging = MessagingService(transport!, storage!, anonymous: false)
      ..ratchet = ratchet;
    groups = GroupService(
      storage!,
      NativeGroupSigner(
        identityToml: identity,
        selfId: id,
        selfPubKey: signed.publicKey,
        lib: lib,
      ),
      send: (peer, gid, json) async {
        if (!sendEnabled) return;
        observe?.call('send_start', peer, json);
        try {
          await messaging!.sendGroupSnapshot(peer, gid.hex, json);
        } finally {
          observe?.call('send_end', peer, json);
        }
      },
      sendSyncResponse: (peer, gid, json) async {
        if (!sendEnabled) return;
        observe?.call('queue_start', peer, json);
        try {
          await messaging!.sendGroupSnapshot(
            peer,
            gid.hex,
            json,
            awaitInitialSend: false,
          );
        } finally {
          observe?.call('queue_end', peer, json);
        }
      },
      activePeers: () async => {
        for (final peer in await transport!.peers())
          if (peer.isActive) peer.nodeId,
      },
    );
    Future<bool> ingest(NodeId peer, String json, bool stranger) async {
      observe?.call('ingress_start', peer, json);
      try {
        return await groups!.receiveGroupFrame(
          peer,
          json,
          fromStranger: stranger,
        );
      } finally {
        observe?.call('ingress_end', peer, json);
      }
    }

    messaging!.onGroupEntry = (peer, json) => ingest(peer, json, false);
    messaging!.onGroupEntryFromStranger = (peer, json) =>
        ingest(peer, json, true);
    messaging!.allowStrangerGroupSync = groups!.allowStrangerGroupSync;
    messaging!.start();
    // AppHandle caches a broadcast controller; this adds a passive observer,
    // not another native receive handler or a second dispatch.
    receiveTap = transport!.messages().listen((message) {
      final envelope = WireEnvelope.decode(message.payload);
      if (envelope.kind == WireKind.groupEntry) {
        observe?.call('transport_rx', message.src, envelope.body);
      }
    });
  }

  Future<String> invite() async {
    final shared = BootstrapInvite.parse(await transport!.createInvite());
    return BootstrapInvite(
      publicKey: shared.publicKey,
      nonce: shared.nonce,
      algo: shared.algo,
      transport: 'tcp://127.0.0.1:$port',
    ).toUri();
  }
}

Future<void> _until(
  Future<bool> Function() ready, {
  required String stage,
  Duration timeout = const Duration(seconds: 120),
}) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < timeout) {
    if (await ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException(stage, timeout);
}

void main() {
  final enabled = Platform.environment['GROUP_OVERLAY_LIVE'] == '1';
  test(
    'twelve native local nodes converge across the XOR split',
    () async {
      final lib = DynamicLibrary.open(Platform.environment['VEIL_FFI_DYLIB']!);
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final evidence = Directory(
        Platform.environment['GROUP_OVERLAY_EVIDENCE']!,
      );
      expect(evidence.existsSync(), isTrue);
      final oldLogDirectory = devLogDirectoryOverride;
      devLogDirectoryOverride = evidence.path;
      final root = await Directory.systemTemp.createTemp('xvgo-');
      final members = <_Member>[];
      final result = <String, Object?>{
        'nodes': 12,
        'product_const_gate': const bool.fromEnvironment('dart.vm.product'),
        'wall_epoch_us': DateTime.now().microsecondsSinceEpoch,
        'host_pid': pid,
        'local_tcp_only': true,
        'public_discovery': false,
        'dht_participation': Platform.environment['GROUP_OVERLAY_DHT'] != '0',
        'membership_epoch_encryption': false,
        'native_signatures': true,
        'encrypted_stores': true,
        'ratchet_persistence': true,
        'peer_authorization_persistence': true,
        'separate_processes': false,
      };
      final samples = <Map<String, Object?>>[];
      final trace = <Map<String, Object?>>[];
      final systemTrace = <Map<String, Object?>>[];
      var timingDropped = 0;
      var activeWindow = -1;
      final subscriptions = <StreamSubscription<dynamic>>[];
      final incoming = <String, Map<int, int>>{};
      final events = <String, int>{};
      final wall = Stopwatch()..start();
      void save() => File('${evidence.path}/native-overlay-result-private.json')
          .writeAsStringSync(
            jsonEncode({
              ...result,
              'samples': samples,
              'trace': trace,
              'system_trace': systemTrace,
              'timing_dropped': timingDropped,
            }),
          );
      try {
        final buckets = [<String>[], <String>[]];
        for (
          var attempt = 0;
          buckets.any((b) => b.length < 6) && attempt < 64;
          attempt++
        ) {
          final cached = File(
            '${evidence.path}/identity-$attempt-private.toml',
          );
          final identity = cached.existsSync()
              ? cached.readAsStringSync()
              : EmbeddedNode.mineConfig(24, lib: lib);
          if (!cached.existsSync()) cached.writeAsStringSync(identity);
          final pub = EmbeddedNode.signMessage(
            identity,
            Uint8List(0),
            lib: lib,
          ).publicKey;
          final bucket = buckets[blake3Hash(pub)[0] >> 7];
          if (bucket.length < 6) bucket.add(identity);
          stderr.writeln(
            jsonEncode({
              'phase': 'identities',
              'ready': buckets[0].length + buckets[1].length,
            }),
          );
        }
        expect(buckets.map((b) => b.length), [6, 6]);
        for (final identity in [...buckets[0], ...buckets[1]]) {
          final member = _Member(members.length, identity, root, lib, wall);
          members.add(member);
          await member.open();
          stderr.writeln(
            jsonEncode({'phase': 'boot', 'ready': members.length}),
          );
        }
        final invites = [for (final member in members) await member.invite()];
        for (var i = 0; i < members.length; i++) {
          for (var j = 0; j < i; j++) {
            await members[i].transport!.joinInvite(invites[j]);
          }
          stderr.writeln(jsonEncode({'phase': 'mesh', 'ready': i + 1}));
        }
        await _until(() async {
          for (final member in members) {
            if ((await member.transport!.peers())
                    .where((p) => p.isActive)
                    .length <
                11) {
              return false;
            }
          }
          return true;
        }, stage: 'local full mesh');
        final owner = members.first;
        final gid = await owner.groups!.createGroup('local overlay');
        for (final member in members.skip(1)) {
          expect(
            await owner.groups!.addControlOp(
              gid,
              ControlOp.addMember,
              target: member.id,
              role: GroupRole.member,
            ),
            isTrue,
          );
        }
        final seed = (await owner.groups!.load(gid))!;
        // Initial membership is provisioned out of band, without a pairwise
        // contact handshake. All measured messages enter over actual TCP/FFI.
        for (final member in members.skip(1)) {
          expect(
            await member.groups!.ingestSnapshot(
              owner.groups!.snapshotJson(seed, recipient: member.id),
            ),
            isTrue,
          );
        }
        for (final member in members) {
          member.sendEnabled = true;
        }
        result['private_node_ids'] = [
          for (final member in members) member.id.hex,
        ];
        final roster = members.map((m) => m.id).toList();
        final old = {
          for (final id in roster)
            id: nearestGroupNodesByXor(
              id,
              roster.where((peer) => peer != id),
              reachable: roster.map((p) => p.hex).toSet(),
            ),
        };
        expect(
          old.entries.where(
            (e) =>
                e.value.any((p) => (p.bytes[0] >> 7) != (e.key.bytes[0] >> 7)),
          ),
          isEmpty,
        );
        final byId = {for (final member in members) member.id: member.index};
        for (final member in members) {
          member.observeSystem = (values) {
            if (activeWindow < 0) return;
            if (systemTrace.length >= 65536) {
              timingDropped++;
              return;
            }
            systemTrace.add({
              ...values,
              'member': member.index,
              'window': activeWindow,
            });
          };
          member.observe = (phase, peer, json) {
            final wire = jsonDecode(json) as Map;
            for (final row in (wire['g'] as List? ?? const [])) {
              final body = row is Map ? row['body'] : null;
              if (body is! String || !body.startsWith('overlay-live-')) {
                continue;
              }
              trace.add({
                'phase': phase,
                'member': member.index,
                'peer': byId[peer],
                'sample': int.parse(body.substring(13)),
                'us': wall.elapsedMicroseconds,
              });
            }
          };
          subscriptions.add(
            member.groups!.incoming.listen((event) {
              final body = event.message.body;
              if (!body.startsWith('overlay-live-')) return;
              incoming.putIfAbsent(body, () => {})[member.index] =
                  wall.elapsedMicroseconds;
              trace.add({
                'phase': 'visible',
                'member': member.index,
                'peer': byId[event.message.author],
                'sample': int.parse(body.substring(13)),
                'us': wall.elapsedMicroseconds,
              });
              events.update(
                '$body|${member.index}',
                (n) => n + 1,
                ifAbsent: () => 1,
              );
            }),
          );
        }
        for (final sourceIndex in [0, 6, 5, 11]) {
          final source = members[sourceIndex];
          final body = 'overlay-live-${samples.length}';
          activeWindow = samples.length;
          final started = wall.elapsedMicroseconds;
          expect(await source.groups!.postMessage(gid, body), isTrue);
          await _until(() async {
            for (final member in members) {
              if (!(await member.groups!.messagesOf(
                gid,
              )).any((m) => m.body == body)) {
                return false;
              }
            }
            return true;
          }, stage: 'message convergence');
          final visible = <int, int>{sourceIndex: 0};
          for (final member in members) {
            final rows = await member.groups!.messagesOf(gid);
            expect(rows.where((m) => m.body == body), hasLength(1));
            if (member != source) {
              final stamp = incoming[body]?[member.index];
              expect(stamp, isNotNull);
              visible[member.index] = (stamp! - started) ~/ 1000;
              expect(events['$body|${member.index}'], 1);
            }
          }
          samples.add({
            'source_index': sourceIndex,
            'started_us': started,
            'visible_ms': visible.map((k, v) => MapEntry('$k', v)),
          });
          save();
          stderr.writeln(
            jsonEncode({
              'phase': 'message',
              'completed': samples.length,
              'max_visible_ms': visible.values.reduce((a, b) => a > b ? a : b),
            }),
          );
        }
        result['converged'] = true;
      } finally {
        activeWindow = -1;
        for (final member in members) {
          await member.receiveTap?.cancel();
        }
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        final cleanupErrors = <String>[];
        Future<void> clean(String category, Future<void> Function() f) async {
          try {
            await f().timeout(const Duration(seconds: 30));
          } catch (_) {
            cleanupErrors.add(category);
          }
        }

        for (final member in members) {
          await clean('messaging', () async => member.messaging?.dispose());
          await clean('groups', () async => member.groups?.dispose());
        }
        for (final member in members.reversed) {
          await clean('transport', () async => member.transport?.dispose());
          await clean(
            'peer-authorization',
            () async => member.peerAuthorization?.close(),
          );
          member.nativeRatchet?.close();
          await clean('controller', () async => member.controller?.stop());
          await clean('storage', () async => member.storage?.close());
        }
        var releasedPorts = 0;
        for (final member in members) {
          if (member.port == 0) continue;
          await clean('listener', () async {
            final probe = await ServerSocket.bind(
              InternetAddress.loopbackIPv4,
              member.port,
            );
            releasedPorts++;
            await probe.close();
          });
        }
        result['released_listeners'] = releasedPorts;
        result['cleanup_errors'] = cleanupErrors;
        result['nodes_stopped'] = members.every(
          (m) =>
              m.controller == null ||
              m.controller!.current.phase == NodePhase.stopped,
        );
        result['completed_samples'] = samples.length;
        save();
        if (cleanupErrors.isEmpty) await root.delete(recursive: true);
        expect(cleanupErrors, isEmpty);
        devLogDirectoryOverride = oldLogDirectory;
        expect(result['nodes_stopped'], isTrue);
      }
    },
    skip: enabled
        ? false
        : 'set GROUP_OVERLAY_LIVE=1 and both native libraries',
    timeout: const Timeout(Duration(minutes: 25)),
  );
}
