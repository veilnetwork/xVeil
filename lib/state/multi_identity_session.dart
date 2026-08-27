import 'dart:io';
import '../data/serve_source.dart';
// Clean public param names are worth more than initializing-formal terseness
// for this small orchestration constructor.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../data/node/bundled_seeds.dart'
    show IdentityPeers, kBundledSeedsDefault;
import '../data/node/bundled_seeds_prefs.dart' show planIdentitySeeds;
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
import 'ratchet_persistence.dart' show ratchetPersistenceFor;
import 'package:xveil/core/log.dart';

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
    this.useBundledSeeds = kBundledSeedsDefault,
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

  /// THIS identity's answer to the shared-seed question, read from its own
  /// space — not the session's, and not the profile's.
  ///
  /// Per spec, because it has to be: with several identities online at once a
  /// single session-wide answer was resolved once and handed to every node, so
  /// two identities could not disagree and the last write won for all of them.
  /// It decides `builtin_seed_policy` in the composed config, which is the half
  /// [bootstrapPeers] cannot express — an empty list alone is the condition
  /// under which veil dials its compiled-in seeds anyway.
  final bool useBundledSeeds;

  /// Built from [useBundledSeeds], per identity — a refuser's spec never holds
  /// the shared descriptors at all, so nothing downstream has an address it
  /// could decide to fall back to.
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

/// No peer list at all — the default for a session nobody handed one to (tests,
/// and any build with neither operator peers nor bundled seeds). Deliberately
/// not "the shared list": a default that hands out addresses is how one
/// identity's answer reached another's node.
List<BootstrapPeerCfg> _noPeers(bool useBundledSeeds) =>
    const <BootstrapPeerCfg>[];

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

/// This identity's storage view over the already-open space, by space id.
///
/// The plan needs it because the shared-seed answer lives in the SPACE: the
/// storage exists as soon as the space is open, which is before any node boots,
/// so the peer list can be built per identity rather than handed down whole.
/// The session hands over its own cache, so the view the plan reads is the very
/// one the boot then uses.
typedef IdentityStorage = Storage Function(int spaceId);

/// Plan the boots for a whole roster over a shared [backing]: open each
/// identity's space (hosting it), read that identity's own shared-seed answer
/// out of it, and assign it a distinct runtime dir + listen port (offset by
/// index) so N nodes can run at once on one host. Pure aside from
/// `backing.openSpace` and that read, so it is unit-testable with a fake
/// backing.
///
/// [peersFor] BUILDS the list from each identity's answer instead of taking one
/// finished list for the session. That list used to be resolved once, from the
/// profile preference, and stamped onto every spec — so an identity that had
/// refused the shared seeds was handed them anyway whenever another identity in
/// the same session had not.
Future<List<IdentityBootSpec>> planIdentityBoots(
  List<RosterEntry> roster,
  AsyncMultiSpaceBacking backing, {
  required String runtimeDirBase,
  required int listenPortBase,
  required IdentityStorage storageFor,
  required IdentityPeers peersFor,
  String? obfs4Psk,
  List<String> udpReflectors = const [],
  bool lazyMining = false,
  ProxyRouting proxy = ProxyRouting.disabled,
}) async {
  final out = <IdentityBootSpec>[];
  for (var i = 0; i < roster.length; i++) {
    final spaceId = await backing.openSpace(roster[i].spaceKeys);
    final seeds = await planIdentitySeeds(
      storage: storageFor(spaceId),
      peersFor: peersFor,
    );
    out.add(
      IdentityBootSpec(
        label: roster[i].label,
        spaceId: spaceId,
        useBundledSeeds: seeds.useBundledSeeds,
        bootstrapPeers: seeds.bootstrapPeers,
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
    // Already resolved from THIS identity's space when the plan was made, over
    // the same storage view. Passed rather than re-read so the policy line and
    // the peer list above cannot come from two different answers.
    useBundledSeeds: spec.useBundledSeeds,
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
    Duration disposeBudget = _defaultDisposeBudget,
    IdentityPeers peersFor = _noPeers,
    String? obfs4Psk,
    List<String> udpReflectors = const [],
    bool lazyMining = false,
    ProxyRouting proxy = ProxyRouting.disabled,
    IdentityNodeBoot boot = _realBoot,
  }) : _runtimeDirBase = runtimeDirBase,
       _listenPortBase = listenPortBase,
       _blobRoot = blobRoot,
       _bootTimeout = bootTimeout,
       _disposeBudget = disposeBudget,
       _peersFor = peersFor,
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

  /// Builds one identity's peer list from ITS answer. A finished list would be
  /// the defect: it can only be built once, from one answer, for everybody.
  final IdentityPeers _peersFor;

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

  /// Per-element teardown deadline — see [disposeAll] for why one exists.
  static const _defaultDisposeBudget = Duration(seconds: 10);
  final Duration _bootTimeout;

  final _storages = <String, Storage>{};
  final _nodes = <String, IdentityNode>{};
  final _messaging = <String, MessagingService>{};

  /// The shared-seed answer each identity's node was actually booted with,
  /// resolved from that identity's own space.
  ///
  /// Kept so the UI can follow a switch without re-reading the container: the
  /// screens render the live value, and leaving it on the previously shown
  /// identity's answer is the same misstatement the per-space answer exists to
  /// end. Null for an identity this session never planned.
  final _bundledSeeds = <String, bool>{};
  bool? usesBundledSeeds(String label) => _bundledSeeds[label];

  List<String> get labels => _storages.keys.toList(growable: false);
  Storage? storageFor(String label) => _storages[label];
  RealVeilStack? stackFor(String label) => _nodes[label]?.stack;
  MessagingService? messagingFor(String label) => _messaging[label];

  /// Open every identity's space over the shared backing, boot its node, and
  /// wire its own messaging pipeline (transport + storage) so it receives
  /// concurrently. Best-effort per identity: a boot failure logs and skips that
  /// identity's node/messaging but keeps its storage view hosted.
  Future<void> bootAll(List<RosterEntry> roster) async {
    // One view per space, made where the space is opened and reused by the boot.
    //
    // The plan needs it: an identity's shared-seed answer lives in ITS space,
    // and the answer decides the peer list its node is composed with. Building
    // the view here — rather than after planning, as the loop used to — is what
    // makes "before its node boots" true, and hands the plan and the boot the
    // SAME handle, so a migration written during the plan is visible to the boot.
    final views = <int, Storage>{};
    Storage viewOf(int spaceId) => views.putIfAbsent(spaceId, () {
      // Each identity's storage view routes its ops to the shared backing's
      // worker isolate (off the UI thread) via AsyncMultiSpaceKvLogStore.
      final storage = HiddenVolumeStorage.fromAsyncStore(
        AsyncMultiSpaceKvLogStore(_backing, spaceId),
      );
      // Same tier the single-space boot uses — without it this identity cannot
      // read the large files it already stored (XV-02).
      final blobRoot = _blobRoot;
      if (blobRoot != null) storage.useOnDiskTier(blobRoot);
      return storage;
    });
    final specs = await planIdentityBoots(
      roster,
      _backing,
      runtimeDirBase: _runtimeDirBase,
      listenPortBase: _listenPortBase,
      storageFor: viewOf,
      peersFor: _peersFor,
      obfs4Psk: _obfs4Psk,
      udpReflectors: _udpReflectors,
      lazyMining: _lazyMining,
      proxy: _proxy,
    );
    for (final spec in specs) {
      final storage = viewOf(spec.spaceId);
      _storages[spec.label] = storage;
      _bundledSeeds[spec.label] = spec.useBundledSeeds;
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
            booting.then((stranded) async {
              try {
                await stranded.dispose();
              } catch (_) {}
            }, onError: (_) {}),
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
              // Per identity, over THIS identity's own storage and its own
              // node. Sharing either would put one identity's chain keys in
              // another's container, which is the whole thing separate spaces
              // exist to prevent.
              ..ratchet = ratchetPersistenceFor(node.stack, storage)
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
  ///
  /// A dispose that never RETURNS costs exactly what a throwing one did, and
  /// only the throw was handled. Messaging teardown waits for the inbound lanes
  /// to go quiet, for native serve/pull streams to join, and for a last ratchet
  /// flush — all of which reach the node over IPC, and a node whose IPC is
  /// wedged makes every one of them wait forever. Nodes are disposed AFTER
  /// messaging, so the node then never stops, the lock is never released, and
  /// whatever asked for the teardown waits behind it: storage compaction sat on
  /// "opening the store" for half an hour with the repack not even begun, and
  /// lock/wipe take this same path.
  ///
  /// So each element gets a deadline. Abandoning a hung dispose leaves its work
  /// running, which is why the budget is generous — but a straggler that fails
  /// its next write is recoverable (container writes are atomic per commit) and
  /// a container that never unlocks again is not.
  final Duration _disposeBudget;

  /// Teardown steps abandoned by the most recent [disposeAll].
  ///
  /// Abandoning is deliberate — a container that never unlocks again is worse
  /// than a straggler — but it is not free, and it used to be invisible outside
  /// a debug log. A node dispose that never returned left the node RUNNING:
  /// holding its sockets and its network identity, still reachable, while the
  /// handle was dropped from the maps here so nothing could even ask it to stop
  /// again. The caller says "locked" at that point, and locked is a claim about
  /// exactly this.
  ///
  /// Empty means every step finished. Non-empty is a fact whoever declares the
  /// session gone has to carry — see `AppController._teardownSession`.
  List<String> get abandonedTeardowns => List.unmodifiable(_abandoned);
  final List<String> _abandoned = [];

  /// Whether the container's lock was RELEASED, as opposed to attempted.
  ///
  /// The close is best-effort by design; what it must not be is invisible. A
  /// close that failed or ran out of time leaves the lock held, and every
  /// caller that goes on to declare the session gone — lock, wipe, start over
  /// — is making a claim about exactly this (report17 XV17-M14).
  bool get containerLockReleased => _containerLockReleased;
  bool _containerLockReleased = true;

  Future<bool> _bounded(String what, Future<void> Function() step) async {
    try {
      await step().timeout(_disposeBudget);
      return true;
    } on TimeoutException {
      _abandoned.add(what);
      devLog(
        () =>
            'xVeil[all-online]: $what did not finish in '
            '${_disposeBudget.inSeconds}s — abandoned so the rest of the '
            'teardown can still release the container lock',
      );
      return false;
    } catch (e) {
      // Recorded, not merely survived. A dispose that THREW left the same
      // thing running as one that timed out — a node with its sockets and its
      // network identity, with its handle already dropped from the maps here
      // — and only the timeout was carried out of this class
      // (report17 XV17-M14).
      _abandoned.add('$what failed: $e');
      devLog(() => 'xVeil[all-online]: $what failed: $e');
      return false;
    }
  }

  Future<void> disposeAll() async {
    _abandoned.clear();
    _containerLockReleased = true;
    for (final entry in _messaging.entries) {
      await _bounded('messaging dispose (${entry.key})', entry.value.dispose);
    }
    for (final entry in _nodes.entries) {
      await _bounded('node dispose (${entry.key})', entry.value.dispose);
    }
    _messaging.clear();
    _nodes.clear();
    _storages.clear();
    _bundledSeeds.clear();
    try {
      await _backing.close().timeout(_disposeBudget);
    } catch (e) {
      // Best-effort by design — one identity's failed teardown must not cost
      // the rest — but no longer SILENT: the backing now says when the
      // container's lock is still held (a worker that would not close in time,
      // or that died mid-close), and that is the fact behind every later
      // "correct password but won't unlock".
      _containerLockReleased = false;
      devLog(() => 'xVeil[all-online]: container lock release failed: $e');
    }
  }
}
