import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/transport/bootstrap_invite.dart';

import '../data/node/embedded_node.dart' show BootstrapPeerCfg;
import '../data/node/fake_node_controller.dart';
import '../data/node/node_controller.dart';
import '../data/node/proxy_routing.dart';
import '../data/storage/fake_kv_log_store.dart';
import '../data/storage/hidden_volume_storage.dart';
import '../data/storage/kv_log_store.dart';
import '../data/storage/storage.dart';
import '../data/storage/worker_multi_space.dart';
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
typedef SessionBuilder = MultiIdentitySession Function({
  required String storePath,
  required String runtimeDir,
  required int listenPort,
  String? obfs4Psk,
  bool lazyMining,
  ProxyRouting proxy,
});

MultiIdentitySession _realSessionBuilder({
  required String storePath,
  required String runtimeDir,
  required int listenPort,
  String? obfs4Psk,
  bool lazyMining = false,
  ProxyRouting proxy = ProxyRouting.disabled,
}) =>
    MultiIdentitySession(
      // Off-isolate: the shared multi-space container is owned by a worker
      // isolate (lazy-spawned on the first openSpace), so every always-online
      // identity's get/commit/scan runs off the UI thread.
      WorkerMultiSpaceBacking(storePath),
      runtimeDirBase: runtimeDir,
      listenPortBase: listenPort,
      // Lockstep with the single-identity boot so always-online nodes join the
      // same (obfs4-protected) network and honour the same mining/routing config.
      obfs4Psk: obfs4Psk,
      lazyMining: lazyMining,
      proxy: proxy,
    );

final sessionBuilderProvider =
    Provider<SessionBuilder>((ref) => _realSessionBuilder);

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

/// Parameters for the in-process deniable boot, set by main() when the
/// node-embedded dylib is loaded. Null disables it (loopback / legacy paths).
class DeniableBootConfig {
  const DeniableBootConfig({
    required this.runtimeDir,
    this.listenPort = 9000,
    this.storePath,
    this.bootstrapPeers = const [],
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
  final List<BootstrapPeerCfg> bootstrapPeers;

  /// Base64 deployment-wide obfs4 pre-shared key. Required to dial peers on a
  /// network that pins a shared obfs4 PSK (e.g. the testnet). Written to a file
  /// in the runtime dir at boot and referenced via `[transport].obfs4_psk_file`.
  final String? obfs4Psk;
}

/// Present (non-null) when the app should boot the node in-process from the
/// in-space identity post-unlock. main() overrides it only when the embedded
/// FFI is available; otherwise the default startup path is unchanged.
final deniableBootProvider = Provider<DeniableBootConfig?>((ref) => null);

/// The real veil stack, when running. Null until built: main() overrides the
/// initial value for the legacy env-config path, or [AppController] sets it
/// post-unlock for the deniable path. The node/transport/invite providers below
/// rebuild when it changes.
final realStackProvider = StateProvider<RealVeilStack?>((ref) => null);

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
  final transport = LoopbackTransport();
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
      tracked[key] =
          p.copyWith(lastSeen: p.isActive ? now : prev?.lastSeen);
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
