import 'dart:ffi';
import 'dart:io';

import 'node/embedded_node.dart';
import 'node/node_controller.dart';
import 'node/veil_node.dart';
import 'storage/storage.dart';
import 'transport/bootstrap_invite.dart';
import 'transport/veil_flutter_transport.dart';
import 'transport/veil_transport.dart';

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
  }) async {
    // 1. Load this identity's node config, or mine + store it on first run.
    var identityToml = await storage.loadNodeConfig();
    if (identityToml == null) {
      // Canonical-difficulty PoW — blocking; first run only.
      identityToml = EmbeddedNode.mineConfig(0, lib: lib);
      await storage.saveNodeConfig(identityToml);
    }

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
    );

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
    if (controller.current.phase != NodePhase.connected) {
      throw StateError(
          'deniable node did not connect: ${controller.current.phase}');
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
