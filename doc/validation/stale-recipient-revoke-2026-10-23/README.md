# Cold recipient after device revocation — 23 October 2026

**PASS for the bounded messaging variant below.** No new authorization bypass
was observed. The source fixes already present in the
[report28 follow-up](../report28-2026-10-21/README.md#multi-device) remain in place;
this cycle adds an independent-process regression for a previously unqualified
ordering. It does not mark all revocation or multi-device scenarios complete.

The subsequent [warm-cache isolation run](../warm-recipient-revoke-2026-10-24/README.md)
preserves C's process and adds a bounded native document refresh. Its evidence
is separate from the cold restart measurements below.

## Current-source audit

The untracked 17 October matrix is an older record, not current defect status.
The committed 21 October audit links to subsequent fixes and repeated runs:

- MD21-03 / old MD-07: the public mailbox seal sink explicitly selects the
  recipient audience. Self-addressed encryption includes the current device;
  group epoch sealing uses that primitive without depositing a relay mailbox
  message. Existing pre-link group/history validation is in report28. No new
  group run was performed here.
- MD21-01 / old MD-08 and MD-10: current source revalidates device certificates
  before using cached authorization and does not infer an authenticated identity
  merely from a session's remembered delegation. Prior warm/cold revoke and call
  checks are recorded in report28. The additional test here covers a new cold
  recipient's first marked outbound application message before A sends another.

Native SDK **`50fa7a2f`** and hidden-volume **`c4ba1fa8`** were built from clean
current source. The relay CLI and client library were built together, with no
compiled seed list, then frozen with the current hidden-volume library. All
artifact hashes remained unchanged through the run. Production/native source
was not modified in this cycle.

## Topology and sequence

A/B belong to X; C belongs to Y. Each device runs its production providers,
native node and encrypted container in its own OS process. Three local relay
processes form a sealed loopback island with public test identities; public
seeds and meeting points are disabled. There is no shared in-process native
identity registry between devices.

| Step | Actual result |
| --- | --- |
| Before revoke, B sends to C | C receives exactly one copy: B's actual device could communicate before revocation. |
| Before revoke, C sends to X | Both A and B receive exactly one copy. |
| B and C stop; A signs B's revocation | Native revoke reports the device revoked. |
| B and C restart from their existing containers | B retains the same physical device and identity; C retains its contact P2P override of deny. |
| C sends the first marked post-revoke message to X | A receives exactly one copy. No manual post-revoke A/C join or new application message from A precedes this send. |
| Old B attempts a new message to C | No corresponding message appears in C's observed history. |
| Watcher checks before C's first send and for at least 60 seconds after B's attempt | No observed copy of C's first message on B, and no accepted attack message on C. Rounds are separated by 500 ms, plus bounded API-read time. |
| A sends a later positive control to C | C receives exactly one copy; the first message is still absent from old B's observed history. |

The selected test passed in **156.602 seconds** including startup and teardown.
Dart formatting and analysis pass. See the
[process suite](../../../test/e2e/multi_device_process_e2e_test.dart) and
[running instructions](../../../test/e2e/README.md).

## Limits

- Ordinary native signed-document propagation and resolution remain enabled.
  The test does not claim that C sends before every protocol packet from A.
- C's OS process restarts. A network partition preserving a warm native
  certificate cache requires a separate test.
- Absence from observed message history is not a ciphertext-recipient audit or
  proof that an attacker cannot decrypt any packet. This does not fully qualify
  checklist item 27 or all of item 29.
- The new case does not initiate calls, exercise files, wait hours/days, or prove
  every clock-skew/replay/revoke ordering. It does not assess physical speech,
  video or Windows behavior. The cellular file gates remain failing in the
  [latest transfer report](../bbr-degraded-path-2026-10-23/README.md).

## Cleanup and privacy

All observed owned processes, including relay/worker processes, exited.
An independent check found no live exact-owned process or frozen CLI process;
the temporary fleet containers were removed. Original fixture source files were
unchanged. The phone and installed Mac application were not touched.

Committed evidence contains only booleans, counts, timing and commit references.
Private logs, node/instance identifiers, process IDs, addresses, ports, paths,
keys and message bodies remain excluded. The original untracked October 17
matrix was preserved. Commits are local and unsigned; no push/release/server
update was performed.
