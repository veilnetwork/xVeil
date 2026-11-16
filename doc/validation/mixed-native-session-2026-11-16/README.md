# Mixed storage with the ordinary all-online native boot

Status: host qualification, no new product defect or runtime change claimed.
Production managed-storage defaults remain OFF.

## Matrix completed at the controller/storage boundary

The existing native master-routing scenario covered three master protection
modes with one identity online, but only the encrypted master with all identities
online. Its same complete scenario now runs all six combinations:

| Master protection | One active identity | All identities online |
| --- | --- | --- |
| Hidden | Pass | Pass, newly covered |
| Encrypted | Pass | Pass |
| Unencrypted | Pass | Pass, newly covered |

Each case includes hidden, encrypted and plaintext children. It checks exact owner
settings and storage keys, selected-view accounting and forced owned reclamation,
bind/unbind and anonymity edits, roster appends, lock and cold access. It also
checks interrupted child-erasure recovery, refusal on an unknown child file,
capture shutdown and preservation of the master's unrelated setting. Storage,
workers and controller behavior are real; these six cases still use fake nodes.

## Separate actual native-node scenario

The new opt-in `mixed_identity_session_live_test.dart` uses the ordinary
`sessionBuilderProvider`, `MultiIdentitySession` default boot and
`RealVeilStack.startDeniable`. An encrypted master opens three simultaneous child
stores, one of each protection type. Real pre-mined synthetic node configurations
avoid spending the test budget mining fresh keys. Each child independently
declines bundled seeds and meeting points. Explicit loopback QUIC invites form
the local three-node mesh; accepted contacts are provisioned out of band.

The unused pre-session controller is inert and the saved-entry OS port is an
in-memory test adapter. No hosted node, transport, native ratchet or messaging
pipeline is replaced. Positive checks require every hosted stack to have an
actual embedded controller, its exact expected native ID, a ratchet handle and
its own persistence attachment.

The scenario verifies:

1. All six directed contact pairs exchange exact known bodies and actual peer
   delivery acknowledgements.
2. Switching the active identity retains the same session, hosted storage and
   all three stack objects. Both enumerable stores accept forced owned
   reclamation while the other nodes stay online. Another complete exchange
   succeeds while the plaintext identity is the active view.
3. Lock removes the session, reports no abandoned teardown and releases storage
   ownership. Every previous UDP listener accepts an exclusive loopback bind
   with address reuse disabled.
4. Fresh router/controller instances cold-open the original master. All three
   actual IDs and exact message ID/body maps match. Each native ratchet is
   nonempty before a new connection is made; an empty fresh session cannot
   satisfy the restoration check.
5. The new native mesh exchanges a third batch with ACKs. There are exactly six
   messages per contact conversation, twelve rows per identity: eighteen unique
   messages across the three batches, each with both peers' stored copies.
   Final lock again releases all listeners and owners.

This covers ordinary all-online production boot wiring and real crypto/traffic,
which the earlier fake-transport tests could not establish. It complements the
[post-ACK process-death qualification](../native-ratchet-first-root-2026-11-16/README.md);
this scenario itself uses graceful lock and cold reopen, not SIGKILL.

## Evidence and continued execution

The final frozen-source host run passed **10 tests across four serial suites,
zero skips**: one real-native mixed session, all six master combinations, the
existing mixed-ingress case and both master-selection/lock cases. Analysis is
clean. Selected Veil and storage library hashes are unchanged from their earlier
qualified inputs; no Rust build, ABI, dependency pin or native binary changed.

Initial fixture analysis corrected a nonexistent controller class, transport
methods accessed through the wrong interface and an unused import. These are
fixture corrections, not product findings. The live run then passed; the final
run also checked exclusive listener reuse, exact history counts and cleanup of
every admitted owner.

`scripts/test-native.sh` now opts into the real mixed-session test and all six
master cases in a separate serial invocation. The existing native nightly job
already calls that script. This wiring is prepared locally; no GitHub run or
Linux qualification is claimed here. On macOS the runner also fixes `TMPDIR` to
the repository's required private temporary root. The explicit local equivalent is:

```sh
XVEIL_MIXED_NATIVE_LIVE=1 TMPDIR=/private/tmp/ flutter test --no-pub --concurrency=1 \
  test/native/mixed_identity_session_live_test.dart \
  test/native/managed_master_routing_test.dart
```

Both qualified native-library environment overrides must be set first. A normal
run with the live opt-in absent skips that case and is not this qualification.
No GUI is launched or activated. All owned testers/nodes exit and synthetic
profiles are removed after confirmed cleanup. Raw evidence remains private.

## Remaining scope

This is macOS host/controller/native evidence. The real-native case has an
encrypted master and independent synthetic child identities, not paired devices
of one identity. It does not qualify physical Android/OEM, Windows native
all-online traffic, real OS-vault authentication, release AOT, all-target native
packaging or arbitrary network faults. No mailbox behavior or old-version
compatibility policy changes. It makes no space-savings or latency claim.
Packaged custom-source compaction cold readback still needs an agreed GUI slot;
the prepared QA app has not been launched. Remaining activation work is not
waived by this matrix. No push or release.
