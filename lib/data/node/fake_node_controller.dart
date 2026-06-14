import 'dart:async';

import 'node_controller.dart';

/// In-memory [NodeController] that simulates a node coming online. Used until
/// the subprocess (`veil-cli node run`) adapter is wired.
class FakeNodeController implements NodeController {
  final _status = StreamController<NodeStatus>.broadcast();
  NodeStatus _current = NodeStatus.stopped;
  Timer? _peerTimer;

  @override
  NodeStatus get current => _current;

  void _emit(NodeStatus s) {
    _current = s;
    if (!_status.isClosed) _status.add(s);
  }

  @override
  Future<void> start() async {
    if (_current.phase == NodePhase.connected ||
        _current.phase == NodePhase.starting) {
      return;
    }
    _emit(const NodeStatus(phase: NodePhase.starting));
    await Future<void>.delayed(const Duration(milliseconds: 900));
    _emit(const NodeStatus(phase: NodePhase.connected, peerCount: 3));
    // Drift the peer count a little so the UI feels live.
    _peerTimer?.cancel();
    _peerTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_current.phase != NodePhase.connected) return;
      final n = 2 + (DateTime.now().second % 5);
      _emit(NodeStatus(phase: NodePhase.connected, peerCount: n));
    });
  }

  @override
  Future<void> setEconomyMode(bool economy) async {
    // No-op for the fake; real adapter calls VeilClient.setBackgroundMode.
  }

  @override
  Future<void> stop() async {
    _peerTimer?.cancel();
    _emit(NodeStatus.stopped);
  }

  @override
  Stream<NodeStatus> status() => _status.stream;
}
