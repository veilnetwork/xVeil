import 'dart:typed_data';

import '../../core/ids.dart';
import 'relay_key_cache.dart';

/// One place a deposit can go: the relay that holds the receiver's mailbox and
/// that relay's public X25519 — the PUT's seal target. Both are needed; a relay
/// without a key cannot be sealed to, so it is not a target at all.
typedef MailboxDepositTarget = ({Uint8List relayNodeId, Uint8List kemPk});

/// One entry of a resolved rendezvous ad, reduced to what a deposit needs.
/// [kemPk] is null when the ad NAMES the relay but carries no KEM field (a v5
/// ad published before the app layer re-attached the relay key).
typedef MailboxAdReplica = ({NodeId relay, Uint8List? kemPk});

/// Where a deposit's targets came from. The distinction is not cosmetic: only
/// [freshAd] may be written back to the cache (see [recordMailboxDeposit]).
enum MailboxTargetSource { freshAd, cache, none }

/// The relays a deposit will be fanned out to, and the provenance of that list.
class MailboxDepositPlan {
  const MailboxDepositPlan(this.targets, this.source);

  final List<MailboxDepositTarget> targets;
  final MailboxTargetSource source;

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
/// [resolveRelayKem] fills a relay's KEM key when neither the ad nor the cache
/// carries one (a one-hop relay-directory lookup at the call site).
Future<MailboxDepositPlan> planMailboxDeposit({
  required NodeId receiver,
  required List<MailboxAdReplica> adReplicas,
  required Future<Uint8List?> Function(NodeId relay) resolveRelayKem,
  required int fanout,
  RelayKeyCache? cache,
}) async {
  final fromAd = await _targetsFor(
    adReplicas,
    resolveRelayKem: resolveRelayKem,
    fanout: fanout,
    cache: cache,
  );
  if (fromAd.isNotEmpty) {
    return MailboxDepositPlan(fromAd, MailboxTargetSource.freshAd);
  }
  if (cache == null) {
    return const MailboxDepositPlan([], MailboxTargetSource.none);
  }
  final remembered = await cache.getPeerRelays(receiver);
  if (remembered.isEmpty) {
    return const MailboxDepositPlan([], MailboxTargetSource.none);
  }
  final fromCache = await _targetsFor(
    [for (final relay in remembered) (relay: relay, kemPk: null)],
    resolveRelayKem: resolveRelayKem,
    fanout: fanout,
    cache: cache,
  );
  return fromCache.isEmpty
      ? const MailboxDepositPlan([], MailboxTargetSource.none)
      : MailboxDepositPlan(fromCache, MailboxTargetSource.cache);
}

/// Key sources in order of freshness: the ad's own KEM field, then the
/// persisted relay-key cache, then a live relay-directory lookup. A relay with
/// no key from any of the three is not a target — the PUT has nothing to seal
/// to — but it does not disqualify its siblings.
Future<List<MailboxDepositTarget>> _targetsFor(
  List<MailboxAdReplica> replicas, {
  required Future<Uint8List?> Function(NodeId relay) resolveRelayKem,
  required int fanout,
  required RelayKeyCache? cache,
}) async {
  final out = <MailboxDepositTarget>[];
  final seen = <String>{};
  for (final r in replicas) {
    if (out.length >= fanout) break;
    if (!seen.add(r.relay.hex)) continue;
    var kem = r.kemPk;
    if (kem == null || kem.length != 32) kem = await cache?.get(r.relay);
    if (kem == null || kem.length != 32) kem = await resolveRelayKem(r.relay);
    if (kem != null && kem.length == 32) {
      out.add((relayNodeId: r.relay.bytes, kemPk: Uint8List.fromList(kem)));
    }
  }
  return out;
}

/// Remember what worked, so the NEXT deposit to a peer whose ad has lapsed has
/// somewhere to go.
///
/// Only a [MailboxTargetSource.freshAd] plan writes the peer→relay record. A
/// deposit made THROUGH the cache must not renew it: our own retries would
/// otherwise keep a relay the peer abandoned alive forever, and the record's
/// TTL is the only thing that ever retires one. Relay KEM keys are written
/// either way — a relay's public key is a fact about the relay, not about the
/// peer's choice of it.
///
/// Best-effort by construction: the deposit has already happened, so a storage
/// failure here must not turn a delivered message into a failed one.
Future<void> recordMailboxDeposit({
  required NodeId receiver,
  required List<MailboxDepositTarget> accepted,
  required MailboxTargetSource source,
  RelayKeyCache? cache,
}) async {
  if (cache == null || accepted.isEmpty) return;
  try {
    for (final t in accepted) {
      await cache.put(NodeId(t.relayNodeId), t.kemPk);
    }
    if (source == MailboxTargetSource.freshAd) {
      await cache.setPeerRelays(
        receiver,
        [for (final t in accepted) NodeId(t.relayNodeId)],
      );
    }
  } catch (_) {
    // best-effort — a lost record only costs the next lapsed-ad deposit
  }
}
