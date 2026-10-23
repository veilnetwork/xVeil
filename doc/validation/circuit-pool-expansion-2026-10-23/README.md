# Distinct-rendezvous expansion for slow streams — 23 October 2026

Production correction: Veil **`1654a9be`**. Stronger discovery-cadence assertions:
**`2a3b4999`**. Parent: **`471618ef`**.

## Confirmed defect

`maybe_shed_slow_bulk_route` chooses a different rendezvous relay before it
remaps a slow stream. When no suitable alternative existed, it requested the
ordinary full pool refresh. The next eligible DATA cell could repeat that
request after construction completed; successfully rebuilding the same
rendezvous did not widen the set the remap could choose. The post-remap warm
request also requested a full refresh.

The real-services regression seeds a confirmed route, a matching signed peer
advertisement, its live first-hop session and the actual slow-window state.
The fixture lacks a complete new two-hop path, so a construction attempt fails
with `NoRelays` and is directly counted in isolated subprocess diagnostics.
On the parent, 16 repeated shed requests with only the already represented
rendezvous caused **one unnecessary construction attempt**; the existing
completed-failure backoff suppressed further failed attempts in that burst.
After the correction the same case makes **zero** construction attempts.
This fixture does not measure how many successful constructions occur on a
public network.

## Correction

The background worker now distinguishes three local intents:

| Intent | Behavior |
| --- | --- |
| Expand | Resolve signed ads and construct routes only through rendezvous relays not already represented by the pool or pinned streams |
| Warm | Reuse only matching, confirmed, live, uncooled, sufficiently active paths; construct missing/unusable ones |
| Refresh | Construct fresh paths for explicit recovery |

Throughput shedding uses **Expand** both without an alternative and after a
successful remap. It does not republish skipped entries or erase their health
and stream statistics. Including pinned streams matters because their circuit
can legitimately outlive its pool entry. Newly advertised unrepresented relays
remain eligible; expansion respects rendezvous cooldowns without the ordinary
repair fallback that retries when every candidate is cooled.

Discovery-only admission runs at most once per **one second per peer and local
producer**. Expired deadlines are pruned. This prevents a fast no-op DHT/cache
probe on every DATA cell. Warm-up and explicit repair bypass that cadence. A
ready matching alternative is selected before discovery admission, so it can
be used immediately. No sleeping automatic discovery loop was added.

Concurrent demand can strengthen **Expand → Warm → Refresh** under the shared
running-task guard. If a completed pass skipped/reused routes, the worker
honors a stronger joined request before removing its slot. A pass that already
built everything afresh does not repeat unnecessarily; completed cold errors
retain their existing failure backoff. Each independent producer gets its own
cadence state. Relay scheduling, wire framing, anonymity hops and limits are
unchanged. Pool-completion diagnostics now include the constant local intent.

## Verification

All **62 anonymous-stream tests** pass. The new regression exercises **10 child
cases**: same relay, another probe after the cadence expires, pinned-only path,
ready alternative, unrepresented advertised relay, cooled new relay, explicit
repair, ordinary warm-up and their coalescence with discovery.

The strengthened test counts actual advertisement-ranking passes as well as
construction attempts: a 16-request no-op burst produces **one discovery pass**;
a later request produces **a second**. Ready-alternative selection preserves
receiver binding and active-stream accounting. Explicit repair/warm-up is
admitted immediately after the discovery burst and when joined with it.

The unrepresented-ad control proves that construction is **attempted**, not
that a new two-hop circuit completes in this offline fixture. A separate
already-ready-route control proves local remap behavior. Physical delivery
still needs its own check.

All-target FFI Clippy with warnings denied, rustfmt and production macOS/Android
builds pass. Both libraries retain the same **199 C export names**. The later
commit changes only test assertions; frozen production-library/source hashes
match the final production code. [summary.json](summary.json) contains numeric
observations and explicit qualification limits. Raw identities and logs remain
outside the repository.

## Physical qualification still pending

The phone was present but **ADB unauthorized**, so no stand app was launched,
phone APK installed, relay changed or physical transfer started in this cycle.
The last physical result remains the preceding SDK's 32 MiB / 4 MiB completion,
not a qualification of this correction. Reduction of the observed reconstruction
count or cellular delivery time is **unproven**. The manifest-first-byte timeout,
other route-repair causes, call/video/live-speech checks and the complete
multi-device matrix remain open. No release or push was performed.
