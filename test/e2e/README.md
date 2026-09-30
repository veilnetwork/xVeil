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

### Environment gates

| Variable | What it must be |
| --- | --- |
| `XVEIL_E2E_VEIL_CLI` | absolute path to a prebuilt `veil-cli` |
| `VEIL_FFI_DYLIB` | absolute path to `libveilclient_ffi` |
| `HIDDEN_VOLUME_FFI_DYLIB` | absolute path to `libhidden_volume_ffi` |

All three must be absolute and must exist; a path that is neither is treated as
unset, because an env override that turns out to be stale otherwise fails much
later as "the node never came up", which is the one thing it does not mean.

With any of them unset the whole suite **skips cleanly** with a message naming
what is missing — an ordinary `flutter test` stays green. The one file that
always runs is `convergence_oracle_test.dart`; see below for why.

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
| `fixtures/*.toml` | test-only, committed node identities (see "Why identities are committed") |

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
3. **no gaps** — each writer's `seq` chain is contiguous, checked **per writer**
   (the flat frontier that collapsed several writers into one is what `9cbe6a4`
   had to fix).

2 and 3 are checked per device rather than between them, because two devices
that are identically broken are not a converged pair.

---

## The cases

### case 3/8 — a stranger writes to an identity with two devices up

C sends to identity X while A and B are both running. The message must appear on
A **and** on B, **exactly once each**, and the pair must agree.

Proves: the identity address resolves, the multi-device mirror carries the row to
the sibling, and no row lands twice. "It arrived" and "it arrived once" are
different claims and the second is the one this project has had to fix — a row
keyed by `msgId ?? contentId` used to land twice under two keys.

### case 10 — strict offline probe beyond the current guarantee

B is down; A sends to C; then A **and** C go down and B comes up. The probe
asks whether B can recover its own outgoing message without a live source.
The accepted architecture does not promise that recovery, so a red result is
recorded as a design limitation rather than a product defect.

With A gone there is no live sibling to ask. The test first confirms that C
received the message and A committed its device-group mirror, then takes A and
C down. Current policy skips mailbox deposits to sibling device addresses, so
the case measures whether any other recovery path can supply B.

### case 20 — an edit and a device-local delete on one identity

A edits a row while B calls `deleteMessageLocally` for the same id, with neither
able to see the other, then both come back. The case asserts two things:

* **what must hold regardless of the rule** — the signed device-group log does
  not fork, duplicate a row, or leave a hole in a writer's chain;
* **what the rule currently is** — pinned, after reading the code rather than
  guessing:
  * `deleteMessageLocally` writes a permanent tombstone, and
    `MessagingDeviceMirror.applyMessage` refuses any mirror carrying an id that
    is tombstoned here (the resurrection invariant in
    `doc/MESSAGE-EDIT-DELETE-DESIGN.md`), so the deleting device never gets the
    row back;
  * the mirror emits on `onMessageStored` and drops an id the receiver already
    holds, so an edited body is not carried to a sibling that already has the row.

  Both point the same way, so the settled state is deterministic: **A keeps the
  edited row, B keeps nothing.** This is permitted because B explicitly made a
  device-local deletion. A delete-for-everyone conflict and a truly simultaneous
  network partition require separate tests.

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
* Nothing is synchronised by sleeping where a condition can be polled. The one
  wait that is not a condition — case 20's "the pair has stopped changing" —
  polls for stability rather than for a fixed delay, because there is no event
  to wait for when the correct outcome is that nothing more happens.
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

See [the dated campaign report](../../doc/MULTIDEVICE-VERIFICATION-2026-09-30.md)
for the exact online/offline setup, observed result and open failures of each
case. The report supersedes earlier runs of this harness; the oracle now
recognizes separate signing chains for devices of one identity.

---

## Known limits, and what comes next

The current cases cover online text, offline catch-up with A available, initial
history, one file, basic calls, and two failure probes. Remaining cases need:

* **cases 44–46 (two multi-device identities exchanging).** The fixture already
  provisions four devices and two identities (A+B = X, C+D = Y), and
  `E2eFleet.start(labels: [...])` takes all four. What is missing is only the
  second link ceremony plus the four-way oracle sweep: link D into C, then
  assert both pairs converge and the cross-identity conversation is identical on
  all four. No new fixture machinery.
* **cases 15/16 (hundreds of messages, interrupted sync).** Needs (a) a bulk
  send helper that does not await each `sendText` round trip, and (b) a
  convergence wait keyed on ROW COUNT rather than on one body — the oracle
  already reports counts, gaps and duplicates, which is exactly the shape those
  cases assert. It will also need a longer per-test timeout and probably a
  `retentionCuts`-aware relaxation of the gap rule once compaction enters the
  picture, since a compacted prefix is a legitimate hole.
* **cases 33–36 (files).** The case 7 assertion reads B's actual bytes, but the
  oracle does not yet include a content digest. Offline seeding, interrupted
  transfers and large files remain open.
* **Not covered here**: device revocation and tombstones, physical audio output,
  and anything needing a phone. Basic call signaling runs in this fixture.
