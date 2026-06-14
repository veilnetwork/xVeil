import 'node/embedded_node.dart';
import 'node/node_controller.dart';
import 'node/veil_node.dart';
import 'transport/bootstrap_invite.dart';
import 'transport/veil_flutter_transport.dart';
import 'transport/veil_transport.dart';

/// The composed real veil stack the app runs when native + a config are
/// available: a started node ([controller]), a connected overlay [transport],
/// this device's shareable [myInvite], and contact redemption ([addContact]).
///
/// Lifecycle ordering matters and is encapsulated here: start the node, wait
/// for connected, THEN connect the transport. Construct from the
/// identity-creation / unlock flow once a config exists (see [ensureVeilConfig]
/// for the one-time mining step).
class RealVeilStack {
  RealVeilStack._({
    required this.controller,
    required this.transport,
    required this.myInvite,
    required String veilCliPath,
    required String configPath,
  })  : _cli = veilCliPath,
        _config = configPath;

  final NodeController controller;
  final VeilTransport transport;
  final BootstrapInvite myInvite;
  final String _cli;
  final String _config;

  /// [embedded] runs the node in-process via the FFI (production path for
  /// sandboxed desktop / iOS — requires a dylib built with `node-embedded`);
  /// otherwise it spawns `veil-cli node run`.
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
  /// ours.) A running node may need a reload to pick up the new bootstrap peer.
  Future<void> addContact(BootstrapInvite peer) => veilBootstrapJoin(
        veilCliPath: _cli,
        configPath: _config,
        inviteUri: peer.toUri(),
      );

  Future<void> dispose() async {
    await transport.dispose();
    await controller.stop();
  }
}
