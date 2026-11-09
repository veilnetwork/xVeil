# `test/e2e` — the multi-device harness

An end-to-end harness for the multi-device checklist, so that multi-device
behaviour stops depending on one person driving a manual stand.

Everything here runs against the **real stack**: the real `veilclient-ffi`
dylib, real embedded veil nodes, real deniable containers, a real local relay
island of `veil-cli` processes, and the app's own Riverpod providers. Nothing
substitutes a signer, a transport or a fold. This project has repeatedly had
unit suites go green while the live node was dead; the whole point of this
subtree is to be the suite that cannot.

---

## Running it

```bash
export XVEIL_E2E_VEIL_CLI="$PWD/third_party/veil/target/debug/veil-cli"
export VEIL_FFI_DYLIB="$PWD/third_party/veil/target/debug/libveilclient_ffi.dylib"
export HIDDEN_VOLUME_FFI_DYLIB="$PWD/third_party/hidden-volume/target/debug/libhidden_volume_ffi.dylib"
export XVEIL_HV_DYLIB="$HIDDEN_VOLUME_FFI_DYLIB"
# Required for connected calls; use a real engine built for this SDK.
export VEIL_MEDIA_DYLIB="/absolute/path/to/libveil_media.dylib"
export TMPDIR=/private/tmp/

flutter test test/e2e/                          # everything
flutter test test/e2e/relay_cluster_test.dart   # just the island
flutter test test/e2e/device_fixture_test.dart  # just the app stacks
flutter test test/e2e/multi_device_e2e_test.dart --plain-name "case 3/8"
```

Build the binaries first — the suite never builds anything itself:

```bash
scripts/build-native.sh --no-compiled-in-seeds  # debug: both FFI libraries + veil-cli
```

**`veil-cli` and `libveilclient_ffi` must come from the SAME build.** They talk
to each other over the wire, and a mismatched pair fails as
`VeilAbiContractMismatch` at best and as "the island never converged" at worst.
`scripts/build-native.sh` builds both from the same tree in one go, which is why
it is the recommended path rather than two `cargo build`s.

The anonymous-call startup fixture also supports a long first call:

```bash
XVEIL_E2E_ANONYMOUS=1 XVEIL_E2E_CALL_HOLD_SECONDS=660 \
  flutter test --no-pub test/e2e/onion_call_startup_process_e2e_test.dart
```

`XVEIL_E2E_CALL_HOLD_SECONDS` accepts 5–720 seconds (default 5). Both endpoints
must continue receiving audio RTP in every five-second observation window.
The second call, after the primary device stops, retains its short hold. This
checks packet continuity and call lifecycle, not speech quality or loudness.

Set `XVEIL_E2E_CALL_FILE_BYTES=3145979` to additionally send a fresh 3 MiB plus
251-byte file from C to the answerer after that hold. Valid sizes are 3–16 MiB;
0 disables the transfer. The call stays active until the reliable anonymous
stream finishes and the received bytes pass SHA-256 verification. Both contacts'
P2P overrides are temporarily denied and restored before hangup. Audio reception
is also observed while the download runs. The fixture owns this transfer and
cancels it on failure before disposing the devices.
Completion has a size-dependent bound (90 seconds plus one second per 4 KiB),
because endpoint DATA pacing during a call can be as low as 5 KiB/s before wire
overhead. Separately, two minutes without another verified piece write fails
the test. This distinguishes slow progress from a stalled stream; it does not
qualify file throughput. For private diagnostics, opt into
`XVEIL_E2E_BULK_STREAM_TRACE=1`; raw endpoint logs are not anonymous reports.

### Environment gates

| Variable | What it must be |
| --- | --- |
| `XVEIL_E2E_VEIL_CLI` | absolute path to a prebuilt `veil-cli` |
| `VEIL_FFI_DYLIB` | absolute path to `libveilclient_ffi` |
| `HIDDEN_VOLUME_FFI_DYLIB` | absolute path to `libhidden_volume_ffi` |
| `VEIL_MEDIA_DYLIB` | absolute path to the real media engine; connected-call cases skip without it |

The three base gates must be absolute and must exist; a path that is neither is treated as
unset, because an env override that turns out to be stale otherwise fails much
later as "the node never came up", which is the one thing it does not mean.

With any base gate unset the native cases **skip** with a message naming
what is missing. A skipped test is not coverage. Connected calls additionally
require the media gate. The oracle and deadline tests always run.

It runs nightly anyway, in `.github/workflows/nightly.yml`, on a Linux runner with
the libraries built from the same tree the way the section above says to build
them. Everything here except case 10 runs, and `mailbox_carriers_live_test` runs
without gating the result: it is the one case that leaves the island, so a red
there can mean somebody else's relay rather than this code. Case 10 is excluded by
name because it probes a stronger offline guarantee than the accepted architecture
provides. Nothing here has ever run on Linux before that workflow, so the timings
below are this machine's, not the runner's.

Optional knobs:

| Variable | Effect |
| --- | --- |
| `XVEIL_E2E_QUIET=1` | silence the harness's progress lines |
| `XVEIL_E2E_RUST_LOG` | `RUST_LOG` for the relay processes (default `info,veil_node_runtime=debug,veil_mailbox=debug`) |

### Crash before applying overlapping history replies

`multi_source_history_process_e2e_test.dart` normally holds the first history
apply until two sibling sources have delivered complete authenticated replies.
With `XVEIL_E2E_HISTORY_OVERLAP_CRASH_BEFORE_APPLY=1`, it instead kills the
receiver at that barrier. Both sources stop before the receiver restarts.
The container is inspected before networking starts, then only one source
returns. All 512 archived rows and the receiver's existing history must
converge by exact ID, body, delivery state, canonical positions and order.
A final receiver restart with every source offline checks durable retention.

Besides the base native gates, this fixture requires
`XVEIL_E2E_HISTORY_OVERLAP=1`, `XVEIL_E2E_STORAGE_TIMING=1`,
`XVEIL_E2E_HISTORY_WIRE_TRACE=1` and an existing private
`XVEIL_E2E_EVIDENCE_DIR`. Evidence includes synthetic identifiers and content
witnesses; it is private stand data, not an anonymous diagnostic export.
This scenario does not enable a sibling mailbox or qualify long offline,
every crash stage, or mobile network handover.

`XVEIL_E2E_HISTORY_OVERLAP_ROWS` selects an archive size between 32 and 3000
rows (default 512). Use 2000 to profile large-history reception; both native
sources must contain the entire selected archive and the full oracle still
checks every row. The worker enforces the same bounds before seeding storage.

With storage timing enabled, the overlap controller requests the census and
starts opt-in CPU/timeline capture. It resets the receiver window immediately
before releasing apply. `XVEIL_E2E_CONTACT_READ_FRONTIER=0` disables only the
test adapter's optional queue witness for an unshared-read control; the app's
authorization checks and native request order stay the same.

---

## What is in here

| File | What it is |
| --- | --- |
| `e2e_env.dart` | the gate, `waitUntil`/`waitFor` (deadline **and** diagnostic), free ports, `teardownLegs`, the `/tmp` temp root |
| `relay_cluster.dart` | spawns, peers, waits on and tears down a sealed local island of `veil-cli` relays |
| `device_fixture.dart` | app-level devices (container + embedded node + real providers) and the device-link ceremony |
| `convergence_oracle.dart` | the pure oracle: two device readings in, a verdict out |
| `convergence_oracle_test.dart` | **ungated** — the oracle's own break-check |
| `relay_cluster_test.dart` | smoke test for the island alone |
| `device_fixture_test.dart` | smoke test for the app stacks and the link ceremony alone |
| `multi_device_e2e_test.dart` | the checklist cases |
| `multi_device_extended_e2e_test.dart` | concurrent writers, interrupted backlog, message state, media, call races, groups and revocation probes |
| `device_process_fixture.dart` / `device_process_worker_test.dart` | a separate OS process and authenticated debug API per device |
| `multi_device_process_e2e_test.dart` | independent history, B→C authentication, reconnect, stale-device revoke, call race and abrupt crash probes |
| `multi_device_partition_e2e_test.dart` | four independent live devices, two transport partitions, concurrent messages/edit/delete/reactions/read state, then ordered convergence without a restart; optional global deletion and offline receiver restart |
| `expired_mirror_process_e2e_test.dart` | real thirty-second TTL with B offline; source journal bodies are retired, A restarts and sends a fresh message to B/C; expired copies stay absent from the conversation and journal after B cold-restarts with A/C stopped |
| `expiry_outbox_process_e2e_test.dart` | proves queued snapshots contain expiring bodies mixed with retained state; observes automatic rewriting, reads stopped A's raw native Outbox before any application cleanup, then checks reconnect/fresh delivery and cold B retention |
| `expired_edit_process_e2e_test.dart` | keeps C offline while a real edit expires; checks automatic replacement, stopped raw native roots, first cold C read before the old TTL timer, durable void ACK and fresh delivery |
| `pending_mutation_convergence_e2e_test.dart` | three native app stacks; a controlled peer unsend arrives before its post, then an offline sibling recovers the deletion without that peer and retains it after restart |
| `e2e_env_test.dart` | unresponsive probes/diagnostics cannot disable the wait deadline |
| `fixtures/*.toml` | test-only, committed node identities (see "Why identities are committed") |

The partition test uses local deletion by default. With the usual native gate
variables configured, set `XVEIL_E2E_PARTITION_DELETE_EVERYONE=1` to test a
concurrent edit versus **delete for everyone**. It first requires the edit in
A/C and the deletion in B/D while the halves are still isolated. After healing,
all four must agree that the target is absent. It then stops A/C/D and restarts
B, checking retained ordered history, deletion, reactions and read position.
The no-restart assertion applies to the live partition and its merge; the
additional cold restart happens only after stable convergence was verified.

Set `XVEIL_E2E_PARTITION_AUTOMATIC_HEAL=1` to heal with admin unban alone,
without calling `/add_peer` again for known siblings. This separately checks
native reconnect/discovery and application anti-entropy without a join kick.
Reaction comparisons reject unknown actors and duplicate raw slots belonging
to one logical identity; identical wrong extra actors on all replicas are not
accepted as convergence.

The two smoke files exist so that failures separate. "The relays never came up",
"the app stack never booted", "the two devices never linked" and "the state did
not converge" are four different problems that a case reports identically. When
the smoke files are green and a case is red, the harness is not the suspect.

---

## The oracle, and why its test is not gated

Every case ends by calling `convergenceOf(a, b)`. An oracle that answers
"converged" to everything therefore turns the entire gated suite green without a
single defect being caught, and nothing downstream notices. So the oracle:

* imports nothing from `lib/` — it takes plain readings and returns a verdict,
  which is what lets its test run under a plain `flutter test` with no dylib, no
  relay and no container;
* has a test that feeds it one deliberately-wrong pair per failure mode and
  demands a specific reason, not merely `agree == false`.

**"Agree" means**, per the campaign's own criterion:

1. the **device-group bundle digest** matches. The digest covers the signed,
   shared rows — control entries and messages — and deliberately excludes the
   per-device local fold state (`localEpochKeys`, the `*Receipts` maps,
   `retentionCuts`), which the design says diverges by construction: an envelope
   is minted per recipient and a receipt records the LOCAL moment a row arrived.
   An oracle that hashed those would call every healthy pair divergent;
2. **no duplicates** — one `(author, seq)` per chain, per device;
3. **no numeric gaps for contiguous logs** — checked per signing writer for
   append-only rows. Sovereign device messages are compactable LWW state, not
   a contiguous history: author counters can advance on another device, and
   superseded rows may disappear. Production explicitly writes no hash chain
   for these state rows. The fixture obtains this distinction from the trusted
   manifest; duplicate checks and control-chain gap checks always remain.
4. **expected conversation data** — scenarios may pass the complete expected
   message-ID list, checked throughout convergence. Cases 3/8 and 20 do so;
   both devices losing the same expected message, duplicates, or unexpected
   rows still fail, including when their state-log digests are identical.

These checks run per device as well as between devices. A sparse state-log
snapshot alone cannot prove completeness of unseen historical events; the case
must name the expected logical data. Numeric density is not a substitute for
that expectation and must not diagnose legitimate state rows as lost messages.

---

## The cases

### case 3/8 — a stranger writes to an identity with two devices up

C sends to identity X while A and B are both running. The message must appear on
A **and** on B, **exactly once each**, and the pair must agree.

Proves: the identity address resolves, the multi-device mirror carries the row to
the sibling, and no row lands twice. "It arrived" and "it arrived once" are
different claims and the second is the one this project has had to fix — a row
keyed by `msgId ?? contentId` used to land twice under two keys.

### case 10 — no-source limit, followed by recovery

B is down; A sends to C; then A **and** C go down and B comes up. The probe
asks whether B can recover its own outgoing message without a live source.
The accepted architecture does not promise that recovery. The test asserts
absence throughout three minutes with B alone, then brings A back and requires
the same outgoing message to arrive exactly once. This tests the agreed limit
and eventual recovery without introducing a device mailbox.

With A gone there is no live sibling to ask. The test first confirms that C
received the message and A committed its device-group mirror, then takes A and
C down. Current policy skips mailbox deposits to sibling device addresses, so
the case measures whether any other recovery path can supply B.

### Extended checklist

`multi_device_extended_e2e_test.dart` exercises concurrent writers, a backlog
of 100 messages, interrupted catch-up, read markers in both directions,
reactions and their removal, edits/replies/pins, contact preferences/blocking,
PNG and 4 MiB file persistence, call decline/reconnect/answer races, pre-link
group history, offline revocation/relink refusal and a third device E of X.
The 4/9 case in the core file includes five real minutes with B offline.

These are app/provider and native-node tests on one host. The native document
registry is process-global: shared-process results must not be cited as proof
of cross-process revocation propagation or rejection of stolen keys. Long
offline periods, real network partitions, OS crashes and host clock skew need
separate runs. A failed or unexecuted subcase is not covered by another subcase
sharing its checklist number.

### case 20 — an edit and a sibling deletion on one identity

A edits a row while B calls `deleteMessageLocally` for the same id, with neither
able to see the other. B publishes a `msgGone` event to the signed device log.
After A reconnects, both devices must apply that event and omit the row. The
test checks the shared log and the visible conversation, including a restart of
A so the folded journal replay is exercised. A delete-for-everyone conflict and
a truly simultaneous network partition require separate tests.

### case 29 variant — cold C sends before a new application message from A

The process suite also runs `offline C sends before post-revoke master message`.
It primes B→C and C→A/B, stops B and C, and revokes B on A. After both processes
restart, C sends to X without a manual post-revoke A/C join or application
message from A. The message must reach A and remain absent on old B. A watcher
starts before that send and checks old B and C with 500-ms pauses between
rounds, including 60 seconds after old B attempts a new message. C must reject
that attempt. An A→C positive
control follows the observation window.

```bash
TMPDIR=/private/tmp/ flutter test --no-pub \
  test/e2e/multi_device_process_e2e_test.dart \
  --plain-name 'offline C sends before post-revoke master message'
```

This is a process-restart case with C's saved contact and P2P policy. Normal
native document propagation/resolution is allowed. It does not freeze a running
node's certificate cache during a network partition, inspect every ciphertext
recipient, or qualify calls from revoked B.

### case 29 variant — C remains alive with warm caches during isolation

`warm C survives a transport partition during revoke` primes B→C and C→A/B,
then uses the existing native `peers ban` administration commands on the owned
workers and all three local relays. Both directions are blocked, including
previous direct A/C and B/C links. C must report zero native sessions before
and after A revokes offline B, while its worker PID remains unchanged and its
local document is still stale. No host firewall or public relay is modified.

After unbanning the island, C sends first and old B attempts messages. Local
admin DHT reads observe when C learns A's current signed document; they do not
force a lookup or inject it. The test distinguishes traffic accepted before
that knowledge from a cache bypass afterwards. If needed, B keeps attempting
every five seconds for up to two minutes. After the current-document barrier,
C sends another marked message to A and B attempts another to C. For at least
60 seconds the former must remain absent from B and the latter absent from C.
A→C is a final positive control.

```bash
TMPDIR=/private/tmp/ flutter test --no-pub \
  test/e2e/multi_device_process_e2e_test.dart \
  --plain-name 'warm C survives a transport partition during revoke'
```

This is a protocol-level isolation test using the existing Unix admin sockets,
with independent native processes and retained in-memory caches. It does not
assert instantaneous global revocation, audit ciphertext recipients, simulate
every physical network failure, or qualify revoked calls.

### case 37 — B answers without a B-C session

C calls identity X and both A and B ring. The fixture verifies that B has no
direct session to C before answering. B sends its answer to the physical return
address in C's offer, while the call id gates the relayed answer at C. A stops
ringing, C connects to B, both directions receive sealed media packets, and C
receives B's hangup. The test runs against the ordinary native library and
does not pre-pair B with C.

---

## How the harness is put together

### The relay island

Three `veil-cli` processes on loopback, mirroring `scripts/dev-mailbox-onion.sh`
(the proven local arrangement):

* `mailbox` — hosts the mailbox and is receive-anonymous, so it can also be a
  rendezvous target;
* `mid1`, `mid2` — `relay_capable`. **Two**, because `select_onion_relay_path`
  forces `hop_count >= 2` and excludes the rendezvous relay from the middle-hop
  pool. One relay is not a smaller island, it is an island where no circuit can
  be built.

All three are pairwise peered and every one of them is written with
`builtin_seed_policy = "never"` and `meeting_points = "off"`, which
`RelayCluster.assertSealed()` re-reads off the config **file** before the suite
proceeds. The app devices also disable bundled seeds and meeting points. These
checks keep the island on its configured loopback peers instead of discovering
nodes on another network.

`--features allow-empty-seeds` builds without a seed list. It does not disable
meeting-point discovery by itself; the explicit `meeting_points = "off"` and
`builtin_seed_policy = "never"` settings seal the relay config. A stock binary
logs `builtin seeds refused (policy=never)` when it rejects that list.

### The devices

Each device is a deniable container + a real embedded node
(`RealVeilStack.startDeniable`, FFI — not a spawned `veil-cli`) + a real
`ProviderContainer` reading this project's own providers.

It is a `ProviderContainer` and **not** a `HeadlessRuntime` for one specific
reason: the daemon composes a genuinely real stack, but the multi-device mirror
(`msgMirror` emit + apply) and the device-sync bridge are wired in
`lib/state/group_service_providers.dart`, inside `groupServiceProvider`, and
nowhere else. A harness built on `HeadlessRuntime` would bring up two real nodes
that never mirror anything to each other — and a mirror hand-written in the
harness to make up for it would go green while the app's own mirror was broken.

There is exactly **one seam**: `_E2eAppController` replaces
`AppController.build()` so the session starts "already unlocked as this
identity" instead of running the onboarding/preferences boot. It stands in for
the USER, not for any mechanism — the fixture opens the container and starts the
node itself, and every provider downstream is the real one.

The device-link ceremony in `E2eFleet.linkDevice` is a faithful transcription of
the stand's three hooks in `lib/debug/soak_hook.dart`
(`_deviceLinkPrepareHook` → `_deviceAdoptPrepareHook` → `_deviceSnapshotSendHook`),
including the fail-closed document check and the retro-delegation pass. Those
hooks are the source of truth; when they change, this changes. Every step is the
same public service call the hook makes.

### Why identities are committed

veil's anti-sybil PoW is the canonical difficulty (24 leading zero bits) and the
node **refuses to start** below it — `config init -d 8` produces a config that
fails validation with `identity.nonce: must produce at least 24 leading zero
bits`. Minting costs ~45 s and ~12 CPU-minutes per relay identity through
`veil-cli`, and ~5 minutes per device identity through the FFI. Seven of them
would be twenty minutes of mining before the first assertion.

So `fixtures/*.toml` holds them, exactly like
`test/native/fixtures/public_discovery_identity_*.toml` already does. They are
test-only keys, deliberately public, and must never be used off a loopback
island. A missing fixture is minted and cached on the spot, with a loud log line.

The two master phrases are committed as constants in `device_fixture.dart` for
the same reason: device A's node key is DERIVED from identity X's phrase, so a
random phrase per run would re-mine every time and never match the cache.

This also keeps the suite away from the stand's worst trap: minting fresh
identities from one host over and over is exactly what the anti-abuse ladder is
for, and it escalates.

### Waiting, and failing

* Every wait has a **deadline and a diagnostic**. `waitUntil` takes what it is
  waiting FOR and a callback describing what it last SAW, and puts both into the
  failure — plus a progress line every 15 s, because a live case takes minutes
  and silence is indistinguishable from a hang.
* Nothing is synchronised by sleeping where a condition can be polled. Case 20
  waits for A and B to remove the row after the device log converges.
* Teardown runs **every leg** and then rethrows the first failure
  (`teardownLegs`). A leaked `veil-cli`, a live node runtime or a held container
  lock poisons every later run, and the next run then fails for a reason that
  has nothing to do with its own code. `E2eFleet.start` tears itself down on a
  half-built fleet for the same reason: a throw out of `start` never reaches the
  caller's `addTearDown`.
* A device that has been taken DOWN gets a zone that swallows its own late
  async errors (`_BootScope`). `groupServiceProvider` starts maintenance passes
  with `unawaited`, and one already in flight when the container closes throws
  "storage is locked" into whatever test is running. While a boot is alive every
  error is forwarded untouched.

---

## What a run costs (measured on this machine)

| Step | Time |
| --- | --- |
| relay island up (3 nodes, cached identities) | ~1.5 s |
| one device boot (container + embedded node + providers) | ~1–3 s |
| device-link ceremony A→B, including B adopting the group | ~40–50 s |
| contact handshake between two identities | seconds, with the direct-dial hint below |
| minting one relay identity (`veil-cli`, all cores) | ~45 s |
| minting one device identity (FFI, single-threaded) | ~5 min |

### Why the device invites carry a loopback transport

`RealVeilStack.myInvite` deliberately carries no `t=`: a loopback address in an
invite that leaves the machine is worse than useless, so a node whose only
listener is 127.0.0.1 publishes an identity-only invite and is reached over the
rendezvous by node id. That is right for the product, and on a fresh island it
is slow and wildly variable — the cold onion handshake between two strangers
measured 13 s on one run and had not completed after 91 s on the next, on the
same code.

The fixture keeps the sovereign contact invite identity-only and uses a
separate device invite carrying the loopback address to warm the direct route.
The transport answers with the **device key**; putting its address into the
sovereign identity invite makes the native handshake correctly reject the
connection for a key mismatch. The direct device route leaves consent, the
mirror, mailbox deposits and the fold unchanged.

After admission, the newly linked device reboots under its adopted sovereign
identity. Refreshing the document in a node still running under its throwaway
identity cannot switch that node's identity in place.

The deadlines stay generous anyway, because the mailbox legs still ride the
rendezvous.

Note what the boot-time island gate does and does not buy: `E2eDevice.start`
waits for an ACTIVE peer, so a node that has not dialled the island at all
cannot be mistaken for a slow one. That is a different (and much earlier) fact
than "the onion rendezvous is usable", which has no cheap probe from this side.

---

## Current results

See [the 2026-10-21 report](../../doc/validation/multi-device-2026-10-21/README.md)
and its 63-row ledger for topology, results, partial coverage and open failures.
Earlier campaign passes are not carried into that ledger without a fresh run.

---

## Known limits, and what comes next

The core, extended, process and supplementary suites now include two linked
identities, a 100-message interrupted catch-up, files up to 4 MiB, revoke,
sender SIGKILL, and call answer races. Their existence does not imply they pass:
the current report records failed and unstable cases as well as passing ones.

Remaining coverage includes real network partitions with both sides operating,
hours/days offline, independent OS clock skew, packet-level forced replays,
5–10 devices, very large files and precise 50% transfer interruption, and
crashes at receive/decrypt/DB/ACK or file/link/revoke boundaries. Physical audio
output, speech quality and phone/Windows UI need separate device runs.

`multi_device_supplementary_e2e_test.dart` adds authenticated anonymous-call
compatibility (`E2eFleet.start(anonymous: true)`), mixed A/D availability,
two-identity calls, local attachment-cache eviction, loss of the calling app,
and offline group removal with an epoch/commitment change. The default fleet
remains non-anonymous. Removed peers can retain stale membership metadata;
the group-removal test records that separately from receiving new group data.


### Independent-process qualification

The ordinary fixture has isolated native nodes and stores, but its devices
share the native identity registry and the mocked preferences singleton in one
Flutter process. It cannot certify propagation of device authorization or the
isolation of platform preferences. The process fixture gives A, B and C separate
native caches and storage workers. It still substitutes the unlocked app
controller and does not certify Android/Windows UI or live-speech quality.

Run the process suite with the same binary environment as above:

```bash
TMPDIR=/private/tmp/ flutter test --no-pub \
  test/e2e/multi_device_process_e2e_test.dart --reporter expanded
```

Only the worker is compiled with the authenticated debug hook. Its secret stays
in its temporary runtime directory and is not printed or included in the report.
Set `XVEIL_E2E_EVIDENCE_DIR` to preserve worker logs and owned process IDs before
temporary containers are removed. Graceful shutdown joins the messaging ratchet
flush before closing the native stack and encrypted store. Abrupt-crash cases
instead kill only the worker's recorded process group. After the campaign,
audit owned relay PIDs and worker process groups independently.

The current report is in `doc/validation/multi-device-2026-10-21/`.
Its per-case statuses distinguish passes, failures, accepted architecture
limits, partial coverage and scenarios not executed. A failed earlier step prevents
coverage claims for later assertions in the same test. In particular, passing
one incoming message on three X devices does not certify every three-device
scenario, and a timer-based eventual call settlement does not prove an immediate
single-device answer election.

### Certificate identity linking through the QR screens

On macOS, with the same native binary environment above and a private IPv4
interface, run:

```bash
TMPDIR=/private/tmp/ flutter test --no-pub \
  test/e2e/qr_device_link_ui_e2e_test.dart --reporter expanded
```

This test opens the production source and target device-link sheets. It uses
an XVRC certificate/code for the source identity, decodes the actual painted
QR pixels with macOS Vision, and supplies that result at the camera route's
return boundary. Swift/Xcode command-line tools are required. No camera or
production control endpoint is introduced.

The test operates the confirmation checkbox and recovery-code field, performs
the encrypted LAN exchange, restarts B's actual native node before releasing
the readiness handshake, and checks the snapshot, both visible rosters and
history/message convergence. It also stops B, sends A to C, stops C and restarts
B to verify recovery from A. Encrypted recovery credentials are intentionally
part of the pinned device-group snapshot; a fresh incorrect recovery code
must not open the copied certificate.

Only fixture code supplies the unlocked controller and restart ownership.
The test pumps UI-owned asynchronous work while joining native/storage
shutdown; waiting with the widget clock stopped would hang the stand. Default
process workers retain their existing restart behavior. Every native node is
real, but this UI test's devices share one Flutter process and mocked platform
preferences. Use the independent-process suite for cache/authorization
propagation claims. This does not qualify physical scanning, OS permissions,
Windows 10, Android or the production app controller's complete unlock path.

Optional `XVEIL_E2E_EVIDENCE_DIR` output is private: it can contain the owned
temporary root and a failed QR image. Keep it outside the repository and never
attach it as an anonymous report. Published results must contain only the
bounded stage/pass/cleanup summaries.


### Receiver crash during a large initial migration

`multi_device_backlog_process_e2e_test.dart` has an opt-in crash mode. With the
usual native-library/CLI gates configured, set:

```sh
TMPDIR=/private/tmp/ \
XVEIL_E2E_MIGRATION_ONLY=1 \
XVEIL_E2E_BACKLOG_BASE_ROWS=2000 \
XVEIL_E2E_MIGRATION_CRASH_AFTER_ROWS=1000 \
XVEIL_E2E_STORAGE_POSITIONS=1 \
XVEIL_E2E_EVIDENCE_DIR=/private/tmp/xveil-crash-evidence \
flutter test --no-pub test/e2e/multi_device_backlog_process_e2e_test.dart
```

Create the evidence directory privately before running. The test uses real
A→C sends and checks delivered status before linking B. It sends SIGKILL to
B's owned process group after observing at least the requested partial count,
asserts the negative SIGKILL exit status, and restarts B. A fixture-only probe
reads synthetic backlog rows through an isolated storage owner, closes it, and
only then constructs B's application owner and starts its **network**: a
nonempty incomplete on-disk prefix is required. A missed crash threshold or a
fully completed transfer does not qualify as a successful crash.

The final oracle compares all IDs, order, source positions and delivered
statuses, rejects duplicate snapshots and completed-history retries, then
restarts B without A/C and rechecks its retained state. The count-only boot
probe writes no message IDs, bodies, peer identifiers or keys. It is disabled
without the crash option; no production debug endpoint or callback is added.
This is a process-crash/reconnect check, not a claim to inject a failure at
one exact fsync/ratchet/ACK instruction. Its timing includes restart and boot
inspection work and must not be compared as uninterrupted migration speed.


Add `XVEIL_E2E_MIGRATION_CRASH_SOURCES_OFFLINE=1` to stop A and C immediately
following B's crash, restart B without them, and require an incomplete local
prefix after reconnect. Only A then returns; C remains stopped throughout the
remaining history recovery. This mode requires a positive crash threshold.
The legacy summary field `offlineScenarioExecuted=false` refers to the separate
100-message/five-minute backlog phase; the crash-specific fields describe the
source-offline steps here. Storage census windows belong to their worker boot;
post-crash counters do not include the killed boot's earlier operations.


### Opt-in call diagnostic snapshots in process fixtures

`XVEIL_E2E_DIAGNOSTICS=1` passes the normal `XVEIL_DIAGNOSTICS=true` compile
flag to owned device workers. With `XVEIL_E2E_EVIDENCE_DIR` set, each worker
writes its ordinary allowlisted diagnostic snapshot there on teardown. The
fixture-only `storage-inspect.json` command `callDiagnostics: true` reads the
same snapshot from a live owner; it is not an application API. Neither switch
adds identifiers or payload fields to the diagnostic report.

`call_signaling_reconnect_process_e2e_test.dart` needs the existing Veil/HVS
native environment, `XVEIL_E2E_ANONYMOUS=1`, and this diagnostic switch. It
checks exact-call ringing, a cold sibling, an offline primary, sibling outgoing
calls, and joining a still-ringing call. Ending checks use fresh diagnostic
terminal evidence and the exact durable journal row because the live slot is
cleared immediately. It does not accept media or qualify audible speech.


The call signaling process fixture also checks finished-call restoration on a
cold sibling. Its private `replayFinishedOffer` file command sends an authenticated
on-behalf-of sibling offer for a previously finished logical call, with a fresh
transport frame ID. It uses the existing anonymous send and native authorization;
this is not a production API or a raw ciphertext-replay test. The receiver must
record replay rejection without any transient callState, then accept fresh calls.
