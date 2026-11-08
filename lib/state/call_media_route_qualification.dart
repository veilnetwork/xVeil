import '../domain/call_signal.dart';

/// Delivery qualification of one already opened, authorized candidate.
/// The native operation starts a fresh bounded challenge on each invocation;
/// local admission and an answer to a previous challenge cannot return true.
Future<bool> qualifyCallMediaHandover({
  required CallTransportKind from,
  required CallTransportKind to,
  required bool Function() stillOwned,
  required Future<bool> Function() qualify,
}) async {
  // A recovered relay can admit the initial control while its independent
  // return path is still warming. Discarding the whole candidate after that
  // observation leaves a dead direct sender until the service's retry/repair.
  // Keep this candidate for at most three NEW short observations instead.
  // Each native begin replaces the expired nonce and retains its own deadline;
  // a late echo from an earlier observation never qualifies the next one.
  // P2P upgrades retain their single observation of an already usable route.
  final attempts =
      from == CallTransportKind.p2p && to == CallTransportKind.relay ? 3 : 1;
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (!stillOwned()) return false;
    final qualified = await qualify();
    if (!stillOwned()) return false;
    if (qualified) return true;
  }
  return false;
}
