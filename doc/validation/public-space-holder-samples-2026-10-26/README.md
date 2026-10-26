# Public Space holder diversity and native discovery

## Confirmed defects and corrections

| Finding | Change | Verification |
| --- | --- | --- |
| Independent replica salts could still leave every replica with the same single holder. | Retain up to five distinct holder keys per route, using deterministic replica-salted ranking. One holder offering many Spaces consumes at most one slot. | Three-node native authority-transfer/search/subscription test passes; unit tests cover both publication orders and a holder offering 50 Spaces. |
| Separate comparison and writes could erase a concurrent holder or newer refresh. | Native publication, direct STORE, recursive STORE, mirror and periodic replication use the same bounded merge and exact-byte CAS. | Concurrent writers, stale refresh and delayed republish snapshot tests. |
| The app stopped after five payloads, hiding a later current quorum. | Verify and merge up to the bounded 30 candidates returned by five slots from five remote replicas plus the local cache. | Regression fails with the old cap (`partialQuorum`) and passes with the new cap. |
| The nominal 16 KiB payload did not reserve the signed carrier overhead. | Cap the complete carrier at 16,384 bytes and its application payload at 16,168 bytes in both Dart and Rust. | Five maximum-sized samples each remain within the existing wire limit. |
| Native telemetry privacy test did not enable its opt-in endpoint. | The stand recipe explicitly enables loopback debug metrics and checks the flag before starting. | Complete telemetry and encrypted-store canary checks pass. Production defaults remain opt-in. |

## Storage, wire and compatibility

The local `XB` bucket contains at most five original signed `XS` carriers.
It is never sent as a STORE or as a response. Each indexed `XSQ` FIND_VALUE
request gets one original carrier, so packet payloads retain the 16 KiB limit.
The selector is bounded to slots 0–4. Slots are queried concurrently within
the existing lookup timeout; each has its own pending query id.

A legacy request receives the first carrier, matching the old replica rank.
A legacy peer ignores a selector and repeats its singleton; the resolver
deduplicates bytes and the application counts distinct holder signatures.
Signature, route-key, expiry, per-peer, identity-write, per-origin and global
storage checks still apply. The local aggregate has an 81,944-byte hard cap;
the existing global DHT byte budget remains unchanged. Per-origin accounting
conservatively charges the complete aggregate to the admitting origin and
refuses the change when that origin cannot afford it. Constrained operator
budgets may therefore keep fewer records.

Periodic replication splits a bucket into its live signed carriers and counts
recipient peers once, rather than counting sample frames as extra replicas.
Expired entries do not prevent live holders from being republished. A cached
snapshot cannot overwrite newer local state.

The bounded index does not promise to retain every Space under a popular
search token. It preserves independent holder diversity within its fixed
sampling and storage budgets. No holder is pinned because it is the local
publisher or a preferred node.

## Validation

The final isolated native stand passed in 24 seconds, with three authenticated
nodes, no public seed or meeting-point fallback, generation 1, two independent
holders, a verified public subscription, exact mention navigation, telemetry
canary checks and encrypted-store scanning. All owned processes exited and
the successful fixture removed its directories.

An earlier complete run passed in 18 seconds before the additional per-holder
slot safeguard. A later attempt stopped during redundant dependency download;
it never started the native test and is excluded from passing evidence. The
final run uses `--no-pub` with already resolved dependencies. The verifier also
requires the actual test-completion marker instead of trusting exit code alone.

Rust crypto, storage, dispatcher and runtime checks, the Dart FFI buffer checks,
application regressions and Clippy with warnings denied passed. See
`results.json` for the exact counts and candidate source commit.

This cycle validates public discovery. Media quality, physical-device coverage
and the wider defect-removal goal still have outstanding work. These commits
are local candidates; no release or server deployment was performed this cycle.
