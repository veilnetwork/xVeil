import 'dart:async';

import '../data/transport/veil_transport.dart';

/// Keep the peer list current while the node is running. Session-count events
/// prompt an immediate read; polling also catches changes that leave the
/// count unchanged. A stalled native read must not stop all later reads.
Stream<List<PeerInfo>> peerInventory({
  required Future<List<PeerInfo>> Function() fetch,
  required Stream<int> sessionCounts,
  Duration pollInterval = const Duration(seconds: 4),
  Duration fetchTimeout = const Duration(seconds: 3),
  DateTime Function()? clock,
}) {
  final now = clock ?? DateTime.now;
  final tracked = <String, PeerInfo>{};
  late final StreamController<List<PeerInfo>> output;
  StreamSubscription<int>? changes;
  Timer? poll;
  var closed = false;
  var inFlight = false;
  var pending = false;

  List<PeerInfo> merge(List<PeerInfo> snapshot) {
    final stamp = now();
    final seen = <String>{};
    for (final peer in snapshot) {
      final key = peer.nodeId.hex;
      seen.add(key);
      tracked[key] = peer.copyWith(
        lastSeen: peer.isActive ? stamp : tracked[key]?.lastSeen,
      );
    }
    for (final key in tracked.keys.toList()) {
      if (!seen.contains(key) && tracked[key]!.state != PeerState.closed) {
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

  Future<void> refresh() async {
    if (closed) return;
    if (inFlight) {
      pending = true;
      return;
    }
    inFlight = true;
    try {
      do {
        pending = false;
        try {
          final snapshot = await fetch().timeout(fetchTimeout);
          if (!closed) output.add(merge(snapshot));
        } catch (_) {
          // Keep the last good list on a transient FFI error or lock stall.
          // The next count event or poll will retry.
        }
      } while (pending && !closed);
    } finally {
      inFlight = false;
    }
  }

  output = StreamController<List<PeerInfo>>(
    onListen: () {
      changes = sessionCounts.listen(
        (_) => unawaited(refresh()),
        onError: (Object _) {},
      );
      poll = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
      unawaited(refresh());
    },
    onCancel: () async {
      closed = true;
      poll?.cancel();
      await changes?.cancel();
    },
  );
  return output.stream;
}
