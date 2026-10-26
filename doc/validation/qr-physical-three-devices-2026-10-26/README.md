# Cold physical device linking and three-device delivery

Local verification after ff5312c7, followed by the content-reoffer correction
below. No release, push, production app installation or relay deployment.

## Stand and actual boundaries

A is a Blackview Android QA instance. B and C are separate macOS application
processes with separate encrypted profiles, native nodes, listeners, metrics
ports and debug API ports. A/B finish as identity X; C is identity Y. The phone
uses Wi-Fi. This does not qualify cellular service or Windows 10.

B and C were created through the actual production onboarding widgets with
independent certificate identities. The new Dart bundles were built from the
current source for a cold launch, copied into private signed QA bundles and
verified. No hot reload was used for this qualification. Native Veil is the
previously checked local e01a79d9 build without low-difficulty or media test
hooks. The main installed apps and their data were untouched.

The source A already held a certificate identity. B joined through the source
and target production sheets, entering A's recovery code only on A and comparing
matching safety codes. The QR was decoded from the phone app's rendered pixels
and pasted into B's visible setup field. This proves the copied-QR/LAN path,
not optical camera scanning. Approval, durable admission, the production
AppController's hosted-node restart and subsequent snapshot delivery completed.
Both native running identities agreed; both physical keys stayed unchanged.

The previously failed QA target from the preceding cycle was explicitly revoked
before adding this fresh B. No old encrypted profile or ratchet state was rolled
back. QA credentials, certificates, probes and ownership records remain private.

## Results

| Check | Actual result |
| --- | --- |
| Configured B joins A | A/B show exactly their two physical device keys, one shared identity and one device group; the identity authority is not an extra row |
| History created before B | All 10 marked historical texts arrived once, retaining their logical IDs |
| Cold B process restart | Identity, physical key, device group and those 10 messages survived reopening |
| Contact request C to X, accepted on A | Request arrived in about 3.4 s; acceptance converged on A/B/C in a further 3.7 s |
| C to X text | Appeared once on A/B, with the same logical ID (about 0.7 s) |
| A to C text, B online | Present once on A/B/C with one logical ID (about 3.3 s) |
| B to C text, A online | Present once on A/B/C with one logical ID (about 4.4 s) |
| C calls X, B answers | A/B both rang; B/C stayed active and A stopped ringing; both active endpoints received audio packets |
| C calls X, A answers | A/B both rang; A/C stayed active and B stopped ringing; both active endpoints received audio packets |
| A calls C while B online | A/C active with receive counters advancing; B stayed inactive |
| B calls C while A online | B/C active with receive counters advancing; A stayed inactive |
| A sends a file while B online | B/C got one offer with the same logical ID; C and previously uncached B fetched all 3 MiB plus a nonaligned tail, with matching SHA-256 (about 3.6 s each) |
| B offline, A sends text/file, C then goes offline, B returns | With A still online, B recovered the text and file offer once with the original IDs and fetched the complete uncached file from A; SHA-256 matched |
| A offline, B has an offer, C has saved the bytes | B fetched a complete uncached file from C; SHA-256 matched, before and after the retry correction below |

All four calls used relay media at both active endpoints, verified in captured
call state. Per-contact P2P policies were temporarily disabled for those call
checks and restored afterwards. Each call was observed active for five seconds;
receive counters advanced in both directions and hangup finished everywhere.
These are routing/packet-flow checks. They do not establish live speech
intelligibility, loudness, long-call stability or video quality.

Raw control-group membership counts are not physical-device roster counts: the
sovereign owner is an identity authority, and its signed announcement supplies
the master's physical address. An initial stand verifier incorrectly expected
the owner key itself to be a physical device. Final verification instead
compares both rendered physical key sets with the device invites read from the
actual configurations. The full group and native identity comparisons are
retained privately.

The short offline check includes node unlock, catch-up and file download in
about 24.8 s. It does not reproduce a five-minute/hour/day absence. Recovery
without any available history or content source was not expected or claimed.

## Confirmed content-reoffer defect

The alternate-holder run exposed an avoidable full receipt timeout. A restarted
source had not relearned B's authenticated membership of identity X. Its first
anonymous stream was correctly denied. The requester sent a single live
reoffer and waited the full 60 s for a qualifying ACK. When that request or its
ACK was lost, or the request arrived with only claimed provenance, no later
copy restored the exchange. The next stream eventually succeeded, giving a
67.4 s complete download in that run.

The requester now retransmits the same reoffer at two-second intervals, at most
eight sends within the existing overall deadline. Every send retains normal
ratchet persistence. A source that already processed the unpredictable frame
ID only repeats its generic ACK. Only an authenticated receipt from the pinned
peer/device can release the wait. Cancellation, disposal, timeout and withdrawn
contact consent stop the retransmission timer; retries remain live-only and
are not persisted to outbox or mailbox. No authorization or source ACL was
relaxed, and no relay priority/classification was introduced.

Five new regressions cover loss of the request, receipt and both packets, plus
cancellation and blocking after a retransmission. The three loss tests timed
out before correction and passed afterwards. All 77 content-stream tests passed,
including claimed-source, wrong-peer/device/stale-receipt, restart and existing
cancellation guards. Direct Dart analysis and whitespace checks passed.

The corrected requester was cold-launched against the preceding source build.
A fresh file was saved by C; C was restarted to discard transient requester
proof, A was made offline, and B fetched its previously uncached bytes from C.
The first reoffer was explicitly rejected as claimed, and the same-ID repeat
two seconds later was authenticated. The receipt wait fell from about 60.0 s
to 2.8 s. The complete file matched its expected size and SHA-256.

The corrected transfer still took 56.3 s overall: its retry used an anonymous
stream, spending about 40.3 s after the manifest. The earlier run used a direct
stream after its timeout. Those total durations are not a controlled throughput
comparison. Slow anonymous bulk delivery remains a follow-up; this cycle fixes
the un-retried proof/receipt wait. Reconnect logs also contain bounded publisher-
slot refusals; their separate cause and impact were not established here, and
the native admission cap was not changed.

Follow-up qualification found that the macOS stand above loaded an unoptimized
development Rust library. This preserves its functional observations but limits
its performance evidence. The [optimized anonymous-stream comparison](../anonymous-stream-queued-writes-2026-10-26/README.md)
records a release-profile baseline, a bounded short-write batching correction,
and the remaining connection/route variability.

## Cleanup and remaining scope

All stand-owned calls/downloads finished. Owned app process groups were checked
exited, QA microphone permissions and the own ADB forward were restored, and
stand-owned plaintext source fixtures were removed from Android. Latest QA
profiles and raw artifacts were archived privately for subsequent work. System
volume/power settings and main profiles were unchanged. Some Mac processes
required forced termination after their containers had been cleanly locked;
this was not an injected mid-transaction crash test.

Windows 10, optical QR scanning, cellular quality, live speech/loudness, video,
long offline periods, full call-history convergence, interruption of large
file downloads and the complete 63-scenario campaign remain unqualified by this
cycle. This evidence does not close every symptom in the user's report.
