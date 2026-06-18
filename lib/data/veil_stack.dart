import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'native_libs.dart' show processLibFor;
import 'node/embedded_node.dart';
import 'node/node_controller.dart';
import 'node/proxy_routing.dart';
import 'node/veil_node.dart';
import 'storage/storage.dart';
import 'transport/bootstrap_invite.dart';
import 'transport/veil_flutter_transport.dart';
import 'transport/veil_transport.dart';

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

/// The composed real veil stack the app runs: a started node ([controller]), a
/// connected overlay [transport], this device's shareable [myInvite], and
/// contact redemption ([addContact]).
///
/// Two ways to build it:
/// - [startDeniable] (production): the node identity lives INSIDE the unlocked
///   deniable container; the node boots deferred and gets its config applied in
///   memory, so nothing identity-bearing is written to a `config.toml`. Invite
///   creation + join run over the node's own IPC.
/// - [start] (legacy dev path): boots from a pre-existing `config.toml` and
///   shells out to `veil-cli` for invite/join. Kept for the env-var dev flow.
class RealVeilStack {
  RealVeilStack._({
    required this.controller,
    required this.transport,
    required this.myInvite,
    String? veilCliPath,
    String? configPath,
    VeilFlutterTransport? nodeIpc,
  })  : _cli = veilCliPath,
        _config = configPath,
        _flutterTransport = nodeIpc;

  final NodeController controller;
  final VeilTransport transport;
  final BootstrapInvite myInvite;

  // Legacy file path uses veil-cli + a config file for invite/join...
  final String? _cli;
  final String? _config;
  // ...the deniable path uses the node's own IPC instead.
  final VeilFlutterTransport? _flutterTransport;

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
    bool anonymous = false,
    List<BootstrapPeerCfg> bootstrapPeers = const [],
    String? obfs4Psk,
    ProxyRouting proxy = ProxyRouting.disabled,
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

    // 1. Load this identity's node config, or mine + store it on first run.
    final String identityToml;
    final existing = await storage.loadNodeConfig();
    if (existing != null) {
      identityToml = existing;
    } else {
      debugPrint('xVeil[deniable]: mining node identity (first run)…');
      // Canonical-difficulty PoW is CPU-heavy. Run it on a separate isolate so
      // the UI thread stays responsive (the "setting up" screen animates). The
      // worker isolate re-opens the dylib itself (from VEIL_FFI_DYLIB) rather
      // than relying on the parent's load being visible via process(), which is
      // not guaranteed across isolates. The explicit-lib path (tests) mines
      // inline.
      identityToml = lib == null
          ? await Isolate.run(_mineConfigInIsolate)
          : EmbeddedNode.mineConfig(0, lib: lib);
      await storage.saveNodeConfig(identityToml);
    }
    debugPrint('xVeil[deniable]: identity ready (${identityToml.length} B) '
        '[+${lap()}ms config]');

    // 2. Ephemeral, identity-free runtime endpoints.
    await Directory(runtimeDir).create(recursive: true);
    final ipcSock = '$runtimeDir/app.sock';
    final adminSock = '$runtimeDir/admin.sock';
    final listen = 'tcp://127.0.0.1:$listenPort';

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
    final fullConfig = EmbeddedNode.composeConfig(
      identityToml: identityToml,
      listenTransport: listen,
      ipcSocket: ipcSock,
      adminSocket: adminSock,
      lib: lib,
      anonymous: anonymous,
      bootstrapPeers: bootstrapPeers,
      obfs4PskFile: obfs4PskFile,
      proxy: proxy,
    );
    if (proxy.isActive) {
      // Proxy services spawn from the APPLIED config (spawn_all_services runs on
      // apply-config reload too), so unlike [anonymity] this needs no stub
      // boot-arming — the composed config above carries the [proxy.*] sections.
      debugPrint('xVeil[deniable]: traffic routing — socks5=${proxy.socks5Active} '
          'exit=${proxy.exitEnabled}');
    }
    if (bootstrapPeers.isNotEmpty) {
      debugPrint('xVeil[deniable]: dialing ${bootstrapPeers.length} '
          'bootstrap peer(s) from config');
    }
    if (anonymous) {
      // Anonymity must be armed at BOOT (passed to startDeferred below), not via
      // applyConfig: veil pins `[anonymity]` at node start and a reload does not
      // re-apply it. The onion descriptor is sealed against the LIVE identity, so
      // arming the stub anonymous + applying the real identity makes the node
      // onion-reachable under its real identity (the throwaway stub identity is
      // never published — publish is periodic, not at boot). See
      // veil build_stub_config_with_ephemeral_identity / veil_node_start_deferred.
      debugPrint('xVeil[deniable]: anonymous routing — arming onion at boot '
          '(resolves to the real identity after apply-config)');
    }
    debugPrint('xVeil[deniable]: composed config [+${lap()}ms], '
        'booting deferred @ $adminSock');

    // 4. Boot deferred (anonymity armed in the stub when requested), then apply
    // the real config IN MEMORY (no file) to promote the real identity.
    final controller = EmbeddedNodeController(
      appSocketPath: ipcSock,
      starter: () {
        // Split the two FFI steps so the log distinguishes a slow admin BIND
        // (startDeferred) from a slow admin CONNECT/apply (applyConfig holds the
        // ~90s connect-retry — a big number here is the port-bind stall).
        final ssw = Stopwatch()..start();
        final node =
            EmbeddedNode.startDeferred(adminSock, anonymous: anonymous, lib: lib);
        final tDeferred = ssw.elapsedMilliseconds;
        node.applyConfig(fullConfig);
        debugPrint('xVeil[deniable]: startDeferred +${tDeferred}ms, '
            'applyConfig +${ssw.elapsedMilliseconds - tDeferred}ms');
        return node;
      },
    );
    await controller.start();
    // This lap is the suspect for a slow switch: startDeferred + applyConfig
    // (admin bind/connect) + the readiness poll. A large value here with a
    // mining-free identity points at a port-bind stall, not PoW.
    debugPrint('xVeil[deniable]: controller phase=${controller.current.phase}'
        ' msg=${controller.current.message} [+${lap()}ms boot+connect]');
    if (controller.current.phase != NodePhase.connected) {
      throw StateError(
          'deniable node did not connect: ${controller.current.phase}'
          ' (${controller.current.message})');
    }

    // 5. Connect the transport, then ask the running node for its own invite.
    final VeilFlutterTransport transport;
    try {
      transport = await VeilFlutterTransport.connect(ipcSock);
    } catch (e) {
      await controller.stop();
      rethrow;
    }
    // IDENTITY-ONLY invite: the deniable node always binds its listener on
    // loopback (`tcp://127.0.0.1:$listenPort`), so its direct-dial address is
    // never reachable by a contact. Strip it — peers reach this node by node_id
    // over the rendezvous network, not by dialing an address. (Sharing real
    // bootstrap peers is a separate, opt-in action; never the loopback.)
    final veilInvite = BootstrapInvite.parse(await transport.createInvite());
    final invite = BootstrapInvite(
      publicKey: veilInvite.publicKey,
      nonce: veilInvite.nonce,
      algo: veilInvite.algo,
      transport: null,
    );
    debugPrint('xVeil[deniable]: connected + identity-only invite ready');

    return RealVeilStack._(
      controller: controller,
      transport: transport,
      myInvite: invite,
      nodeIpc: transport,
    );
  }

  /// Legacy dev boot from an existing `config.toml`. [embedded] runs the node
  /// in-process; otherwise it spawns `veil-cli node run`.
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
      throw StateError('node did not reach connected: ${controller.current.phase}');
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
  /// legacy file path.
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
  }
}
