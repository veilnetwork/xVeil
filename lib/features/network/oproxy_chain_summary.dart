import '../../data/node/proxy_routing.dart';
import '../../l10n/app_localizations.dart';

/// The one-line account of an exit chain: which exit is used first, and how
/// many stand behind it.
///
/// This exists as a function because the two screens that show it — the VPN's
/// own chain and the per-application overrides — each built the sentence
/// inline, and BOTH passed the arguments in the wrong order. The generated
/// signature is `oproxyRouteSummary(fallbacks, primary)` — the placeholders
/// sorted ALPHABETICALLY — while the message reads `{primary} + запасных:
/// {fallbacks}`. Positional arguments of the same static type do not complain
/// when swapped, so a live phone rendered "0 + запасных: exit-host" and the
/// row that was supposed to say which exit the VPN uses said nothing usable.
///
/// [chain] must not be empty: the callers differ on what an empty chain MEANS
/// (the application row says "as the default chain", the VPN row says "no
/// default configured"), so that branch stays with them.
///
/// When [autoFailover] is false the fallbacks are configured but will never be
/// tried — `VpnProxyPlan._normalizeChain` cuts the chain to its first entry —
/// so promising "+ 1 запасной" there would be a lie. Say they are off instead.
String oproxyChainSummary(
  AppL10n l,
  ProxyRouting routing,
  List<String> chain, {
  bool autoFailover = true,
}) {
  assert(chain.isNotEmpty, 'empty chains are the caller’s branch to explain');
  final primary = routing.effectiveOproxies
      .where((endpoint) => endpoint.nodeId == chain.first)
      .firstOrNull;
  final label = primary?.label ?? chain.first.substring(0, 8);
  if (!autoFailover && chain.length > 1) {
    return l.oproxyRouteSummaryNoFailover(label);
  }
  return l.oproxyRouteSummary(chain.length - 1, label);
}
