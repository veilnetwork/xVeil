/// Lifecycle phase of the underlying veil node.
enum NodePhase { stopped, starting, connected, offline, error }

/// A snapshot of node health surfaced to the UI.
class NodeStatus {
  const NodeStatus({
    required this.phase,
    this.peerCount = 0,
    this.message,
  });

  final NodePhase phase;
  final int peerCount;
  final String? message;

  static const stopped = NodeStatus(phase: NodePhase.stopped);
}

/// Port that owns the *running node* lifecycle — distinct from [VeilTransport],
/// which is the messaging surface of an already-running node.
///
/// Decision (2026-06-14): start with the subprocess strategy — bundle and
/// spawn `veil-cli node run`, then connect the FFI client to its IPC socket.
/// The interface deliberately hides that so an embedded-FFI implementation can
/// replace it later without touching callers.
abstract interface class NodeController {
  /// Ensure a node is running and reachable. Idempotent.
  Future<void> start();

  /// Move the node into a battery-friendly low-activity mode (app backgrounded).
  Future<void> setEconomyMode(bool economy);

  /// Stop the node (e.g. on logout). Implementations may keep it alive in the
  /// background instead, depending on platform policy.
  Future<void> stop();

  Stream<NodeStatus> status();

  NodeStatus get current;
}

/// A controller that just reports one fixed [NodeStatus] and does nothing else.
/// Used to surface the HONEST real-node boot state in the UI (`starting` /
/// `error` with a message) when the real stack is expected but not up yet —
/// instead of silently swapping in the in-memory demo node, which would show a
/// fabricated "connected / N peers" the user must never be misled by.
class StaticNodeController implements NodeController {
  StaticNodeController(this._current);
  final NodeStatus _current;
  @override
  NodeStatus get current => _current;
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
  @override
  Future<void> stop() async {}
}
