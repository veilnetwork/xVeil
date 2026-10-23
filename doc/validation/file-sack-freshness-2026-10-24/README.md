# Newest received range in saturated SACK feedback — 24 October 2026

SDK `e81ae21b`, based on `27757b35`. Dart frontends remain from xVeil
`c9e2d58f`; hidden-volume is unchanged.

## Confirmed defect

ACK encoding repeated the first eight buffered ranges in sequence order. Once
persistent early gaps filled those slots, newer received data could remain
invisible to the sender. Its selective scoreboard, first-delivery byte count and
RACK frontier then lacked current information, even though data had arrived.

Two regressions fail against the parent production code. The first receives
sixteen disjoint ranges and loses the newest report once the eight-slot list
fills. A second sends real encoded DATA and ACK frames between two engines:
the receiver holds 256 out-of-order bytes, while the parent's sender knows only
128. With the correction it accounts for all 256, advances the RACK frontier,
repairs the missing data and reassembles the full 512-byte nonperiodic payload
exactly. Both are exercised across sequence-number wrap.

## Correction

Track the most recent actually buffered DATA and put its coalesced range before
older ordinary ranges. D-SACK retains its first slot and its enclosing second
slot for an above-ACK duplicate. A fresh arrival does not erase a pending D-SACK.
Already drained or rejected out-of-window DATA cannot become a new advertised
range. The eight-slot bound and existing frame format remain unchanged.

The newest-receipt principle is described for TCP SACK in
[RFC 2018 §4](https://www.rfc-editor.org/rfc/rfc2018.html#section-4).
Veil retains its own protocol and D-SACK layout; this is not a claim of complete
TCP compliance.

The optional local numeric summary counts cases where the previous oldest-first
selection would have omitted the newest block (`sack_recent_promotions`).
No traffic-class hint, relay priority, mailbox fallback or test traffic generator
is added to production. The retransmission-timeout and route-selection policies
are unchanged by this correction.

The 140 stream tests and 30 anonymous-stream client tests pass, together with
formatting and all-target stream Clippy with warnings denied. The new coverage
includes bounded wire encoding, merged blocks, rejected out-of-window DATA,
D-SACK under full capacity, first-delivery accounting and byte-exact repair.

## Rejected hypotheses / comparison limits

A temporary test with a continuously ready duplicate-ACK inbox did not reproduce
timer starvation on the parent driver. Timer selection was left unchanged and
the temporary test was removed.

A separate Mac-only experimental binary suppressed low-throughput-only route
shedding, retaining network-failure recovery. The 32 MiB reverse transfer still
failed its 180-s gate, at **17.25 MiB** (the preceding ordinary run reached
23.25 MiB). No slow-route shed occurred in that experimental log. These runs do
not isolate a throughput ratio because their paths vary, but the experiment did
not justify removing the existing shedding policy. The experimental source was
restored exactly before further work, and that binary is not release qualified.

## Physical correction check

The cellular Poco, with Wi-Fi off, and Mac used owned QA profiles and denied
contact P2P overrides. The SDK source hashes, installed QA APK, loaded Mac
library and unchanged 199 exported Veil functions were checked. No calls,
audio devices or media test hooks were started.

**Mac → phone: 32 MiB completed in 133.372 seconds, SHA-256 matched.**
This passes the original 180-second gate. Each endpoint observed one native
stream; there were no retained payload-idle failures, access denials or
EOF-before-manifest failures. The phone retained one file-offer row.
The receiver's promotion counter reached **1,093 ACK events**, so saturated
feedback handling was exercised physically. This counts ACK events, not unique
segments or avoided retransmissions. The run still made six throughput-driven
route switches and one no-progress remap; those policies were not disabled.

The preceding ordinary SDK run failed the 180-s gate at 23.25 MiB; its
[result remains recorded](../file-rto-first-receipt-2026-10-24/README.md).
The new completed run is a success, not an isolated causal speedup ratio:
network paths vary. It does not prove every intermittent stall eliminated or
qualify consistently completing all future runs in 180 seconds.

## Cleanup, privacy and remaining work

After both the experiment and corrected run, independent checks confirmed
all owned apps/captures exited, original phone APK hashes were restored,
profile selection and diagnostic properties were preserved, ADB forwards were
removed and contact P2P settings were restored. The installed Mac app was
untouched. Native builds used the watched external volume; Mac launches used
`/private/tmp/`. No phone network setting was changed.

[Evidence](summary.json) contains whitelisted counts, relative timings,
booleans and source hashes. Raw logs, identities, content identifiers, addresses,
credentials, payloads, APKs and private paths remain outside the repository.
The original untracked October 17 matrix is preserved.

Windows, live speech, audio/video, long offline periods and the full multi-device
matrix remain unqualified by this cycle. The overall defect goal stays active.
The next user-requested work is validation of report 29 and the identity wizard's
certificate save dialog.
