# Nicknames over veil — design (v1)

Status: design agreed 2026-07-09 (ROADMAP «Никнеймы»); this doc pins the
record format and flows before the native slice lands.

## Goals

* Claim a human-readable name (`@alice`) resolvable to a veil identity.
* Mined by the SOVEREIGN key, so the name survives device changes
  (multi-device: instances live under the sovereign, see
  InstanceRegistry).
* Ownership is contestable by WEIGHT (user decision): a bigger
  cumulative proof-of-work displaces the current holder. Short names
  cost more (per-length difficulty floor).
* Forward-compatible with staking: the record versions its weight
  source (`pow` now, `stake` later) — a future cryptocurrency stake
  becomes just a heavier weight class.
* Anonymous identities never claim or publish names (a public name is
  a linkability signal) — enforced app-side and ignored relay-side.

## DHT record

Key: `NM || blake3(normalize(name))` (new record kind next to RD/ads).

```text
NicknameRecord v1 {
  version:        u8 = 1,
  name:           utf-8, ≤ 32 chars, normalized (see below),
  owner_node_id:  [u8; 32],          // sovereign node id
  owner_sign_pk:  [u8; 32],          // ed25519, must hash to owner_node_id
  weight_kind:    u8,                // 0 = pow-v1 (blake3 leading zero bits)
  weight:         u64,               // CUMULATIVE claimed weight (see PoW)
  pow_seeds:      Vec<[u8; 32]>,     // nonce seeds proving `weight`, ≤ 64
  issued_at_unix: u64,               // freshness for same-owner refresh
  sig:            ed25519(owner_sign_pk, canonical_bytes_without_sig),
}
```

Normalization: lowercase, NFC, [a-z0-9_] only, 3..=32 chars. The
per-length difficulty floor makes 3-4 char names hours-of-work class,
long names seconds (exact curve tuned in implementation; floor checked
by every verifier).

## Cumulative PoW (weight_kind = 0)

One unit of work: `h = blake3(name_norm || owner_node_id || seed)`;
`bits(h)` = leading zero bits. A seed CONTRIBUTES `2^bits(h)` weight.
`weight` = Σ over `pow_seeds` (capped list: keep the 64 heaviest
seeds; the cap bounds record size while keeping displacement honest —
64 × 2^bits dominates any realistic contest).

* The owner can keep mining and re-publish with a bigger `weight` at
  any time (topping up their moat).
* Verifiers recompute every seed; a record whose recomputed sum <
  `weight`, or whose per-length floor is unmet, is invalid.

## Conflict rule (relay + client side)

A record REPLACES the stored one for the same name iff:
1. valid signature + PoW sum + length floor, AND
2. `weight` strictly greater than stored (any owner), OR same owner
   and `issued_at_unix` newer (refresh without re-mining).

Ties keep the incumbent. This is the user-chosen "bigger PoW wins"
market with the cumulative defense.

## Client flows (v1 scope, all agreed)

* Settings → Identities & account → "Nickname": availability check
  (resolve), mining with progress (background, cancellable, resumable
  seeds cache), publish, auto re-publish/top-up while the node runs.
* Add contact by `@name`: resolve → IdentityDocument → normal invite
  flow.
* Display: verified `@name` next to the LOCAL alias (alias always
  wins in UI); contacts pin the peer's node id — a name changing
  owners NEVER re-points an existing contact, and the UI must call out
  "this name changed owners" when a stored name→id binding stops
  matching.

## Non-goals (v1)

* Name transfer/market UX (displacement IS the market).
* Multiple names per identity (one primary name first).
* Relay-side quotas beyond record validity (a heavier record is the
  only way in).
