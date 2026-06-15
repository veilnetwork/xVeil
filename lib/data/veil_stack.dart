import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'node/embedded_node.dart';
import 'node/node_controller.dart';
import 'node/veil_node.dart';
import 'storage/storage.dart';
import 'transport/bootstrap_invite.dart';
import 'transport/veil_flutter_transport.dart';
import 'transport/veil_transport.dart';

/// Mine a node identity in a worker isolate. Opens the veil dylib from
/// `VEIL_FFI_DYLIB` (falling back to the process symbols) so the FFI resolves
/// independently of how the parent isolate loaded it. Top-level so it is a
/// valid `Isolate.run` entry point.
String _mineConfigInIsolate() {
  final path = Platform.environment['VEIL_FFI_DYLIB'];
  final lib = (path != null && path.isNotEmpty && File(path).existsSync())
      ? DynamicLibrary.open(path)
      : DynamicLibrary.process();
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
  }) async {
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
    debugPrint('xVeil[deniable]: identity ready (${identityToml.length} B)');

    // 2. Ephemeral, identity-free runtime endpoints.
    await Directory(runtimeDir).create(recursive: true);
    final ipcSock = '$runtimeDir/app.sock';
    final adminSock = '$runtimeDir/admin.sock';
    final listen = 'tcp://127.0.0.1:$listenPort';

    // 3. Compose a full, bootable config (identity + runtime) in memory.
    final fullConfig = EmbeddedNode.composeConfig(
      identityToml: identityToml,
      listenTransport: listen,
      ipcSocket: ipcSock,
      adminSocket: adminSock,
      lib: lib,
      anonymous: anonymous,
    );
    if (anonymous) {
      // HONESTY GUARD (security-critical for the threat model): anonymous
      // routing is requested but NOT actually in effect on the deniable path.
      // veil pins the `[anonymity]` state (incl. the onion descriptor, which is
      // DERIVED FROM identity_sk — see veil-anonymity blinded_descriptor.rs) at
      // node boot and never re-applies it on reload (lifecycle.rs
      // `config.anonymity.reload_ignored`). Our deferred boot starts on a
      // THROWAWAY stub identity and promotes the real one via apply-config
      // (= reload), so onion would (a) never re-derive for the real identity and
      // (b) if forced into the stub config, publish under the stub identity.
      // Until veil supports re-deriving anonymity on the identity swap, this
      // node is NOT location-anonymous. Do not let the log imply otherwise.
      debugPrint('xVeil[deniable]: WARNING anonymous routing requested but NOT '
          'active — veil pins onion to the boot identity and the deferred path '
          'swaps identity post-boot; node runs WITHOUT onion (see veil_stack.dart)');
    }
    debugPrint('xVeil[deniable]: composed config, booting deferred @ $adminSock');

    // 4. Boot deferred, then apply the real config IN MEMORY (no file).
    final controller = EmbeddedNodeController(
      appSocketPath: ipcSock,
      starter: () {
        final node = EmbeddedNode.startDeferred(adminSock, lib: lib);
        node.applyConfig(fullConfig);
        return node;
      },
    );
    await controller.start();
    debugPrint('xVeil[deniable]: controller phase=${controller.current.phase}'
        ' msg=${controller.current.message}');
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
    final invite = BootstrapInvite.parse(await transport.createInvite());
    debugPrint('xVeil[deniable]: connected + invite ready');

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
