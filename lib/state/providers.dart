import 'package:flutter/foundation.dart' show kProfileMode, kReleaseMode;
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/transport/bootstrap_invite.dart';

import '../data/node/bundled_seeds.dart'
    show IdentityPeers, kBundledSeedsDefault, resolveBootstrapPeers;
import '../data/node/embedded_node.dart' show BootstrapPeerCfg;
import '../data/node/fake_node_controller.dart';
import '../data/node/node_controller.dart';
import '../data/node/proxy_routing.dart';
import '../data/storage/fake_kv_log_store.dart';
import '../data/storage/hidden_volume_storage.dart';
import '../data/storage/on_disk_blob_store.dart';
import '../data/storage/kv_log_store.dart';
import '../data/storage/storage.dart';
import '../data/storage/worker_multi_space.dart';
import '../data/transport/fail_closed_transport.dart';
import '../data/transport/loopback_transport.dart';
import '../data/transport/veil_transport.dart';
import '../data/veil_stack.dart';
import 'multi_identity_session.dart';

/// --- Infrastructure providers -------------------------------------------
///
/// Every external dependency the app talks to is exposed here behind its
/// port. Today they resolve to fakes; the native swap (Milestone 2) only
/// re-points these three providers — nothing in the UI changes.

final prefsProvider = FutureProvider<SharedPreferences>((ref) {
  return SharedPreferences.getInstance();
});

/// The SINGLE-identity storage (one space open at a time) — the default path.
/// main() overrides this with the real container-backed one; here it is the
/// in-memory dev/test wiring. In "all identities online" mode the active
/// identity's storage comes from the session instead (see [storageProvider]).
final singleSpaceStorageProvider = Provider<Storage>((ref) {
  // Dev/test wiring: the real domain→namespace/log mapping runs over an
  // in-memory space that persists for the session (so lock→unlock keeps
  // data). Swapping to native is just a different SpaceOpener (HvSpace).
  // An empty password unlocks nothing — exercises the auth-fail path.
  final session = FakeKvLogStore();
  KvLogStore? opener({required Uint8List password, required bool create}) {
    return password.isEmpty ? null : session;
  }

  final storage = HiddenVolumeStorage(opener);
  ref.onDispose(storage.close);
  return storage;
});

/// Builds an all-online [MultiIdentitySession] over the real native container.
/// Overridden in tests with a fake backing/boot so the AppController branch is
/// testable without a node.
typedef SessionBuilder =
    MultiIdentitySession Function({
      required String storePath,
      required String runtimeDir,
      required int listenPort,
      required IdentityPeers peersFor,
      String? obfs4Psk,
      required List<String> udpReflectors,
      required bool lazyMining,
      required ProxyRouting proxy,
      required hv.PaddingPreset paddingPreset,
    });

MultiIdentitySession _realSessionBuilder({
  required String storePath,
  required String runtimeDir,
  required int listenPort,
  IdentityPeers peersFor = _noSessionPeers,
  String? obfs4Psk,
  List<String> udpReflectors = const [],
  bool lazyMining = false,
  ProxyRouting proxy = ProxyRouting.disabled,
  hv.PaddingPreset paddingPreset = hv.PaddingPreset.bucket256KiB,
}) => MultiIdentitySession(
  // Off-isolate: the shared multi-space container is owned by a worker
  // isolate (lazy-spawned on the first openSpace), so every always-online
  // identity's get/commit/scan runs off the UI thread.
  WorkerMultiSpaceBacking(storePath, paddingPreset: paddingPreset),
  runtimeDirBase: runtimeDir,
  listenPortBase: listenPort,
  // The SAME large-file tier the single-identity boot opens — one directory
  // beside the container, shared by every space (XV-02).
  blobRoot: blobRootFor(storePath),
  // A BUILDER, not a finished list: every identity in the session resolves its
  // own shared-seed answer from its own space, and its peer list is built from
  // that. One list for the session is what let a refuser be handed the seeds
  // because somebody else in the same container had kept them.
  peersFor: peersFor,
  // Lockstep with the single-identity boot so always-online nodes join the
  // same (obfs4-protected) network and honour the same mining/routing config.
  obfs4Psk: obfs4Psk,
  udpReflectors: udpReflectors,
  lazyMining: lazyMining,
  proxy: proxy,
);

List<BootstrapPeerCfg> _noSessionPeers(bool useBundledSeeds) =>
    const <BootstrapPeerCfg>[];

final sessionBuilderProvider = Provider<SessionBuilder>(
  (ref) => _realSessionBuilder,
);

/// The "all identities online" session, set by [AppController] when a master is
/// unlocked with `keepAllOnline`; null otherwise (single / one-active mode).
final sessionProvider = StateProvider<MultiIdentitySession?>((ref) => null);

/// In a session, the label of the identity the UI currently shows. Changing it
/// (a switch) re-points [storageProvider] / [messagingServiceProvider] to that
/// identity WITHOUT stopping any node — all stay online.
final activeIdentityProvider = StateProvider<String?>((ref) => null);

/// The storage the UI reads. In an all-online session it is the ACTIVE
/// identity's hosted view; otherwise the single-space storage (unchanged path).
final storageProvider = Provider<Storage>((ref) {
  final session = ref.watch(sessionProvider);
  final active = ref.watch(activeIdentityProvider);
  if (session != null && active != null) {
    final s = session.storageFor(active);
    if (s != null) return s;
  }
  return ref.watch(singleSpaceStorageProvider);
});

/// Provenance of the ACTIVE identity's node config ([kIdentityOriginSetting]):
/// 'phrase' — restorable from the recovery phrase; 'mined' — minted at random;
/// null — legacy space provisioned before the marker existed (= no phrase).
/// Follows identity switches via [storageProvider].
final identityOriginProvider = FutureProvider.autoDispose<String?>((ref) async {
  final storage = ref.watch(storageProvider);
  if (!storage.isOpen) return null;
  try {
    return await storage.getSetting(kIdentityOriginSetting);
  } catch (_) {
    return null; // unreadable — show nothing rather than a wrong claim
  }
});

/// Bumped whenever an identity's anonymity preference changes. The flags
/// themselves live on [AppController] — the master roster's `anonymous` entry
/// and the single space's `anonymous` setting — NOT in [AppState], so watching
/// the state alone leaves a screen drawing the value it read before the toggle
/// (the settings switch looked dead: it flipped the node and kept the old
/// position). Anything that renders anonymity watches this too.
final anonymityRevisionProvider = StateProvider<int>((ref) => 0);

/// Parameters for the in-process deniable boot, set by main() when the
/// node-embedded dylib is loaded. Null disables it (loopback / legacy paths).
class DeniableBootConfig {
  const DeniableBootConfig({
    required this.runtimeDir,
    this.listenPort = 9000,
    this.storePath,
    this.bootstrapPeers = const [],
    this.operatorPeers = const [],
    this.bundledSeeds = const [],
    this.udpReflectors = const [],
    this.obfs4Psk,
  });

  /// Directory for the ephemeral, identity-free node sockets (admin + app IPC).
  final String runtimeDir;

  /// This instance's listener port (give two instances on one host distinct
  /// ports so they don't collide).
  final int listenPort;

  /// Path to the deniable container file. Needed by the "all identities online"
  /// branch to open the container as one `HvMultiSpace` (host every identity at
  /// once). Null on the in-memory/loopback path (all-online unavailable).
  final String? storePath;

  /// Bootstrap peers to dial at boot so the node joins a specific network
  /// (seed set / testnet). Empty = rely on the compiled-in BUILTIN_SEEDS.
  /// Loaded by main() from a local, gitignored file (never committed).
  ///
  /// The PROFILE-level list: built once in `main()` from the pre-unlock answer,
  /// before any container is open. It is what the UI reports as "entry points
  /// this app was configured with"; the list a NODE gets comes from [peersFor],
  /// per identity.
  final List<BootstrapPeerCfg> bootstrapPeers;

  /// The two halves [peersFor] builds from, kept apart on purpose.
  ///
  /// [operatorPeers] — `XVEIL_BOOTSTRAP_PEERS`, or anything else the user named
  /// themselves — survives either answer: declining the SHARED seeds is not
  /// declining your own node. [bundledSeeds] are the descriptors from
  /// `assets/prod/seeds.json`, and they are added only for an identity that
  /// keeps them.
  final List<BootstrapPeerCfg> operatorPeers;
  final List<BootstrapPeerCfg> bundledSeeds;

  /// The peers ONE identity is handed, built from ITS OWN answer.
  ///
  /// Built, never filtered: a refuser's list never holds the shared descriptors
  /// at all, so no layer downstream can decide to fall back to something it can
  /// still see.
  ///
  /// A config assembled without the split (the loopback/dev paths, and tests
  /// that only set [bootstrapPeers]) cannot tell the two halves apart any more —
  /// so an identity that KEEPS the seeds gets that list unchanged, and one that
  /// refuses gets nothing. That is the safe direction of the ambiguity: the
  /// answer that must never be overruled is the refusal.
  List<BootstrapPeerCfg> peersFor(bool useBundledSeeds) {
    if (operatorPeers.isEmpty && bundledSeeds.isEmpty) {
      return useBundledSeeds ? bootstrapPeers : const <BootstrapPeerCfg>[];
    }
    return resolveBootstrapPeers(
      operatorPeers: operatorPeers,
      bundledSeeds: bundledSeeds,
      useBundledSeeds: useBundledSeeds,
    );
  }

  /// Static fallback endpoints, and what the simulator injects in its
  /// scenarios. Normal app boots leave this empty: authenticated live peers
  /// advertise reflector availability themselves.
  final List<String> udpReflectors;

  /// Base64 deployment-wide obfs4 pre-shared key. Required to dial peers on a
  /// network that pins a shared obfs4 PSK (e.g. the testnet). Written to a file
  /// in the runtime dir at boot and referenced via `[transport].obfs4_psk_file`.
  final String? obfs4Psk;
}

/// The ACTIVE identity's answer to the shared-seed question, as the RUNNING app
/// knows it — seeded by main() from the pre-unlock preference, then re-pointed
/// at each identity as it is activated (see `AppController`).
///
/// Live UI state, never the source of truth: the answer that decides a node's
/// config is read from that identity's own space at boot
/// ([bundledSeedsAllowedFor]). This one exists so the screens do not have to be
/// async, and because of the first run. The boot config is assembled in `main`,
/// before onboarding has asked anything, so on the launch where the choice is
/// actually made the stored preference still says what it said at process
/// start. [deniableBootProvider] watches this, so recording a refusal REBUILDS
/// the config without the bundled seed descriptors before the node boots at the
/// end of onboarding. Without it the very first session — the one where the
/// person just declined — would still hand those addresses to the node over
/// IPC, which is precisely the quiet fallback the choice is meant to prevent.
final bundledSeedsChoiceProvider = StateProvider<bool>(
  (ref) => kBundledSeedsDefault,
);

/// Present (non-null) when the app should boot the node in-process from the
/// in-space identity post-unlock. main() overrides it only when the embedded
/// FFI is available; otherwise the default startup path is unchanged.
final deniableBootProvider = Provider<DeniableBootConfig?>((ref) => null);

/// The real veil stack, when running. Null until built: main() overrides the
/// initial value for the env-config dev path, or [AppController] sets it
/// post-unlock for the deniable path. The node/transport/invite providers below
/// rebuild when it changes.
final realStackProvider = StateProvider<RealVeilStack?>((ref) => null);

/// One-shot: the user finished onboarding by choosing "link to a device you
/// already use", so the session that just opened should land on the device-link
/// screen rather than on chats. Set by [AppController.completeOnboarding] and
/// consumed by the router on the first `ready`. Deliberately NOT persisted —
/// an interrupted link is resumed from Settings, and a flag that outlived the
/// process would keep hijacking every launch.
final pendingDeviceLinkProvider = StateProvider<bool>((ref) => false);

/// HONEST boot status of the REAL node, when a real node is expected (a packaged
/// build / armed deniable boot) but the stack isn't up yet. Non-null ⇒ the UI
/// must show THIS (e.g. `starting`, or `error`/`offline` with a message) rather
/// than the in-memory demo node — so the app never fabricates a "connected"
/// state. main() seeds it (`starting`/`error`) and [AppController] updates it
/// when the in-process boot fails. Null ⇒ no real node expected (pure dev/UI
/// build) ⇒ the demo `FakeNodeController` is used.
final nodeBootStateProvider = StateProvider<NodeStatus?>((ref) => null);

final nodeControllerProvider = Provider<NodeController>((ref) {
  final stack = ref.watch(realStackProvider);
  if (stack != null) return stack.controller; // owned/disposed by the stack
  // Real node expected but not up: surface the honest boot status — NEVER the
  // demo node's fabricated peer count.
  final boot = ref.watch(nodeBootStateProvider);
  if (boot != null) return StaticNodeController(boot);
  // No real node expected (dev/UI/test build) — the in-memory demo node.
  final node = FakeNodeController();
  ref.onDispose(node.stop);
  return node;
});

final veilTransportProvider = Provider<VeilTransport>((ref) {
  final stack = ref.watch(realStackProvider);
  if (stack != null) return stack.transport; // owned/disposed by the stack
  // NO REAL STACK. What stands in depends on the build (audit XV-01).
  //
  // `LoopbackTransport` echoes every send back as an inbound message FROM the
  // addressee — right for developing the UI on one machine, and a fabricated
  // conversation anywhere else. It was reachable in a packaged desktop build:
  // a veil dylib that failed to load left the boot state null, and this
  // provider handed out a loopback, so a message appeared delivered and
  // answered while nothing had left the machine.
  //
  // A shipped build gets a transport that refuses instead.
  final VeilTransport transport = kReleaseMode || kProfileMode
      ? FailClosedTransport(
          reason: const TransportUnavailable('no veil node is running'),
        )
      : LoopbackTransport();
  ref.onDispose(transport.dispose);
  return transport;
});

/// This device's shareable invite URI for the contact-exchange sheet — only
/// available in real mode (null on loopback, which hides the QR).
final myInviteProvider = Provider<String?>(
  (ref) => ref.watch(realStackProvider)?.myInvite.toUri(),
);

/// The network's bootstrap entry nodes (the public seed descriptors bundled at
/// `assets/prod/seeds.json`, mirroring veil's compiled-in builtin_seeds). These
/// carry full dialable descriptors (transport + pk + nonce) — unlike the live
/// peer list, which has no keys — so they're the honest source for the
/// "share entry nodes" feature. Empty in a clean clone (asset absent).
final seedEntriesProvider = FutureProvider<List<BootstrapInvite>>((ref) async {
  try {
    final raw = await rootBundle.loadString('assets/prod/seeds.json');
    final json = jsonDecode(raw);
    if (json is! List) return const [];
    return [
      for (final e in json)
        if (e is Map &&
            e['transport'] is String &&
            e['public_key'] is String &&
            e['nonce'] is String)
          BootstrapInvite(
            publicKey: base64.decode(e['public_key'] as String),
            transport: e['transport'] as String,
            nonce: base64.decode(e['nonce'] as String),
            algo: (e['algo'] as String?) ?? 'ed25519',
          ),
    ];
  } catch (_) {
    return const [];
  }
});

/// Live node status, surfaced to the network UI. Emits the controller's current
/// snapshot FIRST, then its event stream — so a screen that subscribes after the
/// node already reached `connected` (e.g. the deniable boot finished before the
/// network tab was opened) shows the real status instead of being stuck on the
/// stream's pre-subscription default ("connecting").
final nodeStatusProvider = StreamProvider<NodeStatus>((ref) async* {
  final node = ref.watch(nodeControllerProvider);
  yield node.current;
  yield* node.status();
});

/// Live count of the node's connected peers (active overlay sessions), from the
/// REAL transport — the genuine number shown in the network UI. Null/0 until a
/// real node is up (the demo loopback reports 0). Driven by the node's
/// `sessionsChanged` events, so it tracks connects/disconnects in real time.
final sessionCountProvider = StreamProvider<int>((ref) {
  final stack = ref.watch(realStackProvider);
  if (stack == null) return Stream<int>.value(0);
  return stack.transport.sessionCount();
});

/// Live, deduplicated view of the node's peers for the network "peers" screen.
///
/// veil reports a point-in-time snapshot with NO timestamps, so this provider
/// adds the missing "last seen" honestly: it polls [VeilTransport.peers] and,
/// each time it observes a peer ACTIVE, stamps `lastSeen = now` (meaning "last
/// seen BY THIS DEVICE since the node started" — never a fabricated node
/// clock). Peers that drop out of a later snapshot are kept, marked closed,
/// with their last stamp preserved — so the user can still see when an
/// inactive peer was last connected. Empty (and never polls) in dev/loopback.
final peersProvider = StreamProvider<List<PeerInfo>>((ref) async* {
  final stack = ref.watch(realStackProvider);
  if (stack == null) {
    yield const [];
    return;
  }
  final transport = stack.transport;
  // Union of every peer observed this node-lifetime, keyed by node_id hex.
  final tracked = <String, PeerInfo>{};

  List<PeerInfo> merge(List<PeerInfo> snap) {
    final now = DateTime.now();
    final seenNow = <String>{};
    for (final p in snap) {
      final key = p.nodeId.hex;
      seenNow.add(key);
      final prev = tracked[key];
      // Stamp last-seen only while active; otherwise carry the prior stamp.
      tracked[key] = p.copyWith(lastSeen: p.isActive ? now : prev?.lastSeen);
    }
    // Peers absent from this snapshot: keep them, but mark closed.
    for (final key in tracked.keys.toList()) {
      if (!seenNow.contains(key) && tracked[key]!.state != PeerState.closed) {
        tracked[key] = tracked[key]!.copyWith(state: PeerState.closed);
      }
    }
    final list = tracked.values.toList()
      ..sort((a, b) {
        if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
        final at = a.lastSeen, bt = b.lastSeen;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
    return list;
  }

  // Poll every few seconds: catches connecting→active transitions that don't
  // change the session COUNT (so wouldn't fire a sessionsChanged event), at a
  // negligible cost (one FFI call returning ≤256 entries).
  while (true) {
    List<PeerInfo> snap;
    try {
      snap = await transport.peers();
    } catch (_) {
      snap = const [];
    }
    yield merge(snap);
    await Future<void>.delayed(const Duration(seconds: 4));
  }
});
