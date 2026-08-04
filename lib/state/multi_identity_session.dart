import 'dart:io';
import '../data/serve_source.dart';
// Clean public param names are worth more than initializing-formal terseness
// for this small orchestration constructor.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../data/node/embedded_node.dart' show BootstrapPeerCfg;
import '../data/node/proxy_routing.dart';
import '../data/storage/hidden_volume_storage.dart';
import '../data/storage/multi_space_store.dart';
import '../data/storage/storage.dart';
import '../data/transport/veil_transport.dart';
import '../data/veil_stack.dart';
import '../domain/chat.dart';
import '../domain/p2p_policy.dart';
import '../domain/roster.dart';
import 'messaging.dart';

/// One identity's boot plan in an "all identities online" session: which hosted
/// space it uses, and the ephemeral runtime endpoints (a runtime BASE to create
/// its own directory under + a distinct listen port so the N nodes don't
/// collide) and routing mode.
class IdentityBootSpec {
  const IdentityBootSpec({
    required this.label,
    required this.spaceId,
    required this.runtimeBase,
    required this.listenPort,
    required this.anonymous,
    this.bootstrapPeers = const [],
    this.obfs4Psk,
    this.udpReflectors = const [],
    this.lazyMining = false,
    this.proxy = ProxyRouting.disabled,
  });

  final String label;
  final int spaceId;
  /// Where this identity's node CREATES its runtime directory. Not a directory
  /// it may own — see [RealVeilStack.startDeniable].
  final String runtimeBase;
  final int listenPort;
  final bool anonymous;
  final List<BootstrapPeerCfg> bootstrapPeers;

  /// Session-wide node config the all-online boot must apply per identity, in
  /// lockstep with the single-identity path — without these an always-online
  /// node booted with NO obfs4 PSK (so it could not join the obfs4-protected
  /// production network), no lazy-mining setting, and no traffic routing.
  final String? obfs4Psk;
  final List<String> udpReflectors;
  final bool lazyMining;
  final ProxyRouting proxy;
}

/// A booted identity node: its overlay [transport] (drives that identity's
/// messaging), the optional [stack] (for its invite/status — null in tests),
/// and a [dispose] to tear it down. Decouples the session from the concrete
/// (native) [RealVeilStack] so the orchestration is unit-testable.
class IdentityNode {
  const IdentityNode({
    required this.transport,
    required this.dispose,
    this.stack,
  });

  final VeilTransport transport;
  final Future<void> Function() dispose;
  final RealVeilStack? stack;
}

/// Plan the boots for a whole roster over a shared [backing]: open each
/// identity's space (hosting it) and assign it a distinct runtime dir + listen
/// port (offset by index) so N nodes can run at once on one host. Pure aside
/// from `backing.openSpace`, so it is unit-testable with a fake backing.
Future<List<IdentityBootSpec>> planIdentityBoots(
  List<RosterEntry> roster,
  AsyncMultiSpaceBacking backing, {
  required String runtimeDirBase,
  required int listenPortBase,
  List<BootstrapPeerCfg> bootstrapPeers = const [],
  String? obfs4Psk,
  List<String> udpReflectors = const [],
  bool lazyMining = false,
  ProxyRouting proxy = ProxyRouting.disabled,
}) async {
  final out = <IdentityBootSpec>[];
  for (var i = 0; i < roster.length; i++) {
    out.add(
      IdentityBootSpec(
        label: roster[i].label,
        spaceId: await backing.openSpace(roster[i].spaceKeys),
        bootstrapPeers: bootstrapPeers,
        obfs4Psk: obfs4Psk,
        udpReflectors: udpReflectors,
        lazyMining: lazyMining,
        proxy: proxy,
        // Deniability: the runtime dir name must NOT be the human-readable
        // label — a device seized while running would otherwise read identity
        // names straight off the filesystem. Every node now creates its own
        // randomly-named directory under this shared base, which is opaque AND
        // unstable across runs; the hash of the label this used to interpose
        // was opaque but the SAME every time, so leftovers from a crash
        // correlated one run's identities with the next one's. The directory is
        // released on teardown ([RealVeilStack.dispose]), so nothing survives
        // at rest either way.
        runtimeBase: runtimeDirBase,
        // Offset by 1 so all-online nodes never reuse [listenPortBase] — the
        // port a just-stopped one-active node held, whose lingering teardown
        // would otherwise stall the first identity's bind for ~90s.
        listenPort: listenPortBase + 1 + i,
        anonymous: roster[i].anonymous,
      ),
    );
  }
  return out;
}

/// Boots an [IdentityNode] from [storage] for one [spec] — defaults to the real
/// deniable boot; injectable so the orchestration can be tested without a node.
typedef IdentityNodeBoot =
    Future<IdentityNode> Function(IdentityBootSpec spec, Storage storage);

Future<IdentityNode> _realBoot(IdentityBootSpec spec, Storage storage) async {
  final stack = await RealVeilStack.startDeniable(
    storage: storage,
    runtimeDirBase: spec.runtimeBase,
    listenPort: spec.listenPort,
    anonymous: spec.anonymous,
    lazyMining: spec.lazyMining,
    // Same split as the single-identity path: keep explicit peers out of the
    // reload config (Android ENOENT), then activate them through IPC.
    bootstrapPeers: const <BootstrapPeerCfg>[],
    runtimeBootstrapPeers: spec.bootstrapPeers,
    udpReflectors: spec.udpReflectors,
    obfs4Psk: spec.obfs4Psk,
    proxy: spec.proxy,
  );
  return IdentityNode(
    transport: stack.transport,
    stack: stack,
    dispose: stack.dispose,
  );
}

/// Runs ALL of a master's identities at once. Every identity's space is hosted
/// open over one [MultiSpaceBacking] (one container/lock), its veil node runs
/// simultaneously (own port + runtime dir), AND it has its own
/// [MessagingService] wired to its node's transport + its storage — so EVERY
/// identity receives and persists messages concurrently, not just the active
/// one. The "active" identity is merely the one the UI shows; switching changes
/// the view without stopping any node, so nothing goes offline.
///
/// Trades anonymity for availability — co-located always-on nodes can be
/// correlated by an observer. Opt-in only; mark sensitive identities `anonymous`
/// to route them over onion and keep them uncorrelated even when always-on.
class MultiIdentitySession {
  MultiIdentitySession(
    this._backing, {
    required String runtimeDirBase,
    required int listenPortBase,
    Directory? blobRoot,
    Duration bootTimeout = _defaultBootTimeout,
    List<BootstrapPeerCfg> bootstrapPeers = const [],
    String? obfs4Psk,
    List<String> udpReflectors = const [],
    bool lazyMining = false,
    ProxyRouting proxy = ProxyRouting.disabled,
    IdentityNodeBoot boot = _realBoot,
  }) : _runtimeDirBase = runtimeDirBase,
       _listenPortBase = listenPortBase,
       _blobRoot = blobRoot,
       _bootTimeout = bootTimeout,
       _bootstrapPeers = bootstrapPeers,
       _obfs4Psk = obfs4Psk,
       _udpReflectors = udpReflectors,
       _lazyMining = lazyMining,
       _proxy = proxy,
       _boot = boot;

  final AsyncMultiSpaceBacking _backing;

  /// The shared large-file tier, or null when this build has none.
  ///
  /// All-online storages were built WITHOUT it (audit XV-02): only the
  /// single-space boot ever called `useOnDiskTier`, so switching modes made
  /// already-stored large files read as missing, and new ones fell back into
  /// the volume index — whose ceiling the code itself warns about.
  ///
  /// Every space gets the SAME directory, deliberately. A directory per space
  /// would publish how many hidden spaces the container holds, right next to
  /// it — the fingerprint class hidden-volume removed from the cleartext header
  /// in v3. Ownership is resolved inside each space instead: `eraseSpace`
  /// deletes only the blob names its own volume names (XV-01).
  final Directory? _blobRoot;

  final String _runtimeDirBase;
  final int _listenPortBase;
  final List<BootstrapPeerCfg> _bootstrapPeers;

  /// Session-wide node config applied to every always-online node, kept in
  /// lockstep with the single-identity boot (obfs4 PSK to join the network,
  /// lazy-mining setting, traffic routing).
  final String? _obfs4Psk;
  final List<String> _udpReflectors;
  final bool _lazyMining;
  final ProxyRouting _proxy;
  final IdentityNodeBoot _boot;

  /// Per-identity node-boot ceiling (mining a fresh identity can take a few
  /// seconds; the deferred admin-connect retries up to ~90s, so cap well under
  /// that to fail fast on a stuck bind).
  /// Per-identity node-boot ceiling. Overridable so a test can exercise the
  /// LATE-arrival path without waiting three quarters of a minute for it.
  static const _defaultBootTimeout = Duration(seconds: 45);
  final Duration _bootTimeout;

  final _storages = <String, Storage>{};
  final _nodes = <String, IdentityNode>{};
  final _messaging = <String, MessagingService>{};

  List<String> get labels => _storages.keys.toList(growable: false);
  Storage? storageFor(String label) => _storages[label];
  RealVeilStack? stackFor(String label) => _nodes[label]?.stack;
  MessagingService? messagingFor(String label) => _messaging[label];

  /// Open every identity's space over the shared backing, boot its node, and
  /// wire its own messaging pipeline (transport + storage) so it receives
  /// concurrently. Best-effort per identity: a boot failure logs and skips that
  /// identity's node/messaging but keeps its storage view hosted.
  Future<void> bootAll(List<RosterEntry> roster) async {
    final specs = await planIdentityBoots(
      roster,
      _backing,
      runtimeDirBase: _runtimeDirBase,
      listenPortBase: _listenPortBase,
      bootstrapPeers: _bootstrapPeers,
      obfs4Psk: _obfs4Psk,
      udpReflectors: _udpReflectors,
      lazyMining: _lazyMining,
      proxy: _proxy,
    );
    for (final spec in specs) {
      // Each identity's storage view routes its ops to the shared backing's
      // worker isolate (off the UI thread) via AsyncMultiSpaceKvLogStore.
      final storage = HiddenVolumeStorage.fromAsyncStore(
        AsyncMultiSpaceKvLogStore(_backing, spec.spaceId),
      );
      // Same tier the single-space boot uses — without it this identity cannot
      // read the large files it already stored (XV-02).
      final blobRoot = _blobRoot;
      if (blobRoot != null) storage.useOnDiskTier(blobRoot);
      _storages[spec.label] = storage;
      try {
        // Bound the boot: a node that can't bind its port (e.g. one just freed
        // by a previous mode) otherwise retries the admin-connect for ~90s and
        // would hang the whole unlock. On timeout we skip it (best-effort).
        //
        // `Future.timeout` abandons the WAIT, not the WORK (audit XV-05): the
        // boot keeps running, and a node that finishes late used to land
        // nowhere — not in `_nodes`, so `disposeAll` never stopped it. It kept
        // its port, its sockets and its network presence for the life of the
        // process, invisible to the only code that could shut it down.
        //
        // The boot future is therefore tracked, and a late arrival is stopped
        // rather than dropped. The `whenComplete` runs on the ORIGINAL future,
        // so it fires for the late case too.
        final booting = _boot(spec, storage);
        final IdentityNode node;
        try {
          node = await booting.timeout(_bootTimeout);
        } on TimeoutException {
          // The boot is still running and we are no longer waiting for it.
          // Attach the reaper HERE, not before the await: registered up front
          // it fires ahead of the success continuation and disposes a node we
          // actually wanted.
          unawaited(
            booting.then(
              (stranded) async {
                try {
                  await stranded.dispose();
                } catch (_) {}
              },
              onError: (_) {},
            ),
          );
          rethrow;
        }
        _nodes[spec.label] = node;
        _messaging[spec.label] =
            MessagingService(
                node.transport,
                storage,
                anonymous: spec.anonymous,
                streamRangeParallelism: xveilConfiguredStreamRangeParallelism(),
                streamRangeEnabled: xveilConfiguredStreamRangeEnabled(),
                p2pStreamAllowed: (peer) async {
                  final contact = await storage.getContact(peer);
                  final global = p2pGlobalPolicyFromName(
                    await storage.getSetting(kP2PGlobalPolicySettingKey),
                  );
                  return p2pPolicyAllows(
                    global: global,
                    override:
                        contact?.p2pOverride ?? kDefaultContactP2POverride,
                    contactKnown: contact != null,
                    contactAccepted: contact?.status == ContactStatus.accepted,
                    contactBlocked: contact?.status == ContactStatus.blocked,
                    localAnonymous: spec.anonymous,
                  );
                },
              )
              ..sourceOpener =
                  veilSourceOpener // DURABLE offers: re-open by path
              ..start();
      } catch (_) {
        // Node didn't come up — keep the storage view so the UI shows history;
        // this identity just can't send/receive live until re-booted.
      }
    }
    await _vacuumOpenedSpaces(specs);
  }

  /// Erase what deletion only unlinked, for every space this unlock opened.
  ///
  /// The constant-time open used to do this inline, and that leaked: the scrub's
  /// duration depends on the space's history, so a real space took measurably
  /// longer to open than a decoy, and the equalized scan that hides which
  /// password was right stopped hiding it (audit HV-02).
  ///
  /// So it runs HERE instead — after every node has booted, well past the point
  /// where any timing still attaches to the unlock decision. It is not optional
  /// work: skip it and values a previous session deleted stay decryptable to
  /// anyone who later obtains the password and an old snapshot of the file.
  ///
  /// Best-effort per space, like the boot loop above: a scrub that faults must
  /// not cost the user the identities that opened fine.
  Future<void> _vacuumOpenedSpaces(List<IdentityBootSpec> specs) async {
    for (final spec in specs) {
      try {
        await _backing.vacuumOrphans(spec.spaceId);
      } catch (_) {
        /* the space is open and usable; the scrub retries next unlock */
      }
    }
  }

  /// Tear down all messaging pipelines and nodes, then release the shared lock.
  ///
  /// Best-effort and lock-release-unconditional (mirrors [bootAll]'s guarded
  /// loop): if one per-element teardown faults (an FFI close on an already-freed
  /// handle, a native stop panic), the remaining elements still dispose, the
  /// maps still clear, and — critically — `_backing.close()` still runs to
  /// release the shared container LOCK_EX. Without this guard a single throwing
  /// dispose aborted the whole chain, left the lock held, and wedged the next
  /// unlock.
  Future<void> disposeAll() async {
    for (final m in _messaging.values) {
      try {
        await m.dispose();
      } catch (_) {
        /* keep tearing down */
      }
    }
    for (final n in _nodes.values) {
      try {
        await n.dispose();
      } catch (_) {
        /* keep tearing down */
      }
    }
    _messaging.clear();
    _nodes.clear();
    _storages.clear();
    try {
      await _backing.close();
    } catch (_) {
      /* lock release is best-effort */
    }
  }
}
