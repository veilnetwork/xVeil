# Repeated history work during ingest — 2026-10-27

Private stage timing on the retained three-device stand found three complete
message-history passes during device-journal merge. Later debug-Dart windows
spent roughly 0.6 seconds each on the previous accepted set, the merged accepted
set, and reaction targets. Incoming-row deduplication also verified and hashed
unrelated historical rows before comparing their digest.

The change removes two sources of redundant work:

* Deduplication first narrows by sequence and author, both bound by the signed
  digest. Matching candidates still undergo signature validation and full digest
  comparison. A sequence alone never suppresses a distinct signed row.
* Non-Space reaction targets reuse the merged accepted set already prepared for
  notifications. No await or mutation of messages, cuts or control state occurs
  between those two points. Spaces keep the later validation: their post
  materialization may have awaited decryption.

The existing previous/merged acceptance checks, retention cuts, chain/fork
handling, signature checks and Space behavior remain. There is no change to
native code, media adaptation, mailbox policy or relay scheduling.

## Compiled checks

The new regression failed before correction: a fresh row caused 56 historical
signature checks against 48 for an otherwise empty delta. It now causes no
extra historical deduplication scan. The same fixture checks identical replay
and preserves two distinct signed digests at one author/sequence slot, including
after another replay. Fake-signature fixtures test application behavior, not
native cryptographic strength.

The final serial run passed **484 tests**, with three existing skips, covering
group ingest, durable delivery, outbox, device sync, content, calls and
disappearing messages. Static analysis reported no issues. An initial parallel
run timed out in the audio-watchdog test during concurrent builds; that case
passed in isolation and the entire serial run passed. No watchdog code changed.

## Diagnostic stage runs

A is Android on Wi-Fi and B is macOS, both identity X; C is another macOS
instance, identity Y. Profiles and identities were retained. The same frozen
Veil `1d36980d`, media libraries and hidden-volume artifact were used. There were
no native test hooks, reduced identity difficulty, forced routes or Rust builds.

Both debug-Dart phases sent six spaced C-to-X messages after a fixed 30-second
warm-up. All messages converged with identical new IDs and no duplicates.
In candidate window 4, incoming-row processing took 4.0 ms and reaction-target
preparation 1.8 ms, against 168.0 and 590.9 ms in baseline window 4. The two
necessary accepted-history passes still took about 0.67 and 0.65 seconds in that
candidate window. Overall merge and delivery also include storage and background
work; those profiles advanced between phases. No controlled end-to-end speedup
ratio is claimed. Full window counts, including windows with no completed merge,
are in [summary.json](summary.json).

## AOT/profile check

Debug-Dart performance must not be treated as release performance. The final
Android QA app was built in **profile/AOT** mode with the existing authenticated
debug API explicitly opted in. Its APK contained `libapp.so` and no kernel blob.
Its Veil, media and hidden-volume native artifacts matched the debug QA artifacts.
Both Mac instances remained debug builds. This mixed stand qualifies the stated
flows; it is not a release-mode benchmark of all platforms or an isolated
comparison of the code change alone.

The uninstrumented pass checked three C-to-X messages and three A-to-C messages,
including outgoing copies on online B. All six converged without duplicates.
The complete visible conversation contained **502 rows on each device**, with
identical ID sets and visible order. First observation on A for C-to-X took
7,248–14,871 ms. Submitting on A took 3,833–4,176 ms; its outgoing copy first
appeared on B after 6,725–11,783 ms. Polling used the debug message API and read
the complete conversation, so these observations include observer overhead and
are not pure network latency. File bytes and other state dimensions were not
compared.

C then initiated a video call to X. A/B rang after 718/1,068 ms. A answered;
B stopped ringing, and connection became active after 3,601 ms. Across 40
samples over 89.1 seconds, A and C stayed active on P2P with cameras on and
increasing audio counters. After the first 30 seconds of sampling, received FPS
was 20.2–26.7 on A (median 25.1) and 17.5–25.9 on C (median 23.9), with no
zero-FPS sample in that interval. Native audio-delay peaks were 73/80 ms;
these are not end-to-end speech-delay measurements. Neither endpoint reported
a stalled worker. Live speech intelligibility, headphone volume, and time from
initial call placement to stable video quality were not assessed.

## Cleanup and remaining scope

All started apps were closed after each phase. The final audit checked seven
recorded process groups and both owned Mac executable paths, found zero app
processes, verified restored Android permissions, and confirmed removal of the
owned ADB forward. The final normal builds lacked the private timer strings,
and its endpoint returned 404 on every running role. Main app data and system
power settings were unchanged. Raw logs, IDs and credentials stay outside the
repository; exported evidence contains allowlisted roles, counts and timings.

Nothing was pushed, released or deployed. Data submission, startup catch-up and
propagation still take seconds. Future phone performance/quality measurements
should use AOT/profile and reduce observer load. Native storage/queue time and
the remaining history work need further investigation. Windows, long offline
cases, files, the full multi-device matrix and the earlier partial chunk-ACK
receiver-crash limit remain outside this qualification.
