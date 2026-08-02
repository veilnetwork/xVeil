import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';


import 'native_libs.dart' show processLibFor;
import 'node/embedded_node.dart';
import 'node/node_controller.dart';
import 'node/proxy_routing.dart';
import 'node/veil_node.dart';
import 'storage/storage.dart';
import 'transport/bootstrap_invite.dart';
import 'transport/veil_flutter_transport.dart';
import 'transport/veil_transport.dart';
import 'package:xveil/core/log.dart';

/// Thrown when the runtime directory cannot be made owner-only.
///
/// Carried as its own type so the boot path can report it as a refusal rather
/// than as a generic I/O failure — the distinction the operator needs is
/// "we declined to start" versus "the disk is broken".
class RuntimeDirNotPrivate implements Exception {
  RuntimeDirNotPrivate(this.dir, this.reason);

  final String dir;
  final String reason;

  @override
  String toString() =>
      'runtime directory $dir cannot be made owner-only ($reason); refusing to '
      'put the node control socket there';
}

/// Whether a failure to secure the runtime directory must stop the boot.
///
/// On macOS and Linux the path can sit on a filesystem other local users
/// share, so an unprotected directory is a real exposure and we refuse. On
/// Android and iOS the directory is inside the app sandbox — the OS is already
/// the boundary — and on Windows access is governed by the profile ACL, which
/// a POSIX mode cannot describe and this code does not attempt to set. Failing
/// the boot on those platforms would trade a guarantee they already have for
/// an outage.
bool runtimeDirMustBePrivate() => Platform.isMacOS || Platform.isLinux;

Future<ProcessResult> _chmod700(String dir) => Process.run('chmod', ['700', dir]);

/// Name of the file that marks a directory as one xVeil created and may delete.
///
/// The runtime base comes from `XVEIL_RUNTIME_DIR` when set, and teardown
/// removes it RECURSIVELY. Nothing checked that the path was ours, so a wrong
/// launcher entry — or an env var set by anything else in the session — turned
/// lock/wipe into a recursive delete of whatever it pointed at (audit X-12).
///
/// A marker file is the cheap version of ownership: we write it when we set the
/// directory up, and refuse to recursively delete a directory that does not
/// carry it. It does not defend against an attacker who can write inside the
/// directory — nothing at this layer could — but that is not the failure mode.
/// The one that actually happens is a path that was never ours.
const kRuntimeDirMarker = '.xveil-runtime';

/// Mark [dir] as ours, creating it if needed. Safe to call repeatedly.
Future<void> markRuntimeDirOwned(String dir) async {
  await Directory(dir).create(recursive: true);
  await File('$dir/$kRuntimeDirMarker').writeAsString(
    'Created by xVeil. Deleting this file makes xVeil leave the directory '
    'alone on teardown instead of removing it.\n',
  );
}

/// Whether [dir] carries our marker — i.e. may be removed recursively.
///
/// A missing directory answers false: there is nothing to delete, and saying
/// "yes" would make the caller's guard look like it passed.
bool runtimeDirIsOurs(String dir) =>
    File('$dir/$kRuntimeDirMarker').existsSync();

/// Create the node's runtime directory owner-only, or refuse to use it.
///
/// It holds `admin.sock` — the node's CONTROL socket — next to `app.sock` and
/// the obfs4 PSK. `Directory.create` leaves the mode at the process umask,
/// which on a typical desktop is world-readable, so on a shared machine
/// another local user could reach the admin endpoint of someone else's node.
///
/// Three things this does that the old best-effort `chmod` did not:
///
///   * **refuses a symlink.** `Directory.create` follows one, so a link
///     planted at the runtime path redirected the control socket into a
///     directory the attacker owns. Checked with `followLinks: false` before
///     anything is created.
///   * **verifies the result** by reading the mode back, instead of trusting
///     that `chmod` exiting zero means the filesystem honoured it. Mounted
///     shares and some vendor mounts accept the call and keep the old mode.
///   * **fails closed** where it matters ([runtimeDirMustBePrivate]) instead
///     of logging and carrying on. A hardening step that only logs is a
///     comment claiming something untrue.
///
/// Residual window, stated plainly: between `create` and `chmod` the directory
/// exists at the umask. It is empty for that instant — the sockets and the PSK
/// are written afterwards, by the caller, only once this returns — so the
/// window exposes an empty directory, not a secret. Closing it entirely needs
/// `mkdir(2)` with a mode, which Dart does not expose.
Future<void> createRestrictedRuntimeDir(String dir) async {
  if (FileSystemEntity.typeSync(dir, followLinks: false) ==
      FileSystemEntityType.link) {
    throw RuntimeDirNotPrivate(dir, 'path is a symlink');
  }
  await Directory(dir).create(recursive: true);
  await restrictRuntimeDir(dir);
}

/// Apply and VERIFY the owner-only mode on an existing directory.
///
/// Split from [createRestrictedRuntimeDir] so the check is reachable on a
/// directory the caller made itself, and so tests can hand it a deliberately
/// permissive one.
/// [chmod] exists for tests only. A filesystem that accepts the call and keeps
/// the old mode is the case the read-back guards against, and there is no way
/// to produce one on demand — so it is injected rather than described, and the
/// verification stays covered.
Future<void> restrictRuntimeDir(
  String dir, {
  Future<ProcessResult> Function(String dir)? chmod,
}) async {
  if (Platform.isWindows) return;
  String? failure;
  try {
    final result = await (chmod ?? _chmod700)(dir);
    if (result.exitCode != 0) {
      failure = 'chmod exited ${result.exitCode}: ${result.stderr}';
    }
  } catch (e) {
    failure = 'chmod could not be run: $e';
  }

  // Read the mode back rather than believing the exit code. This is the check
  // that catches a filesystem which accepts chmod and ignores it.
  if (failure == null) {
    try {
      final mode = Directory(dir).statSync().mode;
      if (mode & 0x3F != 0) {
        failure =
            'mode is ${(mode & 0x1FF).toRadixString(8)} after chmod, not 700';
      }
    } catch (e) {
      failure = 'could not stat the directory back: $e';
    }
  }

  if (failure == null) return;
  if (runtimeDirMustBePrivate()) {
    throw RuntimeDirNotPrivate(dir, failure);
  }
  devLog(
    () =>
        'xVeil[deniable]: $dir is not owner-only ($failure) — the OS sandbox '
        'is the boundary on this platform, continuing',
  );
}

/// Register every application-supplied seed on the already-running node.
///
/// Deferred boot applies the real config as a reload. The native runtime keeps
/// its boot-time builtin connectors, but a reload does not spawn outbound
/// connector tasks for newly appended `[[bootstrap_peers]]`. Consequently a
/// seed present only in the bundled/runtime list could remain visible in the
/// composed config without ever being dialled. Redeeming the same public
/// descriptor over IPC closes that lifecycle gap; already-known builtin seeds
/// are harmless refreshes and one bad seed never blocks the rest.
Future<int> registerRuntimeBootstrapPeers(
  List<BootstrapPeerCfg> peers,
  Future<void> Function(String uri) join,
) async {
  var registered = 0;
  for (final peer in peers) {
    final uri =
        'veil:bootstrap?pk=${peer.publicKey}'
        '&t=${peer.transport}'
        '&a=${peer.algo}'
        '&nc=${peer.nonce}';
    try {
      await join(uri);
      registered++;
    } catch (e) {
      devLog(
        () =>
            'xVeil[bootstrap]: runtime seed registration failed '
            'transport=${peer.transport.split(':').first} '
            'error=${e.runtimeType}',
      );
    }
  }
  return registered;
}

/// Mine a node identity in a worker isolate. Re-opens the veil dylib INSIDE the
/// isolate (the parent's load is not guaranteed visible across isolates): from
/// `VEIL_FFI_DYLIB` when set (desktop/tests), else [processLibFor] — which on
/// Android `dlopen`s `libveilclient_ffi.so` by name (its symbols are LOCAL to
/// that handle, NOT in the global `DynamicLibrary.process()` table, so a
/// process() lookup of `veil_config_init` fails with "undefined symbol").
/// Top-level so it is a valid `Isolate.run` entry point.
String _mineConfigInIsolate() {
  final path = Platform.environment['VEIL_FFI_DYLIB'];
  final lib = (path != null && path.isNotEmpty && File(path).existsSync())
      ? DynamicLibrary.open(path)
      : processLibFor('veilclient_ffi');
  return EmbeddedNode.mineConfig(0, lib: lib);
}

/// Same isolate-entry contract as [_mineConfigInIsolate], but the identity is
/// DERIVED from the onboarding master phrase (only the anti-sybil nonce is
/// mined) — see EmbeddedNode.configFromPhrase.
String _configFromPhraseInIsolate(String phrase) {
  final path = Platform.environment['VEIL_FFI_DYLIB'];
  final lib = (path != null && path.isNotEmpty && File(path).existsSync())
      ? DynamicLibrary.open(path)
      : processLibFor('veilclient_ffi');
  return EmbeddedNode.configFromPhrase(phrase, lib: lib);
}

/// The composed real veil stack the app runs: a started node ([controller]), a
/// connected overlay [transport], this device's shareable [myInvite], and
/// contact redemption ([addContact]).
///
/// Two ways to build it:
/// - [startDeniable] (production): the node identity lives INSIDE the unlocked
///   deniable container; the node boots deferred and gets its config applied in
///   memory, so nothing identity-bearing is written to a `config.toml`. Invite
///   creation + join run over the node's own IPC.
/// - [start] (config-file dev path): boots from a pre-existing `config.toml`
///   and shells out to `veil-cli` for invite/join. Not deprecated — it is what
///   `scripts/run-real-instance.sh`, `run-deniable-instance.sh` and
///   `dev-real-pair.sh` still use, and `doc/REAL-MODE.md` documents.
class RealVeilStack {
  RealVeilStack._({
    required this.controller,
    required this.transport,
    required this.myInvite,
    String? veilCliPath,
    String? configPath,
    VeilFlutterTransport? nodeIpc,
    this._runtimeDir,
    this.listenPort = 0,
    this.lanListen = false,
    this.listenScheme = 'tcp',
  }) : _cli = veilCliPath,
       _config = configPath,
       _flutterTransport = nodeIpc;

  final NodeController controller;
  final VeilTransport transport;
  final BootstrapInvite myInvite;

  /// The port this instance's node listener is bound on, and whether that bind
  /// is LAN-wide (`0.0.0.0`, P2P policy allowed it) or loopback-only. The P2P
  /// endpoint service combines [listenPort] with the device's LAN addresses to
  /// mint the direct-dial URIs it shares with consenting contacts; when
  /// [lanListen] is false it shares nothing (nobody could dial us anyway).
  final int listenPort;
  final bool lanListen;

  /// Scheme of the actual peer listener. P2P endpoint exchange must preserve
  /// it: advertising `tcp://` for a QUIC socket silently falls back to the
  /// ordered stream path and reintroduces video head-of-line stalls.
  final String listenScheme;

  // The config-file dev path uses veil-cli + a config file for invite/join.
  final String? _cli;
  final String? _config;
  // ...the deniable path uses the node's own IPC instead.
  final VeilFlutterTransport? _flutterTransport;
  // The ephemeral runtime dir (sockets + public PSK). Deleted on dispose so it
  // leaves NO at-rest artifact — see [dispose].
  final String? _runtimeDir;

  /// Step 1 of the deniable boot, extracted so the provenance contract is
  /// unit-testable: load the stored node config, or provision + store one on
  /// first run — derived from [identityPhrase] when given, mined at random
  /// otherwise. Records [kIdentityOriginSetting] ('phrase'/'mined') alongside
  /// a FRESH provision only, so the honest "no phrase" state of a space
  /// provisioned before the marker existed is never overwritten.
  static Future<String> ensureNodeConfig(
    Storage storage, {
    String? identityPhrase,
    DynamicLibrary? lib,
  }) async {
    final existing = await storage.loadNodeConfig();
    if (existing != null) return existing;
    final String identityToml;
    final String origin;
    if (identityPhrase != null && identityPhrase.isNotEmpty) {
      devLog(
        () =>
            'xVeil[deniable]: deriving node identity from phrase '
            '(first run)…',
      );
      // Phrase-derived identity (P2): the keypair is deterministic, only the
      // nonce search burns CPU — still off the UI isolate like the mine.
      final phrase = identityPhrase;
      identityToml = lib == null
          ? await Isolate.run(() => _configFromPhraseInIsolate(phrase))
          : EmbeddedNode.configFromPhrase(phrase, lib: lib);
      origin = 'phrase';
    } else {
      devLog(() => 'xVeil[deniable]: mining node identity (first run)…');
      // Canonical-difficulty PoW is CPU-heavy. Run it on a separate isolate so
      // the UI thread stays responsive (the "setting up" screen animates). The
      // worker isolate re-opens the dylib itself (from VEIL_FFI_DYLIB) rather
      // than relying on the parent's load being visible via process(), which is
      // not guaranteed across isolates. The explicit-lib path (tests) mines
      // inline.
      identityToml = lib == null
          ? await Isolate.run(_mineConfigInIsolate)
          : EmbeddedNode.mineConfig(0, lib: lib);
      origin = 'mined';
    }
    await storage.saveNodeConfig(identityToml);
    await storage.putSetting(kIdentityOriginSetting, origin);
    return identityToml;
  }

  /// Production boot: identity comes from the unlocked [storage] (mined +
  /// stored on first run), the node boots in-process via deferred-init and has
  /// its real config applied in memory — no `config.toml` on disk. [runtimeDir]
  /// holds the ephemeral, identity-free sockets; [listenPort] is this instance's
  /// listener (give two instances on one host distinct ports).
  static Future<RealVeilStack> startDeniable({
    required Storage storage,
    required String runtimeDir,
    DynamicLibrary? lib,
    int listenPort = 9000,
    // P2P direct-session epic: bind the node's listener on all interfaces so
    // LAN contacts can dial the exchanged `tcp://<lan-ip>:<listenPort>`
    // endpoint. Gated by the caller on the P2P policy (never for an anonymous
    // posture, never when policy=denied) — a loopback-only node stays
    // undialable, which is the deniable default.
    bool lanListen = false,
    bool anonymous = false,
    bool lazyMining = false,
    List<BootstrapPeerCfg> bootstrapPeers = const [],
    // Optional post-connect set: activates app-bundled alternatives without
    // injecting them into the deferred reload config. Null reuses the config
    // set, which is the natural behaviour for headless callers.
    List<BootstrapPeerCfg>? runtimeBootstrapPeers,
    List<String> udpReflectors = const [],
    String? obfs4Psk,
    ProxyRouting proxy = ProxyRouting.disabled,
    // Test/headless multi-node runs may host several embedded nodes in one
    // process. Give each one a distinct loopback-only metrics port; ordinary
    // app boots keep the established platform default.
    int? debugMetricsPort,
    // First-run only (onboarding-phrase epic P2): when set and no node config
    // is stored yet, the identity is DERIVED from this master phrase instead
    // of mined at random — node_id becomes deterministic in the phrase, so
    // disaster recovery restores the same identity. Consumed once; the phrase
    // itself is never persisted (the derived [Identity] TOML goes into the
    // deniable container like the mined one always has).
    String? identityPhrase,
  }) async {
    // Time each phase so the log pinpoints where a slow boot/switch goes (the
    // boot is mining-free when the identity already exists, so a slow switch is
    // the node bind/connect, not PoW). Zero-cost diagnostic; reads at a glance.
    final sw = Stopwatch()..start();
    int lap() {
      final ms = sw.elapsedMilliseconds;
      sw.reset();
      return ms;
    }

    // 1. Load this identity's node config, or derive/mine + store it on
    // first run.
    final identityToml = await ensureNodeConfig(
      storage,
      identityPhrase: identityPhrase,
      lib: lib,
    );
    devLog(
      () =>
          'xVeil[deniable]: identity ready (${identityToml.length} B) '
          '[+${lap()}ms config]',
    );

    // 2. Ephemeral, identity-free runtime endpoints.
    await createRestrictedRuntimeDir(runtimeDir);
    // iOS application-container paths exceed sockaddr_un's SUN_LEN on both
    // physical devices and Simulator. Keep discovery sidecars in the sandbox,
    // but carry local admin + IPC over authenticated loopback TCP there.
    final tcpLocalEndpoints = Platform.isIOS;
    final ipcSock = tcpLocalEndpoints
        ? '$runtimeDir/ipc.anchor'
        : '$runtimeDir/app.sock';
    final adminSock = tcpLocalEndpoints
        ? '$runtimeDir/admin.anchor'
        : '$runtimeDir/admin.sock';
    final ipcEndpoint = tcpLocalEndpoints
        ? 'tcp://127.0.0.1:0?runtime_dir=$runtimeDir'
        : ipcSock;
    final adminEndpoint = tcpLocalEndpoints
        ? 'tcp://127.0.0.1:0?runtime_dir=$runtimeDir'
        : adminSock;
    // Direct peer sessions use QUIC even on a LAN. Besides authenticating and
    // encrypting the listener transport, this makes QUIC DATAGRAM available
    // to real-time media; TCP remains supported when dialing older peers.
    const listenScheme = 'quic';
    final listen = lanListen
        ? '$listenScheme://0.0.0.0:$listenPort'
        : '$listenScheme://127.0.0.1:$listenPort';

    // Deployment-wide obfs4 PSK (networks that pin a shared anti-probe key):
    // drop it in the runtime dir and reference it from the config. Identity-free
    // and ephemeral, so it lives alongside the sockets (never in the container).
    String? obfs4PskFile;
    if (obfs4Psk != null && obfs4Psk.isNotEmpty) {
      obfs4PskFile = '$runtimeDir/obfs4_psk.b64';
      await File(obfs4PskFile).writeAsString(obfs4Psk);
    }

    // 3. Compose a full, bootable config (identity + runtime) in memory.
    // INVARIANT: `anonymous` here MUST match the value passed to startDeferred
    // below. veil pins [anonymity] from the STUB boot config; the applied config
    // is a reload that does not re-apply it but DOES warn `config.anonymity.
    // reload_ignored` if its [anonymity] differs from the boot state. Keeping the
    // applied config's anonymity consistent with the stub's avoids that warning.
    var fullConfig = EmbeddedNode.composeConfig(
      identityToml: identityToml,
      listenTransport: listen,
      ipcSocket: ipcEndpoint,
      adminSocket: adminEndpoint,
      lib: lib,
      anonymous: anonymous,
      lazyMining: lazyMining,
      bootstrapPeers: bootstrapPeers,
      udpReflectors: udpReflectors,
      obfs4PskFile: obfs4PskFile,
      proxy: proxy,
    );
    // Debug stands only: loopback Prometheus metrics for the embedded node,
    // the per-node twin of a relay's [metrics] endpoint. Follows the debug
    // hook's gating (compiled out of release; explicit opt-out via the same
    // define family). Never binds a non-loopback interface.
    if (kXVeilDebugBuild &&
        const bool.fromEnvironment('XVEIL_DEBUG_HOOK', defaultValue: true)) {
      fullConfig = EmbeddedNode.withDebugMetrics(
        fullConfig,
        debugMetricsPort ??
            ((Platform.isAndroid || Platform.isIOS) ? 39998 : 39997),
      );
    }
    if (proxy.isActive) {
      // Proxy services spawn from the APPLIED config (spawn_all_services runs on
      // apply-config reload too), so unlike [anonymity] this needs no stub
      // boot-arming — the composed config above carries the [proxy.*] sections.
      devLog(
        () =>
            'xVeil[deniable]: traffic routing — socks5=${proxy.socks5Active} '
            'exit=${proxy.exitEnabled}',
      );
    }
    if (bootstrapPeers.isNotEmpty) {
      devLog(
        () =>
            'xVeil[deniable]: dialing ${bootstrapPeers.length} '
            'bootstrap peer(s) from config',
      );
    }
    if (anonymous) {
      // Anonymity must be armed at BOOT (passed to startDeferred below), not via
      // applyConfig: veil pins `[anonymity]` at node start and a reload does not
      // re-apply it. The onion descriptor is sealed against the LIVE identity, so
      // arming the stub anonymous + applying the real identity makes the node
      // onion-reachable under its real identity (the throwaway stub identity is
      // never published — publish is periodic, not at boot). See
      // veil build_stub_config_with_ephemeral_identity / veil_node_start_deferred.
      devLog(
        () =>
            'xVeil[deniable]: anonymous routing — arming onion at boot '
            '(resolves to the real identity after apply-config)',
      );
    }
    devLog(
      () =>
          'xVeil[deniable]: composed config [+${lap()}ms], '
          'booting deferred @ $adminEndpoint',
    );

    // 4. Boot deferred (anonymity armed in the stub when requested), then apply
    // the real config IN MEMORY (no file) to promote the real identity.
    final controller = EmbeddedNodeController(
      appSocketPath: ipcSock,
      starter: () {
        // Split the two FFI steps so the log distinguishes a slow admin BIND
        // (startDeferred) from a slow admin CONNECT/apply (applyConfig holds the
        // ~90s connect-retry — a big number here is the port-bind stall).
        final ssw = Stopwatch()..start();
        final node = EmbeddedNode.startDeferred(
          adminEndpoint,
          anonymous: anonymous,
          lib: lib,
        );
        final tDeferred = ssw.elapsedMilliseconds;
        node.applyConfig(fullConfig);
        devLog(
          () =>
              'xVeil[deniable]: startDeferred +${tDeferred}ms, '
              'applyConfig +${ssw.elapsedMilliseconds - tDeferred}ms',
        );
        return node;
      },
    );
    await controller.start();
    // This lap is the suspect for a slow switch: startDeferred + applyConfig
    // (admin bind/connect) + the readiness poll. A large value here with a
    // mining-free identity points at a port-bind stall, not PoW.
    devLog(
      () =>
          'xVeil[deniable]: controller phase=${controller.current.phase}'
          ' msg=${controller.current.message} [+${lap()}ms boot+connect]',
    );
    if (controller.current.phase != NodePhase.connected) {
      throw StateError(
        'deniable node did not connect: ${controller.current.phase}'
        ' (${controller.current.message})',
      );
    }

    // 5. Connect the transport, then ask the running node for its own invite.
    final VeilFlutterTransport transport;
    try {
      transport = await VeilFlutterTransport.connect(ipcSock);
    } catch (e) {
      await controller.stop();
      rethrow;
    }
    final seedsToRegister = runtimeBootstrapPeers ?? bootstrapPeers;
    final registeredSeeds = await registerRuntimeBootstrapPeers(
      seedsToRegister,
      transport.joinP2PEndpoint,
    );
    if (seedsToRegister.isNotEmpty) {
      devLog(
        () =>
            'xVeil[bootstrap]: runtime seeds registered '
            '$registeredSeeds/${seedsToRegister.length}',
      );
    }
    // IDENTITY-ONLY invite: the deniable node binds its listener on loopback
    // (or the 0.0.0.0 wildcard when [lanListen]), so the invite's advertise
    // address is never a URI a remote contact could meaningfully dial. Strip
    // it — peers reach this node by node_id over the rendezvous network, not
    // by dialing an address. Real direct-dial endpoints (LAN ip:port) travel
    // separately over the E2E contact channel with mutual P2P consent — see
    // P2PEndpointService — never inside the shareable invite.
    final veilInvite = BootstrapInvite.parse(await transport.createInvite());
    final invite = BootstrapInvite(
      publicKey: veilInvite.publicKey,
      nonce: veilInvite.nonce,
      algo: veilInvite.algo,
      transport: null,
    );
    devLog(() => 'xVeil[deniable]: connected + identity-only invite ready');

    return RealVeilStack._(
      controller: controller,
      transport: transport,
      myInvite: invite,
      nodeIpc: transport,
      runtimeDir: runtimeDir,
      listenPort: listenPort,
      lanListen: lanListen,
      listenScheme: listenScheme,
    );
  }

  /// Dev boot from an existing `config.toml`. [embedded] runs the node
  /// in-process; otherwise it spawns `veil-cli node run`. Still used by the
  /// dev scripts — see the class doc.
  static Future<RealVeilStack> start({
    required String veilCliPath,
    required String configPath,
    required String appSocketPath,
    bool embedded = false,
  }) async {
    final NodeController controller = embedded
        ? EmbeddedNodeController(
            configPath: configPath,
            appSocketPath: appSocketPath,
          )
        : veilSubprocessController(
            veilCliPath: veilCliPath,
            configPath: configPath,
            appSocketPath: appSocketPath,
          );
    await controller.start();
    if (controller.current.phase != NodePhase.connected) {
      throw StateError(
        'node did not reach connected: ${controller.current.phase}',
      );
    }

    final VeilTransport transport;
    try {
      transport = await VeilFlutterTransport.connect(appSocketPath);
    } catch (e) {
      await controller.stop();
      rethrow;
    }

    final invite = await veilBootstrapInvite(
      veilCliPath: veilCliPath,
      configPath: configPath,
    );
    return RealVeilStack._(
      controller: controller,
      transport: transport,
      myInvite: invite,
      veilCliPath: veilCliPath,
      configPath: configPath,
    );
  }

  /// Redeem a peer's invite so this node dials it — forms the bidirectional
  /// session veil's directional dedup needs. (Pair with the peer redeeming
  /// ours.) Uses the node's own IPC on the deniable path, `veil-cli` on the
  /// config-file dev path.
  Future<void> addContact(BootstrapInvite peer) {
    // IDENTITY-ONLY invite (no transport): there is nothing to dial — the
    // contact is reached by node_id over rendezvous, and the chat is keyed by
    // node_id. A `bootstrap join` here would add a useless (or loopback)
    // bootstrap peer. Only redeem invites that actually carry a dialable peer.
    if (peer.transport == null) return Future.value();
    final ft = _flutterTransport;
    if (ft != null) return ft.joinInvite(peer.toUri());
    return veilBootstrapJoin(
      veilCliPath: _cli!,
      configPath: _config!,
      inviteUri: peer.toUri(),
    );
  }

  Future<void> dispose() async {
    await transport.dispose();
    await controller.stop();
    // Deniability: the runtime dir (sockets + the public obfs4 PSK) is named
    // per-identity and would otherwise persist in temp after teardown — a
    // plaintext side-channel revealing that identities ran (and, before the
    // opaque-naming fix, which ones). Remove it now that the node is stopped.
    final dir = _runtimeDir;
    if (dir != null) {
      try {
        final d = Directory(dir);
        if (d.existsSync()) await d.delete(recursive: true);
      } catch (_) {
        // Best-effort — a leftover empty socket dir is not worth failing on.
      }
    }
  }
}
