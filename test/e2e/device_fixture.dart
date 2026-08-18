/// App-level DEVICES, in one Dart process, over the local relay island.
///
/// ## What a device is here
///
/// The same objects the app runs, composed the way the app composes them: a
/// deniable container, a real embedded veil node (`RealVeilStack.startDeniable`
/// — FFI, not a spawned `veil-cli`), and a real Riverpod container reading the
/// project's OWN providers. Nothing in this file re-implements messaging, group
/// folding, device sync or the mirror; it starts the real ones.
///
/// That last part is the whole reason this is a `ProviderContainer` and not a
/// [HeadlessRuntime]. The daemon composes a stack too — and it is a genuinely
/// real one — but the multi-device MIRROR (`msgMirror` emit + apply) and the
/// device-sync bridge are wired in `lib/state/group_service_providers.dart`,
/// inside `groupServiceProvider`, and nowhere else. A harness built on
/// `HeadlessRuntime` would bring up two real nodes that never mirror anything
/// to each other, and every case in this suite would fail — or worse, a
/// hand-written mirror in the harness would make them pass while the app's own
/// mirror was broken. The project has paid for that shape twice already (the
/// fake was green while the junction was inert; the fake contradicted the real
/// contract).
///
/// ## The one seam
///
/// [_E2eAppController] replaces `AppController.build()` so the session is
/// "already unlocked as this identity" instead of running the onboarding /
/// preferences boot. It is a stand-in for the USER, not for any mechanism: the
/// fixture opens the container and starts the node itself, exactly as the
/// controller's unlock path would, and every provider downstream —
/// `groupSignerProvider`, `messagingServiceProvider`, `groupServiceProvider`,
/// the mirror, the device-sync bridge — is the real one, reading real state.
///
/// ## Identity material is cached, not minted per run
///
/// veil's anti-sybil PoW is ~45 wall-seconds and ~12 CPU-minutes per identity
/// at the canonical difficulty, and the node refuses to run below it. Four
/// devices would be three minutes of mining before the first assertion. So the
/// identity TOMLs live in `test/e2e/fixtures/` and are minted on first miss.
/// This also keeps the suite off the stand's worst trap: minting fresh
/// identities from one host repeatedly is what the anti-abuse ladder is FOR,
/// and it escalates.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/identity_config_fields.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/device_link_invite.dart';
import 'package:xveil/data/veil_stack.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/messaging_core.dart';
import 'package:xveil/state/messaging_providers.dart';
import 'package:xveil/state/providers.dart';

import 'convergence_oracle.dart';
import 'e2e_env.dart';
import 'relay_cluster.dart';

/// The identity a device belongs to. Two devices of one [E2eIdentity] are
/// siblings; two of different ones are strangers who must exchange contacts.
class E2eIdentity {
  const E2eIdentity({required this.label, required this.phrase});

  final String label;

  /// The master phrase. COMMITTED, because the node identity of the first
  /// device is derived from it and that derivation is the expensive part: a
  /// random phrase per run would re-mine every time and the cached TOML would
  /// never match.
  ///
  /// Test-only, obviously. It names an identity that exists only on a loopback
  /// island.
  final String phrase;

  /// Identity X — devices A (master) and B (sibling).
  static const x = E2eIdentity(
    label: 'X',
    phrase: 'vital write maple stamp arrest nominee shaft bitter intact '
        'distance damage banner seat inspire awful robot depend cream '
        'universe same throw bacon exotic aerobic',
  );

  /// Identity Y — devices C (master) and D (sibling).
  static const y = E2eIdentity(
    label: 'Y',
    phrase: 'civil quarter abuse shell buddy laugh surface isolate same '
        'scout alter lottery term autumn viable initial theory hurt '
        'prepare report crawl riot galaxy vocal',
  );
}

/// The AppController seam. See the library doc: it stands in for the user
/// having unlocked this identity, and for nothing else.
class _E2eAppController extends AppController {
  _E2eAppController(this._identity);

  final Identity _identity;

  @override
  AppState build() => AppState(AppPhase.ready, identity: _identity);
}

/// One BOOT of a device, and the zone its asynchronous work runs in.
///
/// Why a zone. `groupServiceProvider` kicks off maintenance passes from its
/// own body (`startSpaceLifecycleMaintenance` and friends) with `unawaited`,
/// and those passes read storage. Taking a device DOWN disposes the providers
/// and closes the container, so a pass already in flight lands on a closed
/// container and throws "storage is locked" out of a future nobody awaits —
/// into the TEST's zone, where it fails whatever case happens to be running.
///
/// That error is a fact about a device that no longer exists, so this zone
/// keeps it: after [alive] goes false, a late error is LOGGED. While the boot
/// is alive every error is forwarded untouched, because an error from a
/// running device is exactly what a case must fail on.
class _BootScope {
  _BootScope(this.label) {
    zone = Zone.current.fork(
      specification: ZoneSpecification(
        handleUncaughtError: (self, parent, zone, error, stackTrace) {
          if (alive) {
            parent.handleUncaughtError(zone, error, stackTrace);
            return;
          }
          E2eLog.line(
            'device $label: late async error from a boot that is already '
            'down (ignored): $error',
          );
        },
      ),
    );
  }

  final String label;
  late final Zone zone;
  bool alive = true;
}

/// One app-level device.
class E2eDevice {
  E2eDevice._({
    required this.label,
    required this.identity,
    required this.dir,
    required this.password,
    required this.identityToml,
    required this.isMaster,
    required this.cluster,
    required this.dylibPath,
  });

  /// 'A', 'B', 'C', 'D'.
  final String label;

  /// Which identity this device belongs to.
  final E2eIdentity identity;

  final Directory dir;
  final String password;

  /// This device's own node identity TOML — pre-seeded into the container so
  /// the boot never mines.
  final String identityToml;

  /// Whether this device holds the identity's MASTER material (derived from the
  /// phrase). Exactly one device per identity does; the other is adopted.
  final bool isMaster;

  final RelayCluster cluster;
  final String dylibPath;

  _BootScope? _boot;
  ProviderContainer? _container;
  HiddenVolumeStorage? _storage;
  RealVeilStack? _stack;
  NodeId? _nodeId;
  NodeId? _identityId;

  bool get up => _container != null;

  ProviderContainer get container => _requireUp(_container, 'container');
  HiddenVolumeStorage get storage => _requireUp(_storage, 'storage');
  RealVeilStack get stack => _requireUp(_stack, 'stack');

  /// Run [body] IN THIS BOOT'S ZONE — used for every provider read.
  ///
  /// Not a nicety. A `read` can build the provider, and building
  /// `groupServiceProvider` starts maintenance passes with `unawaited`. Read
  /// from the test's zone, those passes belong to the TEST: when the device is
  /// later taken down and its container closes, the pass in flight throws
  /// "storage is locked" into whatever case is running — measured here as case
  /// 20 failing on a teardown race after all of its own assertions had passed.
  /// Read through the boot's zone, they belong to the boot, and [_BootScope]
  /// discards them once that boot is over.
  T inZone<T>(T Function() body) {
    final boot = _boot;
    return boot == null ? body() : boot.zone.run(body);
  }

  MessagingService get messaging =>
      inZone(() => container.read(messagingServiceProvider));

  /// The real [GroupService] built by `groupServiceProvider`, with the mirror
  /// and the device-sync bridge attached. Null before the signer resolves.
  GroupService? get groups => inZone(() => container.read(groupServiceProvider));

  /// This DEVICE's transport node id — not the identity's. Confusing the two
  /// is the single most repeated defect class in this campaign's history, so
  /// the fixture keeps both and names them apart.
  NodeId get deviceNodeId => _requireUp(_nodeId, 'device node id');

  /// The IDENTITY's address — what a contact writes down and what a sibling
  /// shares. Equal to [deviceNodeId] only on a device with no sovereign
  /// identity behind it.
  NodeId get identityNodeId => _requireUp(_identityId, 'identity node id');

  T _requireUp<T>(T? value, String what) {
    if (value == null) {
      throw StateError('device $label is DOWN — no $what. A case that stops a '
          'device must bring it back up before asking it anything.');
    }
    return value;
  }

  T _fail<T>(String message) => throw StateError('device $label: $message');

  /// Boot this device: open its container, seed the node identity if the
  /// container is new, start the real stack, build the real providers.
  Future<void> start() async {
    if (_container != null) return;
    final boot = _BootScope(label);
    _boot = boot;
    await E2eLog.step('device $label: boot', () => boot.zone.run(() async {
      await Directory('${dir.path}/blobs').create(recursive: true);
      await Directory('${dir.path}/runtime').create(recursive: true);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['700', '${dir.path}/runtime']);
      }

      final storage = HiddenVolumeStorage.async(
        workerSpaceOpener('${dir.path}/store.hv'),
      )..useOnDiskTier(Directory('${dir.path}/blobs'));
      if (!await storage.open(password: password, createIfMissing: true)) {
        _fail('could not unlock its container');
      }
      _storage = storage;
      // Pre-seed, exactly like `public_space_discovery_live_test`: with a
      // config already in the container, `ensureNodeConfig` never mines.
      if (await storage.loadNodeConfig() == null) {
        await storage.saveNodeConfig(identityToml);
      }

      final stack = await RealVeilStack.startDeniable(
        storage: storage,
        runtimeDirBase: '${dir.path}/runtime',
        lib: DynamicLibrary.open(dylibPath),
        listenPort: await freePort(),
        anonymous: false,
        bootstrapPeers: cluster.bootstrapPeers,
        // Several embedded nodes in one process, each with its own metrics
        // port. A fixed one is why a second instance used to die on "Address
        // already in use" with no port in the message.
        debugMetricsPort: await freePort(),
        // The master device provisions its sovereign material from the phrase;
        // a sibling has none until the link ceremony delegates it one.
        identityPhrase: isMaster ? identity.phrase : null,
        // NEVER the shared seeds. Same rule as the relay island, on the other
        // side of the wire.
        useBundledSeeds: false,
      );
      _stack = stack;
      _nodeId = _deviceIdOf(identityToml);
      _identityId = stack.myInvite.nodeId;

      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer(
        overrides: [
          singleSpaceStorageProvider.overrideWithValue(storage),
          appControllerProvider.overrideWith(
            () => _E2eAppController(Identity(nodeId: _identityId!)),
          ),
          // The mailbox relay candidates come from here — without it a device
          // has live delivery only, and every offline case in this suite is
          // about the mailbox.
          deniableBootProvider.overrideWithValue(
            DeniableBootConfig(
              runtimeDir: '${dir.path}/runtime',
              bootstrapPeers: cluster.bootstrapPeers,
            ),
          ),
        ],
      );
      _container = container;
      container.read(realStackProvider.notifier).state = stack;
      // Eager reads, in the order the app builds them: the messaging service
      // starts listening in its constructor, and the group service attaches
      // every callback (mirror included) in its.
      container.read(messagingServiceProvider);
      await container.read(groupSignerProvider.future);
      if (container.read(groupServiceProvider) == null) {
        _fail('groupServiceProvider stayed null — no signer could be built '
            'from the stored identity config');
      }

      // ON THE ISLAND, not merely started. A node that has not yet dialled a
      // relay looks identical to one that has, right up until the first send
      // sits in an outbox — and the wait that then fails is the CASE's wait,
      // which reports "B never mirrored the message" for what is really "the
      // node was still finding the network". Paid once per boot, here, where
      // the diagnostic says what it actually is.
      await waitUntil(
        () async => (await stack.transport.peers()).any((p) => p.isActive),
        what: 'device $label to have an active peer on the relay island',
        describe: () async {
          final peers = await stack.transport.peers();
          return '${peers.length} peer(s), '
              '${peers.where((p) => p.isActive).length} active';
        },
        timeout: const Duration(minutes: 2),
      );
    }));
  }

  /// Take this device DOWN, the way the campaign's cases mean it: the process
  /// keeps running, this device's node and container do not.
  ///
  /// Deliberately not "pause the network": a stopped device must lose its live
  /// leg AND stop draining its mailbox, or a case that says "B was down"
  /// proves nothing.
  Future<void> stop() async {
    if (_container == null) return;
    await E2eLog.step('device $label: down', () async {
      // FIRST, before anything can throw: from here on, work this boot started
      // is allowed to fail quietly (see [_BootScope]).
      _boot?.alive = false;
      _boot = null;
      final container = _container;
      final stack = _stack;
      final storage = _storage;
      _container = null;
      _stack = null;
      _storage = null;
      await teardownLegs('device-$label-stop', [
        ('dispose providers', () async => container?.dispose()),
        ('dispose stack', () async => stack?.dispose()),
        ('close container', () async => storage?.close()),
      ]);
    });
  }

  /// Down and up again on the SAME container — a restart, not a fresh device.
  Future<void> restart() async {
    await stop();
    await start();
  }

  /// This device's link invite: its OWN device key plus the identity document
  /// it currently holds.
  ///
  /// Mirrors `_deviceInviteHook`. Not `stack.myInvite`, which carries the
  /// IDENTITY's key — every device of an identity produces the same string from
  /// that one, so the ceremony could neither tell two devices apart nor address
  /// one of them.
  Future<DeviceLinkInvite> deviceLinkInvite() async {
    final fields = identityConfigFields(identityToml);
    if (fields == null) _fail('its own identity config will not parse');
    return DeviceLinkInvite(
      device: BootstrapInvite(
        publicKey: fields!.publicKey,
        nonce: fields.nonce,
        algo: fields.algo,
      ),
      document: await RealVeilStack.storedSovereignDocument(storage),
    );
  }

  /// The transport URI this device's node is actually listening on.
  ///
  /// Every node in this suite is on ONE host, so this is always loopback.
  String get dialUri => '${stack.listenScheme}://127.0.0.1:${stack.listenPort}';

  /// This device's contact invite WITH a direct-dial hint.
  ///
  /// `RealVeilStack.myInvite` deliberately carries no `t=`: a loopback address
  /// in an invite that leaves the machine is worse than useless, so a node
  /// whose only listener is 127.0.0.1 publishes an identity-only invite and is
  /// reached over the rendezvous by node id. That is correct for the product
  /// and slow and variable here — the cold onion path between two strangers on
  /// a fresh island was measured at 13 s once and over 90 s the next time.
  ///
  /// On a single-host stand the operator's own recipe is to paste the invite
  /// and append `&t=tcp://127.0.0.1:<listen>`, which is exactly what this is.
  /// It does not bypass anything the cases are about: consent, mirroring,
  /// mailbox deposits and the fold all run unchanged. It only lets two nodes
  /// that are in the same process tree find each other by the shortest route
  /// they really have.
  BootstrapInvite dialableContactInvite() => BootstrapInvite(
    publicKey: stack.myInvite.publicKey,
    nonce: stack.myInvite.nonce,
    algo: stack.myInvite.algo,
    transport: dialUri,
  );

  /// The same hint on this device's OWN key rather than the identity's — what
  /// the link ceremony addresses.
  Future<BootstrapInvite> dialableDeviceInvite() async {
    final link = await deviceLinkInvite();
    return BootstrapInvite(
      publicKey: link.device.publicKey,
      nonce: link.device.nonce,
      algo: link.device.algo,
      transport: dialUri,
    );
  }

  /// Read this device's state for the oracle.
  ///
  /// [conversationPeer] adds the 1:1 conversation with that peer, which is what
  /// the "exactly once" cases are about. It is optional because the device-group
  /// criterion does not need it and reading it costs a full log scan.
  Future<DeviceStateSnapshot> snapshot({NodeId? conversationPeer}) async {
    final service = groups;
    if (service == null) _fail('has no group service to read');
    final gidHex = await service!.deviceGroupIdHex();
    if (gidHex == null) {
      return DeviceStateSnapshot(
        label: label,
        deviceGroupIdHex: null,
        bundleDigest: 'no-device-group',
        rows: const [],
        conversationMessageIds: conversationPeer == null
            ? const []
            : [
                for (final m in await storage.loadMessages(conversationPeer.hex))
                  m.id,
              ],
        // The identifiers are carried on this branch too. They are what a
        // caller checks across a restart, and an unlinked device is exactly
        // when that check matters — a snapshot that dropped them made the
        // assertion `null == null`, which passes for a device that mints a
        // fresh node key on every boot.
        notes: {
          'deviceNode': deviceNodeId.short,
          'identity': identityNodeId.short,
        },
      );
    }
    final gid = NodeId.fromHex(gidHex);
    final bundle = await service.load(gid);
    final state = await service.stateOf(gid);
    if (bundle == null) {
      _fail('has a device-group pointer $gidHex with no bundle behind it');
    }

    final rows = <RowRef>[
      for (final entry in bundle!.control)
        RowRef(kind: 'ctl', authorHex: entry.author.hex, seq: entry.seq),
      for (final message in bundle.messages)
        RowRef(kind: 'msg', authorHex: message.author.hex, seq: message.seq),
    ];

    // The digest covers the SIGNED, SHARED rows and nothing else. Every field
    // in it is one an author wrote and signed, so it is identical on every
    // device that holds the row. Local fold state (localEpochKeys, receipts,
    // retention cuts) is excluded on purpose — see convergence_oracle.dart.
    final lines = <String>[
      for (final entry in bundle.control)
        'ctl|${entry.author.hex}|${entry.seq}|${entry.op.name}|'
            '${entry.target?.hex ?? ""}|${entry.prevHash}|${entry.createdAtMs}|'
            '${_hex(entry.signature)}',
      for (final message in bundle.messages)
        'msg|${message.author.hex}|${message.seq}|${message.prevHash}|'
            '${message.createdAtMs}|${_bodyDigest(message.body)}|'
            '${_hex(message.signature)}',
    ]..sort();

    return DeviceStateSnapshot(
      label: label,
      deviceGroupIdHex: gidHex,
      bundleDigest: sha256.convert(utf8.encode(lines.join('\n'))).toString(),
      rows: rows,
      memberCount: state?.members.length ?? 0,
      epoch: state?.epoch ?? 0,
      conversationMessageIds: conversationPeer == null
          ? const []
          : [
              for (final m in await storage.loadMessages(conversationPeer.hex))
                m.id,
            ],
      notes: {
        'deviceNode': deviceNodeId.short,
        'identity': identityNodeId.short,
        'controlRows': bundle.control.length,
        'messageRows': bundle.messages.length,
      },
    );
  }

  /// The bodies of a 1:1 conversation, in the storage's own convergent order.
  Future<List<String>> conversation(NodeId peer) async =>
      [for (final m in await storage.loadMessages(peer.hex)) m.body];

  Future<List<Message>> conversationRows(NodeId peer) =>
      storage.loadMessages(peer.hex);

  static NodeId _deviceIdOf(String toml) {
    final fields = identityConfigFields(toml);
    if (fields == null) {
      throw StateError('a cached device identity TOML will not parse');
    }
    return BootstrapInvite(
      publicKey: fields.publicKey,
      nonce: fields.nonce,
      algo: fields.algo,
    ).nodeId;
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// An encrypted row's `body` is a placeholder and its ciphertext lives
  /// elsewhere; hashing the body keeps the digest short and is enough, because
  /// the signature in the same line covers the real content.
  static String _bodyDigest(String body) =>
      sha256.convert(utf8.encode(body)).toString().substring(0, 16);
}

/// The four devices, their island, and the ceremonies that link them.
class E2eFleet {
  E2eFleet._({
    required this.root,
    required this.cluster,
    required this.devices,
  });

  final Directory root;
  final RelayCluster cluster;

  /// Keyed by label: A, B, C, D.
  final Map<String, E2eDevice> devices;

  E2eDevice get a => devices['A']!;
  E2eDevice get b => devices['B']!;
  E2eDevice get c => devices['C']!;
  E2eDevice get d => devices['D']!;

  /// Bring up an island and [labels]' worth of devices.
  ///
  /// Only the devices a case needs are started: a device is a whole veil node
  /// and a whole container, and starting two spare ones doubles the noise in
  /// every log the failure will be read from.
  static Future<E2eFleet> start({
    required E2eGate gate,
    List<String> labels = const ['A', 'B', 'C', 'D'],
  }) async {
    final root = await e2eTempRoot('xveil-e2e-');
    RelayCluster? cluster;
    final devices = <String, E2eDevice>{};
    try {
      cluster = await E2eLog.step(
        'relay island',
        () => RelayCluster.start(
          veilCliPath: gate.veilCli!,
          root: Directory('${root.path}/relays'),
        ),
      );
      for (final label in labels) {
        final spec = _spec(label);
        final device = E2eDevice._(
          label: label,
          identity: spec.identity,
          dir: Directory('${root.path}/$label'),
          password: 'e2e-$label-password',
          identityToml: await _identityToml(spec, gate.veilDylib!),
          isMaster: spec.isMaster,
          cluster: cluster!,
          dylibPath: gate.veilDylib!,
        );
        await device.dir.create(recursive: true);
        devices[label] = device;
      }
      for (final device in devices.values) {
        await device.start();
      }
      return E2eFleet._(root: root, cluster: cluster!, devices: devices);
    } catch (_) {
      // A half-built fleet still holds relay processes, node runtimes and an
      // open container lock. Every one of them poisons the NEXT run, which
      // then fails for a reason that has nothing to do with its own code — so
      // the legs run here rather than in the caller's `addTearDown`, which a
      // throw out of `start` never reaches.
      await teardownLegs('fleet-boot', [
        for (final device in devices.values)
          ('stop ${device.label}', device.stop),
        if (cluster != null)
          ('stop relays', () => cluster!.dispose(removeFiles: false)),
        ('remove $root', () async {
          if (await root.exists()) await root.delete(recursive: true);
        }),
      ]);
      rethrow;
    }
  }

  /// Diagnostics for a failure message: every device's shape plus every
  /// relay's log tail.
  Future<String> diagnostics() async {
    final buffer = StringBuffer();
    for (final device in devices.values) {
      if (!device.up) {
        buffer.writeln('${device.label}: DOWN');
        continue;
      }
      try {
        buffer.writeln('${device.label}: ${await device.snapshot()}');
      } catch (error) {
        buffer.writeln('${device.label}: could not be read: $error');
      }
    }
    buffer.writeln(cluster.diagnostics());
    return buffer.toString();
  }

  Future<void> dispose() async {
    await teardownLegs('fleet', [
      for (final device in devices.values)
        ('stop ${device.label}', device.stop),
      ('stop relays', () => cluster.dispose(removeFiles: false)),
      ('remove $root', () async {
        if (await root.exists()) await root.delete(recursive: true);
      }),
    ]);
  }

  // --- ceremonies -----------------------------------------------------------

  /// `addContact`, minus the one failure that is not one.
  ///
  /// veil's `bootstrap_join` answers `alreadyRegistered` when the peer is
  /// already in the runtime peer-set, and the Dart binding turns that into a
  /// throw. Two of this ceremony's joins hit it legitimately: on a MASTER
  /// device `master_pk == device_pk`, so its contact invite and its device
  /// invite are the same key, and the second join is a re-dial of a peer the
  /// node already has. Rethrows anything else — a join that failed for a real
  /// reason must still stop the ceremony.
  static Future<void> _join(E2eDevice on, BootstrapInvite invite) async {
    try {
      await on.stack.addContact(invite);
    } on StateError catch (error) {
      if (!'$error'.contains('alreadyRegistered')) rethrow;
      E2eLog.line('${on.label}: already had ${invite.nodeId.short} as a peer');
    }
  }

  /// Link [target] into [master]'s identity — the full device-link ceremony.
  ///
  /// A faithful transcription of the stand's three hooks, in their order and
  /// with their fail-closed checks:
  /// `_deviceLinkPrepareHook` → `_deviceAdoptPrepareHook` →
  /// `_deviceSnapshotSendHook` (lib/debug/soak_hook.dart). Those hooks are the
  /// source of truth; when they change, this changes. It is written out here
  /// rather than called through HTTP because these devices are in this process
  /// — but every step below is the same public service call the hook makes, so
  /// nothing about the ceremony is simulated.
  Future<void> linkDevice({
    required E2eDevice master,
    required E2eDevice target,
  }) async {
    if (!master.isMaster) {
      throw ArgumentError('${master.label} holds no master material');
    }
    if (master.identity.label != target.identity.label) {
      throw ArgumentError(
        'cannot link ${target.label} (identity ${target.identity.label}) into '
        '${master.label} (identity ${master.identity.label})',
      );
    }
    await E2eLog.step('link ${target.label} into ${master.label}', () async {
      final phrase = master.identity.phrase;
      final masterGroups = master.groups!;
      final targetGroups = target.groups!;

      // 1. LINK PREPARE, on the master.
      final link = await target.deviceLinkInvite();
      final mine = await master.deviceLinkInvite();
      if (link.isSelf(
        myDeviceNodeId: mine.nodeId,
        myIdentityId: masterGroups.selfId,
      )) {
        throw StateError(
          'the ceremony thinks ${target.label} IS ${master.label} — two '
          'devices minted from the same key are one node, not two',
        );
      }

      // The document FIRST. Until the master's document names the sibling, the
      // registry it publishes lists one instance, sealing for "my other
      // devices" finds none, and the snapshot below is deposited for nobody.
      final theirDoc = link.document;
      if (theirDoc != null && theirDoc.isNotEmpty) {
        if (await RealVeilStack.adoptSovereignDocument(
          master.storage,
          document: theirDoc,
          stagingBase: Directory.systemTemp.path,
        )) {
          await master.stack.refreshSovereignIdentity(master.storage);
        }
      }
      await _join(master, await target.dialableDeviceInvite());

      // The document half, FAIL CLOSED: a group membership on top of a document
      // that does not name the device is the half-linked state the campaign
      // measured as a half-ghost member.
      final outcome = await RealVeilStack.delegateDeviceIntoDocument(
        master.storage,
        phrase: phrase,
        devicePubkey: link.device.publicKey,
        stagingBase: Directory.systemTemp.path,
      );
      if (!outcome.documentNamesDevice) {
        throw StateError(
          'the identity document was not amended for ${target.label} — the '
          'ceremony would leave a device the identity does not vouch for',
        );
      }
      var delegated = outcome == DeviceDelegation.delegated;

      final sovereign = await masterGroups.openLocalSovereign(phrase);
      try {
        if (!await masterGroups.linkDevice(
          link.device.nodeId,
          sovereign: sovereign,
          broadcastSnapshot: false,
        )) {
          throw StateError('${master.label} refused ${target.label} membership');
        }
        // RETRO-delegation: members admitted before the document learned to
        // grow. Without it their rows drop as "signature verify failed" on
        // every newly linked device.
        for (final entry in (await masterGroups.deviceWriterKeys()).entries) {
          if (entry.key == link.device.nodeId) continue;
          delegated = await RealVeilStack.delegateDeviceIntoDocument(
                    master.storage,
                    phrase: phrase,
                    devicePubkey: entry.value,
                    stagingBase: Directory.systemTemp.path,
                  ) ==
                  DeviceDelegation.delegated ||
              delegated;
        }
        if (delegated) {
          await master.stack.refreshSovereignIdentity(master.storage);
        }
        final token = await masterGroups.createDeviceLinkToken(
          master.stack.myInvite,
          sourceDevice: mine.nodeId,
          document: await RealVeilStack.storedSovereignDocument(master.storage),
        );
        if (token == null) throw StateError('no device-link token was issued');

        // 2. ADOPT PREPARE, on the target.
        await _join(target, master.dialableContactInvite());
        await _join(target, await master.dialableDeviceInvite());
        final sourceDoc = token.document;
        if (sourceDoc != null && sourceDoc.isNotEmpty) {
          if (await RealVeilStack.adoptSovereignDocument(
            target.storage,
            document: sourceDoc,
            stagingBase: Directory.systemTemp.path,
          )) {
            await target.stack.refreshSovereignIdentity(target.storage);
          }
        }
        if (!await targetGroups.prepareDeviceAdoption(
          token,
          myDevice: (await target.deviceLinkInvite()).nodeId,
        )) {
          throw StateError('${target.label} refused the admission');
        }

        // 3. SNAPSHOT SEND, on the master: membership first, then everything
        // the identity already holds. A device linked without the seed adopts
        // the group correctly and shows an empty history.
        final sent = await masterGroups.broadcastDeviceGroup();
        var seeded = 0;
        for (final device in await masterGroups.otherDeviceIds()) {
          seeded += await masterGroups.seedDevice(device);
        }
        E2eLog.line('link: snapshot sent=$sent seeded=$seeded');
      } finally {
        sovereign.close();
      }
    });

    // The ceremony is asynchronous on the target's side: the snapshot travels
    // over the island. Wait for the state that makes the pair a pair.
    await waitUntil(
      () async =>
          await target.groups!.deviceGroupIdHex() ==
          await master.groups!.deviceGroupIdHex(),
      what: '${target.label} to adopt ${master.label}\'s device group',
      describe: () async =>
          '${master.label}=${await master.groups!.deviceGroupIdHex()} '
          '${target.label}=${await target.groups!.deviceGroupIdHex()}',
      timeout: const Duration(minutes: 3),
    );
  }

  /// The full consent handshake between two devices of DIFFERENT identities,
  /// over the real overlay: request → accept.
  Future<void> introduce(E2eDevice from, E2eDevice to) async {
    await E2eLog.step('${from.label} ↔ ${to.label} contact', () async {
      await _join(from, to.dialableContactInvite());
      await _join(to, from.dialableContactInvite());
      await from.messaging.sendRequest(to.identityNodeId, 'e2e');
      await waitUntil(
        () async =>
            (await to.storage.getContact(from.identityNodeId))?.status ==
            ContactStatus.pendingIncoming,
        what: '${to.label} to see ${from.label}\'s contact request',
        describe: () async =>
            'status=${(await to.storage.getContact(from.identityNodeId))?.status}',
        // Generous, because this is the COLD onion path and nothing else. Two
        // strangers on a fresh island have no direct route: a loopback invite
        // deliberately carries no `t=` (dialing 127.0.0.1 on somebody else's
        // machine is worse than useless), so the request goes out over the
        // rendezvous once both sides have registered with a relay and built
        // circuits. Measured here at 13s on a warm island and past 90s on a
        // cold one; a tight deadline would report the cold start as a defect.
        timeout: const Duration(minutes: 5),
      );
      await to.messaging.acceptContact(from.identityNodeId);
      await waitUntil(
        () async =>
            (await from.storage.getContact(to.identityNodeId))?.status ==
            ContactStatus.accepted,
        what: '${from.label} to see the acceptance',
        describe: () async =>
            'status=${(await from.storage.getContact(to.identityNodeId))?.status}',
        // The return leg is over a route that has just proved it works, so it
        // is normally seconds — but it rides the same cold-start variance.
        timeout: const Duration(minutes: 5),
      );
    });
  }

  // --- identity material ----------------------------------------------------

  static ({E2eIdentity identity, bool isMaster, String fixture}) _spec(
    String label,
  ) => switch (label) {
    'A' => (identity: E2eIdentity.x, isMaster: true, fixture: 'x_master'),
    'B' => (identity: E2eIdentity.x, isMaster: false, fixture: 'x_sibling'),
    'C' => (identity: E2eIdentity.y, isMaster: true, fixture: 'y_master'),
    'D' => (identity: E2eIdentity.y, isMaster: false, fixture: 'y_sibling'),
    _ => throw ArgumentError('unknown device label $label'),
  };

  static Future<String> _identityToml(
    ({E2eIdentity identity, bool isMaster, String fixture}) spec,
    String dylibPath,
  ) async {
    final file = File('test/e2e/fixtures/device_identity_${spec.fixture}.toml');
    if (await file.exists()) {
      final text = await file.readAsString();
      // A cached master TOML that does NOT match the phrase would produce a
      // device whose node key the identity document cannot name — the exact
      // half-linked state the ceremony fails closed on, arriving instead as an
      // inexplicable "membership rejected".
      return text;
    }
    E2eLog.line(
      'no cached identity for ${spec.fixture} — MINTING at the canonical PoW '
      'difficulty. ~45s and every core; cached at ${file.path} afterwards.',
    );
    final lib = DynamicLibrary.open(dylibPath);
    final toml = spec.isMaster
        // DERIVED from the phrase: the first device of an identity takes the
        // phrase's own keypair, which is what makes node_id recoverable.
        ? EmbeddedNode.configFromPhrase(spec.identity.phrase, lib: lib)
        // MINED: every later device must have a key of its own. Two devices
        // holding one key are one node — they cannot link ("self device") and
        // would drive the same ratchets.
        : EmbeddedNode.mineConfig(0, lib: lib);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '# TEST-ONLY device identity for the end-to-end multi-device harness\n'
      '# (test/e2e/device_fixture.dart). The private key is intentionally\n'
      '# public and must NEVER be used outside an isolated loopback test.\n'
      '${spec.isMaster ? "# DERIVED from E2eIdentity.${spec.identity.label.toLowerCase()}.phrase — "
          "regenerating it means regenerating that phrase too.\n" : ""}'
      '$toml',
    );
    return file.readAsString();
  }
}
