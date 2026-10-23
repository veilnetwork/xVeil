# Stale-session recovery without quarantining a replacement — 23 October 2026

SDK correction: **`10b56236`**, parent **`b7745be2`**.

## Evidence that led to the correction

The parent Poco/Mac cellular run failed both 180-second file gates, as recorded
in the [BBR follow-up](../bbr-delivery-2026-10-23/README.md). Examining its longest
sampled local retry episode found:

- **19,167 ms** elapsed in the retry episode, with **722 additional WouldBlock
  results**, no cumulative ACK progress and no advance in the reserved send
  sequence. No complete retry recovery was recorded in that interval. Partial
  handoffs cannot be ruled out from these counters alone; the duration is not
  a per-frame queue age or network latency.
- A route was invalidated after its first-hop session generation changed while
  the peer already had a **live replacement session**. The old handler imposed
  a **60-second** cooldown on both the rendezvous and first hop.
- Three subsequent open failures in that interval explicitly reported a cooled
  first hop. A later candidate failed confirmation after about ten seconds.
  The latter is a separate unresolved path failure, not proved to be caused by
  this cooldown bug.

The unnecessary quarantine is directly supported by the live-session stale
event and the subsequent cooled-hop refusals. The record does not prove that a
ready replacement circuit had already been published during that exact event;
that additional deletion race is reproduced below.

## Reproduction and change

The parent regression retains an obsolete generation on a circuit handle while
the real session TX registry has a live outbox. A new circuit through the same
first hop/rendezvous is already published and carries another live stream.
Calling stale-handle cleanup deletes that replacement, evicts the other
stream's Bulk/ACK pins and quarantines the recovered hop. The parent test fails
with `late stale handle removed the ready replacement at the same R`.

Cleanup now removes the observed obsolete circuit and other circuits/pins on
the affected first hop whose session is dead or captured generation is no
longer current. It preserves current replacements, their stream accounting and
receiver bindings. Pool and pin mutation use the existing pool → pins lock
order; retired circuits retain the existing grace policy, with shared handles
deduplicated. A late notification that removes nothing adds no retire timer.

Stale-generation evidence no longer creates a rendezvous/first-hop cooldown.
Existing send-failure/no-progress cooldowns are neither cleared nor changed.
Dead sessions and generation mismatches remain ineligible for selection. The
existing bounded background refresh restores missing paths; its admission,
retry cadence and concurrency are unchanged.

## Checks

- The parent-failing positive case now preserves the replacement and both pins
  for the other stream, closes the obsolete stream's admission count, and
  actually hands off its retained DATA on the ready replacement's outbox.
- Three negative cases retain exact preexisting rendezvous/hop cooldown
  deadlines, or leave a dead hop ineligible. Each keeps the unaccepted DATA
  queued and admits none to the recoverable lane.
- All **68 anonymous-stream client tests** pass, including existing cookie/key
  receiver-isolation, ACK-copy recovery, active-stream limits, confirmed cooldown
  recovery, sparse-RTO health and real-engine media/file coexistence checks.
- Client Clippy with embedded-node/test features, library and test targets,
  warnings denied, and workspace rustfmt checks pass.

These fixtures use actual runtime services, DataCircuit handles and outboxes.
The old handle's differing generation is deliberately set in the fixture;
this is not a real QUIC reconnect or a physical throughput benchmark.

Production macOS and Android builds pass. Frozen source hashes match the clean
`10b56236` SDK worktree; each library retains exactly the same **199 C export
names**. Compatible QA frontends are unchanged, without native media test hooks
or a PCM probe.

## Physical Poco/Mac run on the corrected SDK

Both endpoints loaded `10b56236`, verified by source hashes, installed APK hash
and the Mac's loaded library path. The phone was awake in the existing owned QA
profile. Wi-Fi remained off and cellular remained its active default transport.
Own-contact P2P was denied; recorded file opens were anonymous. No call or
physical audio device was opened.

| Phone → Mac | Result, 180-second limit |
| --- | --- |
| 32 MiB | **Failed**; last observed sink **4,194,304 bytes (4 MiB)**. Integrity unverified. |
| Following 4 MiB | **Passed in 40.282 seconds**, SHA-256 matched. |

Each file used one pull request, with no retained setup/manifest-first-byte,
manifest EOF, payload-read idle or source payload-write idle failure. The large
file's final reset/failure is the explicit harness cancellation. Including
fixture/offer setup, durations were **182.002 / 40.997 seconds**. Messages arrived
once in **1.610 / 1.041 seconds** (Mac → phone / phone → Mac); preexisting contact
state means this does not qualify a fresh invitation exchange.

No stale-session event with an already live replacement was recorded on either
endpoint. One stale event with a dead session was recorded on the Mac across
the owned runtime, retired without the old cooldown message. This does not
physically qualify the specific live-replacement case or prove a speedup: the
routes and network were uncontrolled, and the target event did not recur.

Whole-runtime driver retry episodes reached **4077 / 1100 ms** (Mac / phone).
These include retained-frame/partial-handoff effects and must not be described
as one frame's wait or network latency. Separate phone session-queue samples
reached **451 ms** for capacity and **205 ms** for child unavailability. Native
whole-runtime route counters can include cleanup; they are retained numerically
without attributing every event to a particular file. The failed large-file
gate remains open.

Both own-contact policies and the diagnostic property were restored. Independent
checks verified the original Poco APK's exact hash, owned Mac/phone apps and
capture absent, Wi-Fi still off, mobile data still on and user-profile selection
unchanged before APK restoration. The installed Mac app was untouched.
No push, release or relay update was performed.

## Limits

The change addresses a reproduced recovery defect, not every file stall.
Confirmation timeouts, local admission, payload-idle failures, call/audio/video,
Windows reports, Android background behavior and the full multi-device matrix
remain open. No relay priority, wire field, queue budget or timeout was changed.
Private logs, node/stream identifiers, addresses, keys, content and paths are
excluded; committed evidence is numeric/boolean and source commit references.
