import 'dart:typed_data';

import '../../core/ids.dart';
import 'relay_key_cache.dart';

/// One place a deposit can go: the relay that holds the receiver's mailbox and
/// that relay's public X25519 — the PUT's seal target. Both are needed; a relay
/// without a key cannot be sealed to, so it is not a target at all.
typedef MailboxDepositTarget = ({Uint8List relayNodeId, Uint8List kemPk});

/// One entry of a resolved rendezvous ad, reduced to what a deposit needs.
/// [kemPk] is null for an ad with no explicit mailbox key.
typedef MailboxAdReplica = ({NodeId relay, Uint8List? kemPk});

typedef ResolvedMailboxRelayKey = ({Uint8List key, int validUntilUnix});

/// Only [freshAd] provides new evidence of which relay serves the recipient.
enum MailboxTargetSource { freshAd, cache, none }

/// The relays a deposit will be fanned out to, and the provenance of that list.
class MailboxDepositPlan {
  const MailboxDepositPlan._(
    this.targets,
    this.source, [
    this._resolvedKeyExpiries = const {},
  ]);

  final List<MailboxDepositTarget> targets;
  final MailboxTargetSource source;
  final Map<NodeId, int> _resolvedKeyExpiries;

  bool get isEmpty => targets.isEmpty;
}

/// Pick the relays to deposit at: the peer's FRESH rendezvous ad first, the
/// last-known-good cache second.
///
/// WHAT THIS BUYS. A sender learns which relay holds a peer's mailbox only from
/// that peer's rendezvous ad, and only a live node republishes one — so once a
/// device has been off longer than its ad lives, the resolve returns nothing
/// and, before this fallback existed, no deposit was even attempted: the
/// unresolved-peer backoff took over and the mail sat in the SENDER's outbox
/// until the recipient came back. Measured live 2026-08-18 against a
/// force-stopped Android sibling: 25 minutes, zero `stash OK`, 16
/// `deposit SUPPRESSED — unresolved-peer backoff`, 3 `stash FAILED`. Falling
/// back to the relays that last held the peer's mailbox restores the deposit,
/// which is the whole point of a mailbox: the relay does not need the ad to
/// ACCEPT one. The ad tells the SENDER where to go; it is not a credential.
///
/// WHAT IT DOES NOT BUY. It cannot help a peer that has NEVER been resolved —
/// there is nothing to remember about a stranger — so the backoff below is kept
/// for exactly that case. It also cannot notice that a recipient moved to
/// another relay while it was away: a deposit at the old relay is then thrown
/// away by that relay's TTL and the recipient fetches nothing. That is bounded
/// by the entry's own TTL and corrected the instant one fresh ad resolves,
/// which overwrites the record wholesale — and it is strictly better than the
/// measured alternative, which delivered nothing to anyone.
///
/// For remembered relays, query their current signed keys before falling back
/// to the stored ones. The directory alone cannot establish a mailbox target;
/// it only refreshes the key of a target established by the recipient's ad.
Future<MailboxDepositPlan> planMailboxDeposit({
  required NodeId receiver,
  required List<MailboxAdReplica> adReplicas,
  required Future<ResolvedMailboxRelayKey?> Function(NodeId relay)
  resolveRelayKem,
  required int fanout,
  RelayKeyCache? cache,
}) async {
  const empty = MailboxDepositPlan._([], MailboxTargetSource.none);
  if (fanout <= 0) return empty;

  final targets = <MailboxDepositTarget>[];
  final seen = <NodeId>{};
  for (final replica in adReplicas) {
    if (targets.length >= fanout) break;
    final kem = replica.kemPk;
    if (kem == null || kem.length != 32 || !seen.add(replica.relay)) continue;
    targets.add((
      relayNodeId: replica.relay.bytes,
      kemPk: Uint8List.fromList(kem),
    ));
  }
  if (targets.isNotEmpty) {
    return MailboxDepositPlan._(targets, MailboxTargetSource.freshAd);
  }
  if (cache == null) return empty;

  // A silent relay must not make the others pay another serial directory
  // timeout. Bound the batch to the same size as the persisted peer record.
  final remembered = await cache.getPeerRelays(receiver);
  final candidates = await Future.wait(
    remembered.toSet().take(kPeerRelayCacheMaxRelays).map((relay) async {
      final resolved = await resolveRelayKem(relay);
      final nowUnix = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (resolved != null &&
          resolved.key.length == 32 &&
          (resolved.validUntilUnix == 0 || resolved.validUntilUnix > nowUnix)) {
        return (
          relay: relay,
          kem: resolved.key,
          expiry: resolved.validUntilUnix,
        );
      }
      return (relay: relay, kem: await cache.get(relay), expiry: null);
    }),
  );
  final resolvedKeyExpiries = <NodeId, int>{};
  for (final candidate in candidates) {
    if (targets.length >= fanout) break;
    final kem = candidate.kem;
    if (kem == null || kem.length != 32) continue;
    targets.add((
      relayNodeId: candidate.relay.bytes,
      kemPk: Uint8List.fromList(kem),
    ));
    final expiry = candidate.expiry;
    if (expiry != null) resolvedKeyExpiries[candidate.relay] = expiry;
  }
  return targets.isEmpty
      ? empty
      : MailboxDepositPlan._(
          targets,
          MailboxTargetSource.cache,
          resolvedKeyExpiries,
        );
}

/// Keep verified key evidence from an advertisement or the relay directory.
/// A transport handoff using a cached key says nothing about its validity.
/// Only an advertisement can extend the lifetime of a peer's relay list.
Future<void> recordMailboxDeposit({
  required NodeId receiver,
  required List<MailboxDepositTarget> accepted,
  required MailboxDepositPlan plan,
  RelayKeyCache? cache,
}) async {
  if (cache == null || accepted.isEmpty) return;
  final fromAd = plan.source == MailboxTargetSource.freshAd;
  try {
    for (final target in accepted) {
      final relay = NodeId(target.relayNodeId);
      final expiry = plan._resolvedKeyExpiries[relay];
      if (fromAd || expiry != null) {
        await cache.put(relay, target.kemPk, validUntilUnix: expiry ?? 0);
      }
    }
    if (fromAd) {
      await cache.setPeerRelays(receiver, [
        for (final target in accepted) NodeId(target.relayNodeId),
      ]);
    }
  } catch (_) {
    // best-effort — a lost record only costs the next lapsed-ad deposit
  }
}
