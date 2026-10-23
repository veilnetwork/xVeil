# Cellular call and file validation — 2026-10-22

**Status: partial stream fixes verified; long anonymous transfers and call/video failures remain.**

## Latest follow-up — 23 October: graceful close and final local ACK handoff

[stream-close-handoff.json](stream-close-handoff.json) records SDK `097e373b`.
**The 32-MiB anonymous upload is still incomplete at the 180-second observation
deadline. General file reliability and physical audio/video quality are open.**

### Two reproduced local defects

The FFI's ordinary stream close releases both application halves gracefully.
However, the driver reset the stream when late reverse-direction bytes arrived
without a reader. A controlled peer's final eight-byte credit reproduced this:
queued payload was delivered, followed by an unwanted APP reset. The driver now
drains/discards late received bytes only when both application halves are gone,
while completing queued writes and transport acknowledgements. Dropping only
the reader while keeping a writer retains its previous abort behavior.

The driver also retired after both byte directions completed even when its last
ACK remained locally rejected by the carrier. The peer then had no confirmation
of its final credit/FIN. Retirement now waits for that local ACK handoff. A
permanently unavailable carrier is bounded by the existing retry-policy ceiling
(maximum RTO times retry count plus one), rather than leaking a detached task.
Local waiting does not generate a network-RTO event; explicit reset remains
responsive. This does not guarantee delivery after a carrier accepts an ACK and
it is subsequently lost in the network.

Both regression cases fail on the previous source. The reader-only-drop
control passes before and after the correction. The new five-test suite also
checks exact queued payload, received credit, clean EOF, cancellation and the
permanent-backpressure bound. These are controlled async driver exchanges,
not a claim that a particular WAN stall has been eliminated.

### Gates and physical qualification

All **75 stream tests** and **44 FFI anonymous-stream tests** pass, with
all-target Clippy and rustfmt clean. Production Mac and Android SDK builds pass;
the same **198 SDK export names** are retained. Current sources, frozen SDKs,
installed APK and the Mac process's loaded library were verified before and
after physical testing. Ordinary frontends/media engines were unchanged; no
synthetic media, PCM probes or calls were enabled. No wire format, relay media
classification, transit priority, mailbox policy or network-RTO constant changed.

The phone used cellular data with Wi-Fi off. QA-contact P2P was denied for these
transfers and restored afterward. All recorded opens were anonymous; counts in
the JSON include manifest probes and retry opens.

| Direction | Size | Download | Pull requests | Result |
| --- | ---: | ---: | ---: | --- |
| Phone → laptop | 4 MiB | 34.209 s | 2 | Exact SHA-256 match after resume |
| Laptop → phone | 4 MiB | 73.160 s | 3 | Exact SHA-256 match after resume |
| Phone → laptop | 32 MiB | **Incomplete at 180 s** | 3 | Final hash unverified; harness cancels the remaining attempt |

The large transfer recorded committed resume offsets of **29,884,416** and
**30,932,992 bytes**, not a verified complete file. One pull attempt failed
before obtaining its manifest; failure-log counts also include final harness
cancellation. The small reverse transfer likewise had one no-manifest failure.
No general speed improvement is established; these runs were slower than the
preceding small-file run and do not isolate network variation or rule out a
performance regression. The largest sampled local carrier waits were **335 ms
on the laptop** (207 driver samples) and **14,750 ms on the phone** (264 samples).
These are sampled local waits, not end-to-end latency or absolute maxima.

During this sequence the phone's serving log recorded **two `invalid content
stream credit` failures**. The exact cause of those rejected application credits
is not yet established. Their validation was not weakened, and correcting local
stream close is not claimed to have resolved them. This is a concrete next
investigation alongside the remaining local queue stalls and network ACK loss.

Both owned app processes and captures exited. Policies, the temporary Android
diagnostic property and exact original phone APK were restored and checked;
owned phone file fixtures were removed. The installed Mac app was unchanged.
Only aggregate evidence is published here; raw captures, identifiers, keys,
addresses, packet sequences and file hashes remain outside the repository.

## Previous follow-up — 23 October: ACK fallback after local queue rejection

[ack-copy-fallback.json](ack-copy-fallback.json) records SDK `99d0fa17`.
**Large-file stalls and physical audio/video failures remain unresolved.**

ACK redundancy selected its limited candidate set before trying local enqueue.
When the primary and first alternate shared a full first-hop outbox, a healthy
third path was never tried. A controlled regression using real runtime circuits,
signed directory entries and genuinely saturated ordinary outboxes fails with
the old implementation and passes with the correction. Candidates now consume
the copy budget only after an actual enqueue. An all-full control preserves
the pending ACK and reports backpressure; it does not manufacture acceptance.

Alternates must retain the primary's receiver cookie and protected receiver
key. Without an ACK route, the stream's existing Bulk binding supplies these
constraints; missing binding does not authorize a guessed destination. Tests
cover both binding sources, wrong cookies/keys, and the successful-copy limit.
The existing remapping predicate is shared without changing its semantics.
The ordinary local and wire priority remains INTERACTIVE. No relay media
classification, new transit priority, mailbox policy, RTO or window change is
introduced. The controlled test proves the mechanism, not a healthy third path
in the physical run.

All **44 FFI anonymous-stream tests** pass; all-target Clippy and formatting
checks pass. Production Mac and Android SDK builds pass, with the same **198
SDK export names**. Frozen libraries, current sources, installed APK and the
Mac process's loaded SDK were checked before and after the transfers. Ordinary
frontends and media engines were unchanged; no calls or synthetic media ran.

| Direction | Size | Download | Attempts | Result |
| --- | ---: | ---: | ---: | --- |
| Phone → laptop | 4 MiB | 12.772 s | 1 | Exact SHA-256 match |
| Laptop → phone | 4 MiB | 15.005 s | 1 | Exact SHA-256 match |
| Phone → laptop | 32 MiB | **Timed out at 180 s** | 2 | Incomplete; final hash unverified |

The phone used cellular data with Wi-Fi off; all opens were anonymous, with no
direct stream. First request to validated manifest took 2.432, 0.591 and 2.372 s
respectively. Neither small transfer needed a payload-idle retry. The failed
large upload still had two failed attempts. The largest sampled local enqueue
waits were **4 ms on the laptop** (163 samples) and **5,052 ms on the phone**
(190 samples). These are approximately one-second driver samples, not absolute
maxima or end-to-end delays. Separate runs and different attempted payload
volumes do not establish a general speed improvement or a unique stall cause.

QA policies and the temporary Android diagnostic property were restored and
verified. Both owned app processes and captures exited. The original phone APK
was restored with an exact hash match, preserving data; owned file fixtures
were removed. The installed Mac app was unchanged. Public evidence contains
only aggregate values, not identifiers, keys, addresses or file hashes.

## Previous follow-up — 23 October: handshake timing and actual stream route recovery

[stream-route-recovery.json](stream-route-recovery.json) records SDK
`62d6b15d`. **Cold startup, long payload stalls and audio/video quality remain
open.** The controlled fixes below do not establish that the field stalls have
been eliminated; an unsuccessful large transfer is included in the evidence.

### Confirmed mechanisms and corrections

Tracked SYN/SYN_ACK timers started before the local carrier accepted them.
A **250-ms** local wait triggered a handshake network retry against a **50-ms**
test RTO, with no handoff. The async driver now tracks handshake handoffs as
well as DATA/FIN. Only a handed-off, unconfirmed handshake can report its network
timeout. A continuously rejected local handshake still closes after the
configured handshake retry budget, without manufacturing a network-loss event.
Real network retry caps remain active. A duplicate SYN after confirmation does
not rearm handshake recovery. Standalone sans-IO timing conventions are retained.

Handshake timeouts were also absent from the driver → mux → hub → circuit
recovery path. The notification now reaches the carrier. A controlled exchange
using the real driver, mux and SDK adapter loses its first locally accepted SYN,
then delivers the exact request/reply over an available alternate. Disabling
hub forwarding makes this same exchange fail; exact source is restored after
the control. This ready wire is controlled in memory, not a WAN latency test.

The existing non-quarantining DATA recovery removed a sticky route cache pin,
but the pool's handshake-membership index immediately selected **the same old
circuit**. A real-runtime regression reproduced this despite an available
alternate. Recovery now updates both indices atomically, using pool → route
lock order to prevent concurrent refill from retiring the selected target.
The affected Bulk pin and an ACK pin using the same old circuit move together;
other streams, their active counts and the shared pool are preserved. Missing,
closed, cooled or admission-full alternatives leave the current path in place.

The new recovery path also preserves the exact receiver cookie and protected
receiver key: a valid ad for another device or key generation does not own
this stream's reassembly state. An unguarded candidate failed this regression.
Both handshake and DATA recovery now reject those changes, while matching
protected receivers remap successfully. Membership retains its existing bound.
No relay media classification, transit priority, mailbox policy, wire format,
network RTO constant or queue/window ceiling changed.

### Gates

All **70 stream tests** and **42 FFI anonymous-stream tests** pass, including
both handshake roles, accepted network loss, local backpressure/cancellation,
the local retry budget, duplicate SYN, real mux forwarding, both route indices,
other-stream preservation and receiver binding. All-target Clippy and rustfmt
pass. Production Mac and Android SDK builds pass; the **198 SDK export names**
match the prior library. Ordinary stand frontends and native media engines are
unchanged. No synthetic media, new production test hooks or calls were enabled.

### Physical qualification and unresolved failure

The phone used cellular data with Wi-Fi off. All opens below were anonymous,
with no direct stream. Source hashes, frozen SDKs, installed APKs and the Mac
process's loaded library were verified for each build.

| Build / direction | Size | Download | First request → validated manifest | Result |
| --- | ---: | ---: | ---: | --- |
| Before receiver-binding guard, phone → laptop | 4 MiB | 104.367 s | 26.402 s | SHA-256 matches; four no-manifest timeouts and one other failed attempt |
| Before receiver-binding guard, laptop → phone | 4 MiB | 9.748 s | 0.760 s | SHA-256 matches |
| Before receiver-binding guard, phone → laptop | 32 MiB | **Timed out at 180 s** | 7.162 s | Not completed; final hash unverified |
| Final guarded SDK, phone → laptop | 4 MiB | 54.630 s | 3.177 s | SHA-256 matches after automatic resume |
| Final guarded SDK, laptop → phone | 4 MiB | 28.789 s | 1.158 s | SHA-256 matches |

The failed 32-MiB run had a **20-second payload idle timeout** after
**12,644,300 received bytes**, plus another failed attempt. The final guarded
phone upload also had one 20-second payload idle timeout before successful
resume. The final SDK was retested with the two 4-MiB files, not another
32-MiB upload. **General stream stalls and large-file completion are therefore
not qualified as fixed.** These separate runs cannot isolate network changes,
prove a speed improvement or rule out a performance regression. The controlled
handshake fixes are not established as the cause of the field cold-start delay.

QA policies were restored and verified after both runs. Both owned applications
and log captures exited; process absence was checked independently. The exact
original phone APK was restored and hash-verified, owned phone fixtures removed,
and the Android diagnostic property left unchanged. Public evidence contains
only aggregate values, with no raw identifiers, keys, addresses, paths, packet
sequences or file hashes. No subjective sound, video or multi-device partition
qualification is claimed by these file tests.

## Previous follow-up — 23 October: retain cells rejected by stale or failed circuits

[local-enqueue-retention.json](local-enqueue-retention.json) records aggregate
evidence for SDK `a84f3223`. The preceding local-handoff correction could not
help when the carrier falsely declared acceptance. Further actual adapter
branches did that: a stale scalar route returned success, a stale DATA run
drained its queue, and a non-queue enqueue rejection discarded unaccepted
scalar cells or the rest of a run. None had reached the local transport.

Those branches retain the exact cells and report local backpressure. Missing
routes use the existing 25-ms retry hint; full queues retain the ordinary
1-ms retry. An oversized envelope fails permanently instead of retrying or
quarantining a healthy route. An ACK actually accepted on an alternate can
still release the pending ACK. Accepted prefixes are accounted for even when
the next cell encounters a full queue.

Striped sends now preserve the concrete enqueue error and the relative order
of all unaccepted cells, ahead of unrelated queued suffixes. Previously a
missing route was reported to health tracking as queue-full, and a later full
queue could move earlier rejected cells behind its unsent tail. Healthy
stripes still make progress, and only actual handoffs update send activity.
The lossy media-datagram path, relay scheduling, wire format, C ABI, network
timeouts and queue/window ceilings are unchanged.

### Verification

The real pre-correction scalar function and rejection behavior were restored
temporarily: both stale-route and enqueue-rejection regressions failed.
Exact corrected source was restored afterward. Fixtures create real circuits,
signed directory entries and local session outboxes, without public network
connections. Each has a distinct identity and verifies its service binding.

All **37 FFI anonymous-stream tests** pass, including eight new controls for
healthy sends, retained controls/DATA, partial admission, actual queue-full,
non-prefix stripes, mixed missing/full routes, fatal oversize, and an ACK
accepted by an alternate. All-target Clippy and rustfmt pass. Production Mac
and Android SDK builds pass. Frozen inputs, the installed APK and the Mac
process's loaded SDK were verified before and after physical qualification.
The ordinary stand frontends and native media engines were unchanged; no
synthetic media or new production test hooks were enabled.

### Physical result and limits

The phone used cellular data with Wi-Fi off. QA-contact P2P was denied for
these anonymous-stream transfers, then restored and checked. All three files
passed final SHA-256 verification within the unchanged 180-second test window.

| Direction / size | Download | Requests | No-manifest timeouts | First request → validated manifest | Payload idle timeouts |
| --- | ---: | ---: | ---: | ---: | ---: |
| Phone → laptop, 4 MiB | 64.152 s | 7 | 6 | 54.655 s | 0 |
| Laptop → phone, 4 MiB | 35.573 s | 1 | 0 | 0.740 s | 0 |
| Phone → laptop, 32 MiB | 126.166 s | 2 | 0 | 0.928 s | 1 |

The large transfer resumed automatically after **20 seconds** without payload
progress at **25,367,940 bytes**, and the final file matched exactly. This is
successful recovery, not elimination of the stall. **Cold startup and general
stream stalls remain open.** Separate runs cannot isolate network variation,
establish a speed improvement or rule out a performance regression. This does
not certify every former large-transfer failure or any audio/video quality.

Both owned applications and the capture exited, independently checked after
cleanup. The exact original phone APK was restored and hash-verified; owned
phone file fixtures were removed. The Android diagnostic property was not
changed. No call or physical audio device was opened. Public evidence omits
identifiers, addresses, raw paths, keys, packet sequences and file hashes.

## Previous follow-up — 23 October: start network timers at local carrier handoff

[local-handoff-timers.json](local-handoff-timers.json) contains aggregate proof.
The async stream driver reserved DATA/FIN as network flight before the local
carrier accepted them. A controlled **250-ms** local block triggered a network
RTO despite **zero DATA handoffs**. This manufactured loss and could collapse
the sending window while the data was still waiting locally.

The driver now confirms accepted DATA/FIN using a bounded, reusable multiset
of sequence/span/type tokens, without copying their payloads. This handles
non-prefix acceptance by striped routes. The engine reserves window space at
poll time, but starts network timing on carrier acceptance. Locally pending
attempts cannot independently trigger RTO/RACK or accept impossible ACK/SACKs;
an earlier handed-off copy can still be acknowledged. Segment matching uses
one linear pass per handoff. Standalone sans-IO callers preserve their existing
poll-as-send convention; the async driver opts into tracking internally.

Selective repair preserves the local queue during no-SACK recovery. Tests
cover late valid ACKs after rewind, sequence wrap, FIN, and real accepted
network loss while another segment is locally blocked. A separate fix excludes
only the pacing wake-up while a committed outbound queue prevents further
polling: the old due pacing deadline could spin instead of waiting for the
carrier retry. Actual protocol deadlines remain active. Wire formats, C ABI,
network timeout constants, relay policy and window ceilings are unchanged.

All **65 stream tests** and **29 FFI anonymous-stream tests** pass, with clean
all-target Clippy and rustfmt. Three real-driver local-queue scenarios cover
**12 combinations** of RACK and no-SACK rewind. Real network loss still triggers
recovery and all recovered bytes match exactly. Production Mac/Android SDK
builds pass. Physical apps used unchanged ordinary frontends, verified frozen
SDKs and no native media test hooks. Only explanatory comments changed after
physical qualification; the expanded test matrix also passed.

### Physical result and remaining defect

Both directions used anonymous streams; the phone was on cellular with Wi-Fi
off. Each **4-MiB** file passed SHA-256. Phone → laptop took **53.277 s**, with
**3 manifest requests / 2 timeouts** and **18.814 s** to the validated manifest.
Laptop → phone took **39.153 s**, with one request, no manifest timeout and
**0.676 s** to the validated manifest. **The cold-start failure is still open.**
These runs do not establish a speed improvement. Carrier acceptance also
precedes possible SDK/OS queues and peer receipt; it is not a wire timestamp.
Other adapter branches that declare success after discarding a cell need
separate investigation. No call/audio-quality or large-file-completion claim
is made. Owned apps exited; the exact original phone APK, QA policies and
Android diagnostic property were restored and verified. Public evidence
contains no raw identifiers, addresses, file paths, keys or packet sequences.

## Previous follow-up — 23 October: retain cells while a stream route is cold

[cold-route-backpressure.json](cold-route-backpressure.json) contains only
aggregate evidence. SDK `b27aa766` corrects another first-manifest failure
mechanism. **General transfer throughput and audio/video quality remain open.**

### Confirmed mechanism and correction

The real circuit-backed `CellSender` returned success when route construction
had produced no usable circuit. Its scalar path discarded the cell; its DATA
batch path drained the entire unsent run. The stream engine had already
committed those cells to flight, so the driver could only recover through
network retransmission. A locally unsent SYN therefore paid the unchanged
**six-second handshake RTO**, even after the route became available.

Both no-ready-route paths now retain the exact cells and report local
backpressure. A typed local retry hint gives cold routes a **25-ms** cadence;
ordinary queue-full errors keep their **1-ms** retry. Hints are bounded to
1–1000 ms. The delay starts after the asynchronous send attempt returns and
uses the driver's timer selection, preserving cancellation/read processing.
Network RTOs and the wire format are unchanged. An ACK copy that was actually
accepted on an alternate path can release the pending ACK; it need not be
duplicated again on every local retry of an unavailable primary.

Two new regressions fail against the old production behavior: the actual
offline SDK adapter acknowledges/drains unsent controls and DATA; the actual
mux/driver then fails to deliver a request/reply within two seconds after a
controlled route becomes ready. With the correction, the same tests preserve
the exact distinct cells and complete the exchange. The ready wire in that
second test is controlled in memory; it is not a WAN latency qualification.

All **58 onion-stream tests** and **29 FFI anonymous-stream tests** pass.
Virtual-time tests cover the slower retry after an asynchronous send and
cancellation during backoff. Clippy for both packages with all targets and
rustfmt pass. Production Mac and Android SDK builds pass. The field apps use
unchanged frontends, ordinary native engines and verified current SDK binaries;
only the trait's explanatory documentation was clarified after qualification.

### Physical comparison

The phone remained on cellular with Wi-Fi off. Both downloads used anonymous
streams with QA-contact P2P temporarily denied; no direct stream was opened.

| SDK | File | Manifest attempts / timeouts | First request → validated manifest | Complete download | Verification |
| --- | ---: | ---: | ---: | ---: | --- |
| Prior `9bfa7190` | 4 MiB | 3 / 2 | 17.957 s | 47.218 s | Exact SHA-256 match |
| Corrected functions | 4 MiB | 1 / 0 | 1.957 s | 66.827 s | Exact SHA-256 match |

The prior driver snapshots include SYN_SENT at age **6002 ms** with no local
backpressure reported. The new run has no sampled SYN_SENT interval, which
does not prove an instantaneous handshake. The controlled regressions establish
the local discard defect; these separate field runs are consistent with the
startup correction but cannot isolate every network effect. **The complete
new download was slower.** These observations do not establish a throughput
improvement or rule out a performance regression. Long local queue waits and
their interaction with data retransmission timers still need controlled
qualification.

Both QA-contact policies were restored and checked. Owned applications and
capture processes exited; owned phone source fixtures were removed. The exact
original phone APK was restored and hash-verified, and the Android diagnostic
property returned to its pre-test value. No call or physical audio device was
opened. No raw stream id/sequence, identity, address, cookie, file path/name or
credential was exported.

## Previous follow-up — 23 October: stream rendezvous ordering and anonymous files

[stream-rendezvous-ordering.json](stream-rendezvous-ordering.json) records
aggregate proof only. SDK `9bfa7190` removes a compiled preference for one
relay from a historical public stand. Outbound stream construction also used
relay-id ordering after resolution, discarding the resolver's newest-first
criterion. When a partial refresh retains older valid fallback registrations,
that can promote an earlier process's receive circuit over a fresh one.

The endpoint now ranks by an explicit operator preference, then registration
freshness, then relay id. Equal entries retain resolver order. Per-relay
deduplication therefore keeps the newer cookie; normal signed-ad validation,
fallback retention and the existing circuit cooldown filters still apply.
The relay preference has no built-in default. The local operator override
remains available.

The current-registration regression fails with the **actual old comparator**
temporarily restored in the real FFI module; it passes with the correction.
The original source is restored unconditionally after that control. The final
anonymous-stream suite passes **27 tests**, including real circuit-feed ARQ,
local producer isolation and authenticated media ingress. Equal-generation
ordering, duplicate-relay cookies and an explicit operator preference are
covered. Rustfmt and production SDK builds for Mac/Android pass.

### Physical verification

Both owned QA applications used ordinary production native engines and the
freshly built SDK. The exact installed Android APK and the Mac process's
loaded SDK path were checked; frozen build-input hashes stayed unchanged.
An obsolete disposable PacketTunnel build was stopped before it could supply
the stand's SDK. The frontend build then consumed frozen current libraries.
This was a stand construction correction, not a product-source change.

The phone used cellular data with Wi-Fi off. P2P was temporarily denied only
for the two QA contacts. Receiver logs confirm an **anonymous stream** in both
directions, with one request, no direct-stream open and no manifest timeout:

| Direction | Size | Request → validated manifest | Complete download | Verification |
| --- | ---: | ---: | ---: | --- |
| Phone → laptop | 4 MiB | 7.293 s | 87.781 s | Exact SHA-256 match |
| Laptop → phone | 4 MiB | 0.356 s | 64.412 s | Exact SHA-256 match |

These are successful first attempts on the corrected clients and updated
relay fleet, **not a controlled before/after attribution** to the ranking
change. The earlier failing capture proves the historical stand preference
was active, but its candidate ads had the same generation: stale generation
is not established as the cause of that timeout. The new cold header still
approaches the existing eight-second first-byte bound, and anonymous transfer
throughput remains low. Cold-start latency and the remaining audio/video
failures require further work; two successful downloads do not close them.

No call or physical audio device was opened in this cycle. Both QA-contact
policies were restored and checked, owned phone file fixtures removed, owned
apps exited, and the exact original phone APK was restored and hash-verified.
The disposable tunnel-build script was restored. Public evidence contains no
identity, relay address, file name/path, request id, cookie or credential.

## Previous follow-up — 23 October: delivery stages and subthreshold probe recovery

[socket-to-kernel-delivery.json](socket-to-kernel-delivery.json) and
[direct-relay-follow-up.json](direct-relay-follow-up.json) contain aggregate
evidence only. **The physical video freeze and long delivery tail remain open.**

### Separating local queues from delivery

The 179.88-second direct call enabled endpoint UDP tracing on both sides.
Encrypted datagrams are joined only by a unique matching digest and size,
on local connections accepting the owned primary source. Grouped receive
timestamps, ambiguous matches and packets outside the calibrated interval
cannot supply a one-packet delay. These are opaque datagrams on those
connections, not an audio-only measurement or a packet-loss census.

Start/end phone-wall-clock brackets form a conservative 47.19-ms offset
envelope. Assuming no unobserved clock step outside that envelope, the
matched socket-send-to-peer-kernel maxima are:

| Direction | Eligible matches | Lower bound on maximum | Upper bound on maximum | Peer kernel-to-poll maximum upper bound |
| --- | ---: | ---: | ---: | ---: |
| Laptop → phone | 230 | 1085.51 ms | 1133.70 ms | 4.89 ms |
| Phone → laptop | 276 | 1134.05 ms | 1182.24 ms | 1.69 ms |

Socket send is recorded after successful OS handoff. This span includes
sender OS transmit queues and the external network, and does not identify
the provider or NIC as the cause. QUIC acceptance is an earlier stage:
budget admission to acceptance peaked at 0.274/3.580 ms. The laptop QUIC
connection also recorded a **199.14-ms lifetime datagram queue maximum**,
mostly congestion-window blocking. Lifetime maxima are not packet latency
percentiles and cannot be added to unrelated maxima to reconstruct one packet.

The separate 179.97-second relay comparison used only temporary QA-contact
P2P overrides, which were restored and checked. Ordinary ordered relay paths
were active; no direct QUIC media path was reported. Video froze there too:
laptop/phone sent 3/3 frames and decoded 3/3, versus 5/3 sent and 2/4 decoded
in the direct capture. Both calls used continuous synthetic PCM through the
real codecs/network, real cameras, and no physical audio device. They were
separate network observations, not a controlled causal quality comparison.
Matching ciphertext across endpoint sockets cannot measure a relay path whose
hop encryption changes, so no relay one-way UDP latency is claimed.

`scripts/analyze_physical_udp_delivery.py` reproduces the direct timing
summary without exporting digests, connections, cells, wall offsets, payloads
or addresses. Its **10 tests** cover both clock directions, uncertainty,
capture boundaries, ambiguous/replayed samples, other connections, missing
kernel/GRO timestamps, clock/size contradictions and lifetime maxima.

### Confirmed recovery-policy correction

Native duration windows already distinguish small repairs from significant
speech damage when deciding video cuts. The sparse-resume gate nevertheless
rejected every fresh concealment/catch-up event, even when the same duration
measurement explicitly said the damage was below its threshold. A sequence
of small repairs could therefore keep video paused indefinitely.

Measured subthreshold repairs now allow the existing three-sample recovery
to release **only the one-fps trial**. Raw repair events still hold growth.
Significant damage, interruptions, admission/network loss, unsafe or missing
playout measurements, and unknown/partial duration support retain their
protection. Buffer and duration thresholds are unchanged.

The new public-adapter regression failed on the old code (the trial stayed
paused), then passed with the correction. Partial support in either direction
and significant-damage controls also pass. **270 tests** across the adapter,
source pressure/recovery, transient loss, buffer windows, video delivery and
group adapter pass; the two changed Dart files analyze cleanly.

These physical captures preceded the policy correction. They contain frequent
significant audio damage, so the correction is not represented as resolving
their freeze or as a new physical quality qualification. No live speech,
headphone loudness or acoustic latency assessment was performed. Owned apps
exited, QA policies and the exact original phone APK were restored; the
ordinary private stand artifact was restored as well.

## Previous follow-up — 23 October: sparse video and long Opus packets

[sparse-video-packetization.json](sparse-video-packetization.json) contains only
aggregate evidence. **Physical video freezing remains unresolved.**

The native packet-duration gate required an emitted <=40-ms Opus packet before
releasing video, even when the application had already selected its one-fps
recovery trial. On a narrow audio allocation this could prevent the trial from
starting. A source actually capped at **<=1 fps** can now coexist with 60-ms Opus.
The explicit audio pause still stops that source; larger cadences retain the
existing short-packet gate. The source cap is applied before sparse permission
opens, and permission closes before raising cadence. No audio payload floor,
route ceiling, relay role, priority or mailbox policy changed.

A new regression uses the public video APIs, two real Opus/VP8 engines and a
lossless mocked Veil boundary at a fixed 48-kbit audio allocation. With actual
60-ms packets, the old library sends **zero** video frames in three seconds;
the corrected library sends **three**, and the receiver decodes at least two.
Explicit pause, resume, blocked unfunded 3-fps mode and return to 1 fps pass.
The existing packet-policy/real-Opus gate decodes **991** valid packets. Both
production libraries build with **105** public exports and no test hooks.

The frame-sizing integration gate also exposed a pre-existing fixture defect:
both libraries failed its immediate zero-cap assertion after profile retune.
The test now waits for the asynchronous encoder update and funds the group
fixture through the real allocator, because that source-only fixture has no
receivers providing transport feedback. The original zero-cap recovery
requirements remain. Direct/group integration and frame-budget unit gates pass.
The additional allocator helper exists only in test builds.

The **179.64-second P2P phone/laptop call** with continuous synthetic PCM and
real cameras again stopped video: Mac/phone sent **5/2** frames and decoded
**1/4**. The application audio pause persisted. This field failure is retained,
not represented as a successful video recovery. Both source/render drivers
kept ticking: their maximum intervals were **11.04/18.32 ms**, with no failed
ticks or driver restarts.

Packet joins narrow the remaining delay to the interval between sender native
admission and receiver native arrival, which includes **SDK queues and the
network**. Estimated maxima were **1171.96/1166.88 ms** (Mac-to-phone/reverse),
with a combined initial clock-bracket width of 5.09 ms; clock-rate drift was not
bounded. Sender admission maxima were **0.066/2.213 ms**, and receiver-native
handoff maxima **4.994/0.094 ms**. Source RTP attempt gaps stayed below
**65.77/77.94 ms**. These measurements do not identify the wire or provider as
the sole cause, and local acceptance is not actual wire transmission. They also
do not assess acoustic latency or intelligibility. The next investigation must
separate SDK queueing from network delivery on this interval.

Owned apps exited, original phone APK/hash and ordinary private stand artifacts
were restored. No raw trace, identifier, address, payload or credential was
exported.

## Previous follow-up: packet waiting time follows actual renders

[packet-wait-render-clock.json](packet-wait-render-clock.json) contains aggregate
results only. **The video freeze remains unresolved.**

A regression using the production factory and real NetEq/PCMU proved that
catch-up aged queued packets by **170 ms within one 10-ms render callback**.
The controller's arrival history already used a separate render clock, but
NetEq's default packet-buffer stopwatches still followed the decoder clock,
which advances for every discarded block. This false waiting time also feeds
NetEq's future-packet and post-concealment decode decisions.

The packet buffer now shares the existing render clock with arrival history.
The decoder's internal clock and recovery/quality thresholds are unchanged.
The regression now reads **10, 20, 30 ms** after three successive renders;
the first render still discards the same 160 ms of queued stale audio.

The unit gates, 120-second real Opus speech/DTX/resumption scenario, recurring
jitter at both buffer capacities, and real three-party mixing/JSON gate passed.
Fresh mixed group audio measured **171.97 ms** against the unchanged 200-ms gate.
Mac and Android native builds succeeded.

An independent **179.61-second** phone/laptop P2P call used continuous synthetic
PCM through the real Opus engines/network and actual cameras, without opening
physical audio devices. Neither PCM driver restarted. Nonquiet decoded blocks
were 98.16%/99.46% in the audio-only interval and 98.77%/99.33% with cameras
(Mac/phone); the preceding field control had lower fractions. These are signal
presence observations, not a listening or acoustic-delay assessment, and network
variability prevents attributing their entire difference to the clock fix.
Video still failed: Mac/phone sent **3/0** frames and decoded **0/1**. Application
and native packetization holds persisted, so the clock correction does not
establish that video adaptation is fixed.

Owned apps exited after collection. The original phone APK was restored and
its hash verified; the ordinary private stand artifacts were restored too.
No synthetic hook or test override was added to production code.

## Previous follow-up: valid group JSON and direct audio counters

[group-stats-and-audio-counters.json](group-stats-and-audio-counters.json) contains
only aggregate results. **Video remains unresolved.**

### Confirmed production fix

Group delivery statistics used a binary 32-byte participant id directly as a
JSON object key. NUL bytes truncated the C string; quotes, backslashes and
non-UTF-8 bytes could invalidate it. The native getter now emits hex keys. This
restores complete group statistics for application parsing and adaptation.
Anonymous diagnostic export still omits both participant-keyed maps.

The real group test now uses ids containing NUL, quote, backslash and `0xff`,
parses the complete output as UTF-8 JSON, checks both expected hex keys and
requires numeric recovery fields to exist. **Its original PCM and timing gates
were retained.** Final result: fresh mixed output from both sources at **170.56
ms**, 50 warm mixed ticks, 15 recovered mixed ticks, six catch-up events, 880 ms
trimmed, no fallback. The gate exited successfully.

This also corrects earlier validation wording: the old group probe printed good
PCM timings but exited with status **5**. Its missing JSON counters had silently
been interpreted as zero. That run was not a passing gate. The cause was the
malformed native JSON; no quality threshold was relaxed to make it pass.

### Experiment removed after checking the evidence

A new local-reserve condition for preemptive expansion passed a targeted unit
case, the long-Opus and recurring-jitter experiments, but did not restore video
on the phone. It was **removed from the final code**. Final production audio
policy is unchanged from the preceding SDK commit.

Direct native `inserted_samples_for_deceleration` and
`removed_samples_for_acceleration` counters now appear in the native snapshot
and the explicit anonymous-journal numeric allow-list. The control with the old
audio policy measured only **33.94/74.44 ms** of inserted audio on laptop/phone,
while forced catch-up discarded **2,510/8,680 ms** over approximately 119 seconds.
A large expansion/discard loop is therefore not supported by these counters.
Earlier inference from rendered RTP timestamp differences was not an
authoritative measurement of added samples.

Both the 179-second experiment and 119-second control stayed connected but sent
**zero video frames**. Their routes differed (mixed P2P/relay versus relay), so
latency changes cannot be attributed solely to the experiment. Native receive
callback-to-worker handoff on the phone had p95 below **0.73 ms**, maximum below
**4 ms** in these runs. This bounds that local handoff only, not SDK, sender or
network queues. The remaining audio damage and source holds need investigation
with sustained audio input; live microphone tests were mostly quiet.

### Final verification and cleanup

- Final decoder/catch-up unit gate and real group PCM/JSON gate passed.
- Four anonymous-journal tests passed, including rejection of both real
  participant-map field names; the two changed Dart files analyze cleanly.
- Both production native builds retain **105 C ABI exports**, with test hooks
  and synthetic media disabled. Final native source matches the physical
  control build, including the retained Android disconnect recovery.
- Owned applications, native test processes and log captures exited. Owned
  phone traces/cache were removed, the original phone APK restored and its
  hash verified. No raw/native trace, identity, address or key was exported.
- Speech intelligibility and acoustic loudness remain unassessed; no relay
  classification, priority or mailbox fallback was added.

## Previous follow-up: Android device disconnect

[aaudio-disconnect.json](aaudio-disconnect.json) contains only aggregate results.
The previous apparent P2P path stall had an endpoint cause in this reproduction:
turning on the camera selected the speaker, Android disconnected **both AAudio
streams**, and the ADM had no error callbacks to reopen them. The phone's audio
RTP attempts stopped for about 15 seconds while incoming audio still advanced.
A receiver-side silence timeout then initiated relay recovery. That timeout did
not establish a broken network route.

The ADM now registers error callbacks and recreates the affected stream on one
owned worker, serialized with ordinary stop/device/start operations. Generation
checks reject retired work. Stop/destruction close callbacks and join the worker;
no detached recovery thread survives the ADM. Temporary open/start failures retry
with a delay. A failed initial `requestStart` now returns failure and closes the
stream, instead of reporting successful recording/playout. FineAudioBuffer is
rebuilt after the reopened device's actual format is known. WebRTC's control
sequence remains responsible for starting/stopping AudioDeviceBuffer.

This follows the [AAudio disconnect contract](https://developer.android.com/ndk/guides/audio/aaudio/aaudio):
stop/close/reopen must happen outside its error callback thread.

### Verification

- A host smoke test compiles the **production ADM**, real WebRTC buffer and a
  controllable AAudio backend. The old source fails both the missing callback
  and false-success startup regressions. The corrected source passes capture
  and playout recovery, temporary open failures, failed recovery starts,
  a callback racing close, explicit stop and destruction with recovery pending.
  Command: `TMPDIR=/private/tmp/ python3 flutter/veil_media/test/run_aaudio_disconnect_smoke.py`
  from the Veil repository with the normal WebRTC build available.
- The production Android library builds with the usual **105 C ABI exports**.
  No synthetic capture or test hooks were enabled in the physical app.
- During a new **179-second** phone → laptop call, camera enable again caused
  Android's disconnect error. Capture reopened in **520 ms**, playout in
  **245 ms**. Both counters reflect one successful reopen, not an engine rebuild.
- The maximum gap between encoded phone audio packets changed from **15,939.85
  ms** in the prior run to **1,009.24 ms** in this run. This measures source
  production, including DTX/capture scheduling; it is not acoustic latency.
  Both endpoints stayed on **P2P for the complete call** and audio counters
  continued after the route change. Network variability prevents a general
  latency or sound-quality guarantee from this comparison.

### Still unresolved

Video again stopped after its first frames: laptop/phone sent **3/5** frames
and decoded **4/3**; the last decode advances were at **68.44/65.36 s**, after
camera enable at **60.25 s**. Reported nonzero FPS then remained stale. Native
packetization and application audio-protection holds still need work; repeated
forced catch-up remains present. Fixing device recovery does not prove that
video adaptation or end-to-end audio quality is fixed. No live speech or
listening assessment was supplied.

Both owned apps and log captures exited afterward. The original phone APK was
restored and its hash verified. No relay behavior or transport priority changed.

## Previous follow-up: content credit and audio reserve

[credit-and-audio-reserve.json](credit-and-audio-reserve.json) contains only
allow-listed aggregate results. Raw traces, endpoint identities, addresses,
profile names, file names, device labels and keys remain outside the repository.

### Corrections and verification

- Reliable content streams negotiate a 256 KiB application-read window with
  cumulative credit every 64 KiB. The first 128 KiB implementations prevented
  queue-full markers but were too slow to finish 32 MiB within 180 seconds;
  they were not accepted as the final fix. The final sliding window retains
  bounded reads and compatibility with old clients/servers. Credit is not
  durable delivery; existing piece and final hash verification remain required.
- The native RTP-age catch-up path no longer drains below the adaptive decoder
  reserve merely because audio spent time upstream. The new regression fails
  on the old code. The independent hard local-storage budget is unchanged.
  The long-Opus and recurring-jitter gates pass; the earlier group
  probe did not pass its exit-status gate (corrected in the latest follow-up). Recurring-jitter
  arrivals now follow source RTP time to avoid unrelated callback-boundary
  variation between controls; no acceptance threshold was relaxed.
- The complete Flutter suite passes **5,777 tests, 154 skipped** for the sliding
  protocol. After changing only its window size, the final content, credit and
  idle-write subset passes **70 tests**; all six changed Dart files analyze
  cleanly. Slow sinks, cancellation, partial/invalid ACKs, final-close races,
  FIFO writes, range resume and both legacy compatibility directions are covered.

### Physical file results

| Direction | Size | Download time | Verification |
|---|---:|---:|---|
| Phone → laptop | 32 MiB | 142.09 s | Exact SHA-256 match |
| Laptop → phone | 32 MiB | 52.30 s | Exact SHA-256 match |

The phone used cellular data with Wi-Fi disabled. During the upload the owned
laptop receiver process was stopped for five seconds after at least 4 MiB and
then resumed. No queue-full marker or payload restart was observed. The first
upload attempt timed out **before its manifest**; a warmed direct-stream retry
then carried the complete payload. The reverse transfer needed one request.
The physical payload used direct streams; anonymous transport and compatibility
were also checked in the simulated transport tests. Older peers retain their
uncredited behaviour. These measurements do not establish a universal speed.

### Calls remain unresolved

Clean production native engines, real microphones/cameras and the normal SDK
were used for both calls; the temporary file-test SDK probe was removed first.

- Laptop → phone: incoming signaling took **1.10 s**, connection after answer
  **2.55 s**. The call remained connected for **139 s**, but only nine laptop
  frames and zero phone frames were sent; decoding froze. Sampled local audio
  delay peaked at **210/749 ms** (laptop/phone). The reserve correction did not
  establish recovery of video or elimination of catch-up events on this path.
- Phone → laptop: **179 s**, with cameras enabled at **60 s**. Audio trouble
  existed before video: native receive age reached **844/693 ms** and sampled
  forced catch-up totals reached **340/4,970 ms** in the first 55 seconds.
  After camera enable, the call switched from P2P to relay at about **65–66 s**.
  Sampled native receive age on the laptop peaked at **14,041 ms** around
  recovery; phone local audio delay peaked at **1,704 ms**. Only five/two sent
  video frames were counted across media epochs. The call survived, video did
  not recover. Nonzero retained FPS was not treated as decoder progress.

Audio packet counters progressed in both directions. This does not certify
speaker audibility or speech quality: the user could not listen or speak during
these tests. Local buffer delay is not acoustic end-to-end latency. A single
field network does not identify the carrier, a relay or the endpoint as the
cause. Call quality and the P2P-to-relay stall remain release risks.

All owned apps and log captures were stopped afterward; original phone APK
restoration and its hash were verified, and owned phone file fixtures removed.
No relay classification, relay priority, mailbox fallback or container change
was introduced. Commits for this cycle are local and unsigned.

## Previous follow-up: paused-source feedback and receive queues

[follow-up.json](follow-up.json) contains only aggregate measurements.

### Corrections verified

- SDK `76820278` drains already queued receive fragments in bounded reads.
  The regression failed on the old code (2,048 bytes returned for 65,536 bytes
  already available) and passes after the correction. Short reads never wait
  for a full buffer. Partial frames, empty DATA, EOF and credit accounting are
  covered. All 51 SDK unit tests pass.
- The video delivery model no longer interprets intentionally stopped source
  media time, or a retained old frame's delay, as a growing decoder queue.
  The adapter regression previously kept video paused after audio recovered;
  it now releases only the one-fps floor. Frames acknowledged during a pause
  cannot authorize growth afterward. The adaptation/privacy subset passes
  186 tests; the changed Dart files analyze cleanly.
- Anonymous reports now include explicitly allowed numeric frame counters,
  native video pause/packetization flags, receive age and catch-up/discard
  counts. They still exclude raw/native logs, identifiers and nested peer maps.

### Physical results and unresolved defects

The clean production media engines and SDK were tested with real microphones
and cameras; temporary native probes were absent in the final call. No live
speech or acoustic assessment was supplied.

- Audio transmission from the Mac returned in subsequent runs, including a
  35-second audio call and two approximately 140-second video calls. These
  stayed connected. The earlier zero-transmission startup remains unexplained;
  no capture-driver fix is claimed.
- Before the paused-source correction, false video queue pressure appeared
  in 117/135 laptop samples and 115/135 phone samples. Afterward it appeared
  in **0/135** at either endpoint. Nevertheless, video still froze: only six
  laptop frames and three phone frames were sent, and decoded counters stopped
  progressing after the first approximately eleven seconds. Stale FPS values
  are not evidence of resumed video.
- Fresh audio damage continued to hold video. The final sampled receiver
  catch-up counters recorded 2,670 ms discarded on the laptop and 10,870 ms on
  the phone. The phone remained paused for 130/135 samples. The cause of this
  frequent audio catch-up needs investigation; disabling this safeguard or
  claiming fixed video is not justified by these measurements.
- Two further phone → laptop 32-MiB files completed with exact SHA-256 matches:
  102.61 s before receive coalescing and 126.49 s afterward, including offers.
  **No speed improvement is established.** The coalesced run still reproduced
  SDK receive-queue overflow, followed by thousands of close notifications and
  successful resumption. Coalescing does not provide missing end-to-end
  receive backpressure; file-stream closure remains an unresolved defect class.

The stream-close probes were isolated in a temporary SDK worktree, which was
removed. Apps and owned capture processes were stopped; the original phone APK
was restored with an exact hash match and its process was verified absent.
Test-file caches were removed without removing the user's profiles.

## Follow-up: automatic investigation

Source correction: Veil `c5ca76b9` (unreleased).

The audio Call had a fixed 96,000-bit/s estimator ceiling. With the observed
509-byte route overhead plus a 20-byte RTP header, a 40-ms packet costs
129,800 bit/s including the existing minimum speech payload. With the encoder's
20% reserve and strict integer comparison it needs at least 162,255 bit/s of
gross allocation. Consequently, the old ceiling could never fund the short
packet required to release video's packetization hold after a yield.

The source correction derives the ceiling from framing, retaining 96,000 bit/s
on lower-overhead paths. It changes the base WebRTC constraint: client
preferences alone can only tighten the original ceiling. No minimum allocation,
new bandwidth estimate, relay priority or override of measured audio pauses is
introduced. This removes a necessary recovery obstacle; it does not prove that
the network will supply enough allocation or that all video failures are fixed.

Automated regression evidence:

- Real Opus, including DTX: reproduce the 60-ms hold at the old relay ceiling;
  decode 40-ms packets and admit video after a funded recovery on 209-, 360-
  and 509-byte routes. A requested duration alone cannot release the hold.
- Observe the actual GoogCC constraints during live overhead changes: the
  larger ceiling reaches the controller and returns to 96,000 bit/s when
  framing shrinks. Independent audio/video routes remain separate. The BWE
  handover regression also passes: only genuine committed path changes reset
  their controllers; framing corrections preserve the current path estimate.
- Four SDK stream regressions pass. A closed stream's credit now reports
  `veil stream already closed`, preserving the FFI's existing closed-stream
  classification. A second stream still writes through the same IPC writer;
  a genuinely exited writer retains its distinct failure text. The earlier
  `veil IPC writer task closed` line alone cannot diagnose an IPC-task crash.

Additional physical calls could not validate recovery: the Mac emitted no audio
packets despite authorized microphone access and successful capture-start
status, and calls ended after approximately 21–35 seconds. Repeating with the
exact previous Mac media binary (verified against the saved build hash) also
produced zero outgoing audio. This is an additional unresolved capture/liveness
failure; it is not evidence that the corrected ceiling restored moving video.
The final base-constraint correction is validated by native tests, not a passing
physical call. The failing 32-MiB upload also remains unresolved.

Both endpoints were closed after these checks. The original phone APK was
restored again with an exact hash match; its process and the owned Mac process
were verified absent. No live speech was requested or assessed.

Two physical endpoints: a Mac laptop and an Android phone on cellular data,
with Wi-Fi disabled on the phone. The phone was awake and unlocked. Test profiles
were isolated from existing conversations. The stand frontend used xVeil
`a6b7524b`, Veil `0.11.44` / `c67cfe30` and hidden-volume `2.6.3`. It used ordinary
production media engines and real microphones/cameras, with synthetic media and
PCM injection disabled. Builds finished before network measurements began.

Only aggregate observations are retained here: no peer/device identifiers,
addresses, paths, keys, message contents, camera images or audio recordings.
[summary.json](summary.json) contains the numeric measurements. Private working
captures are excluded from the repository.

## Results

| Case | Observed result |
|---|---|
| Contact request, laptop → phone | Received in 4.15 s; accepted at both endpoints by 5.29 s. |
| Text, each direction | Observed within 0.57 s, one copy each. After the failed large upload both directions still delivered within 0.57 s. |
| 32 MiB, laptop → phone, no call | Completed in 104.50 s; SHA-256 matched. |
| 32 MiB, phone → laptop, no call | Timed out at 180 s. Observed partial file reached 3,932,160 bytes (3.75 MiB); repeated stream reopening did not complete it. The source file was not moved or modified. |
| Audio call, laptop → phone, then enable cameras | Ring in 1.10 s, active 1.02 s after answering. Remained connected for 149 s. Automatically moved P2P → relay at about 35.4 s; the harness requested no route change. Sustained video failed: 2 decoded phone → laptop frames, none in the other direction across sampled media epochs. |
| Initial video call, phone → laptop, after phone restart | Ring in 1.71 s, active 4.72 s after answering. Remained connected for 179 s. Brief relay/P2P transitions settled on relay. The phone decoded 11 early laptop frames, then stopped progressing after about 14.3 s. No phone frames reached the laptop. |
| Audio-only call with two simultaneous 1 MiB files | Call remained P2P for 90 s, without ending unexpectedly. Both files eventually passed SHA-256, taking about 106 s from transfer start; completion was after hangup. |

The first 4 MiB simultaneous-transfer attempt was canceled by the harness before
completion. It is unscored as a product failure. The smaller-file recheck waited
for completion and for its request threads to exit.

## Evidence and remaining questions

### File upload

The receive side logged resume offsets, EOF mid-piece and subsequent attempts
that failed to obtain a manifest. The sending phone reported the fixed SDK
failure `veil IPC writer task closed`, a payload-write idle timeout and later an
onion-stream driver closure. These establish failure in the stream path; they
do not establish which network or application condition caused its first stall.

The ongoing ability to send short messages and establish calls after the failed
upload separates this observation from a complete node/process outage. The
32 MiB reverse transfer remains a failing case.

### Call media

The first automatic relay recovery followed a native audio-receive age above
3 seconds after cameras were enabled. Media counters were grouped by media epoch
so handover resets are not mistaken for an entire call's totals. Reported FPS
was not used as proof of moving video: frame counters stopped advancing while a
stale nonzero FPS value remained visible in one run.

Cameras continued capturing on Android while video transmission was held. Native
`audio_packetization_video_hold` / `video_send_paused` stayed set for most video
samples, with 60-ms audio packetization. This identifies a local admission gate
that requires investigation, including whether audio adaptation can release it
under these conditions. It does not prove that the gate caused the original
network/audio interruption.

Measured jitter-buffer-plus-device audio delay:

| Call | Laptop median / maximum | Phone median / maximum |
|---|---|---|
| First call with camera enable and handover | 10 / 198 ms | 151 / 1657 ms |
| Reverse video call | 32 / 242 ms | 151 / 303 ms |
| Audio-only recheck | 10 / 140 ms | 142 / 201 ms |

These are local buffer measurements, not end-to-end acoustic delay. Live speech,
headphone loudness and intelligibility were not assessed. The observed network
and one endpoint pair do not isolate the carrier as the cause of either defect.

## Cleanup

- All calls ended and owned log-capture processes exited.
- Owned Mac stand process exited; the installed Mac app was not replaced.
- Phone test caches were removed.
- The original phone APK was restored in place, with an exact SHA-256 match,
  preserving existing application data. Restored version: `0.13.88`, code `2107`.
- The phone app process was absent after restoration; the owned ADB forward was
  removed.
