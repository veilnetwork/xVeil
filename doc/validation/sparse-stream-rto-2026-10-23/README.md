# Sparse-stream RTO recovery — 23 October 2026

SDK fix: **`8998746a`**. Parent/opt-in wait diagnostics: **`15c2a408`**.

## What remains broken on the device stand

The preceding cellular run on SDK `e9d3bd3d` still failed both files: 32 MiB
stopped at the 600-second diagnostic limit with 19 MiB present; 4 MiB stopped at
180 seconds with 1 MiB present. Neither completed or qualified integrity.
Seven large-file attempts timed out waiting for the first manifest byte.

Matching one failed stream between the retained logs showed the source had
received the request and queued its manifest, but its first four bytes never
entered the local carrier. Eight source snapshots end with **7743 ms local
blocked age**, **3487 local rejections**, **zero successful local recoveries**,
**262,140 app-pending bytes**, **zero consecutive DATA RTOs** and no DATA RTO
deadline. This is direct evidence of local admission wait, not a network
retransmission timeout. App-level “manifest sent” meant local stream write,
not first-hop or remote delivery. Endpoint clocks were not subtracted.

`15c2a408` adds opt-in, once-per-second-per-gate evidence for child unavailability,
transport capacity (required/available bytes) and source-budget deferral. It
changes no scheduling policy. All **666 session tests** passed, with eight
existing ignored tests; session Clippy, the then-current 124 stream / 65 client
tests and native build/199-export checks passed. Native raw logs are not part
of the anonymous user report, which retains its enum/numeric allowlist.

The new cellular run stopped at the pre-install device check: Poco was absent;
only Blackview with default Wi-Fi was present. No APK was installed, app
launched, call started, identity modified or setting changed on that replacement
phone. The exact local deferral gate therefore remains **unqualified physically**.

## Separate confirmed false route recovery

Existing route policy counted RTOs over a stream's lifetime on one route.
Even separate 8-byte writes that each recovered and were cumulatively ACKed
before the next write reached the three-event route-repair threshold. Short
long-lived credit/control flows could thus trigger repeated circuit replacement
while their application had no continuously queued tail.

Resetting that count on every ACK would disable the intended guard against a
backlogged file delivering one repaired segment per coarse RTO. The correction
instead carries the actual local demand snapshot at the timeout:

- At most one MSS outstanding, no pending app bytes, no locally unhanded segment
  and no hidden no-SACK rewind ceiling.
- The async driver also requires its app-command queue and retained outbound
  cells to be empty before passing the application-limited observation onward.
- Only an isolated RTO (`consec_rto == 1`) **with new cumulative ACK progress**
  since the previous route-local observation resets that stream's repair streak
  to one. Total RTO diagnostics still count every event.
- Backlogged, repeatedly unacknowledged, locally pending, rewound and legacy
  observations retain the conservative recovery policy.

This changes the endpoint's route-health decision. No relay role/priority,
mailbox rule, queue size, pacing budget, timer threshold or wire field changed.
It does **not** fix or conceal the preceding zero-handoff manifest blockage.

## Regression evidence

With demand plumbing present but the old carrier policy unchanged, the
real-engine/NodeServices regression fails: acknowledged tiny writes replace
their route. The corrected policy passes **eight cases** (isolated, backlogged,
blackholed and legacy observations, each with no-SACK rewind off/on). DATA is
admitted to real local outboxes; engine RTOs and cumulative ACKs are real sans-IO
transitions. Sparse writes retain their pin and avoid cooling; backlog and
blackhole cases still remap. Every generated RTO remains in diagnostics.

A separate async test drops DATA after local acceptance and exercises the real
driver → mux → sender path for 8-byte sparse and 4096-byte backlogged writes.
Another engine test keeps unhanded local segments and an outstanding larger
rewind flight conservative. These use a virtual clock; they are not handset
measurements and do not prove remote network delivery.

All **126 stream tests**, **66 anonymous-stream client tests**, all-target
Clippy with warnings denied and rustfmt pass. Existing legacy-callback tests
continue through the default forwarding method.

## Compatibility and qualification limits

The Rust `Event::DataRto` observation gains `app_limited`; consumers matching
its full field list must include the field or use `..`. The new trait callbacks
have defaults forwarding to the existing callbacks. The wire protocol is
unchanged. This is a local scheduling observation, never an application label
or priority sent to a relay.

Production macOS/Android native builds pass. Their frozen source hashes match
SDK `8998746a`, their library hashes match the retained artifacts, and the
unchanged compatible frontend sources were checked. Both retain exactly the
same **199 C export names**. No new native media test hook or PCM probe is
present. These are build/artifact checks; no installed/loaded-phone proof is
claimed for this correction.

The corrected SDK still needs handset/provider qualification. No physical speed,
file-completion, audio/video or multi-device convergence improvement is claimed.
The original 180-second completion target and first-byte/idle deadlines remain
unchanged. Raw identifiers, logs, addresses, content hashes and credentials stay
in the private cache; committed evidence contains only numeric/boolean results
and source commit references. No push, release or relay update.
