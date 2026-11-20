import '../domain/call_signal.dart';

/// Delivery qualification of one already opened, authorized candidate.
/// The native operation starts a fresh bounded challenge on each invocation;
/// local admission and an answer to a previous challenge cannot return true.
Future<bool> qualifyCallMediaHandover({
  required CallTransportKind from,
  required CallTransportKind to,
  required bool Function() stillOwned,
  required Future<bool> Function(Duration budget) qualify,
}) async {
  // A recovered relay's first echo can take longer than 600 ms. Use two
  // fresh 900-ms observations within the same 1800-ms total probe budget.
  // Both still require their own matching authenticated echo before expiry.
  final budgets = from == CallTransportKind.p2p && to == CallTransportKind.relay
      ? const [Duration(milliseconds: 900), Duration(milliseconds: 900)]
      : const [Duration(milliseconds: 600)];
  for (final budget in budgets) {
    if (!stillOwned()) return false;
    final qualified = await qualify(budget);
    if (!stillOwned()) return false;
    if (qualified) return true;
  }
  return false;
}
