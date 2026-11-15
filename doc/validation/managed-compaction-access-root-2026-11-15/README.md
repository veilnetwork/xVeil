# Hosted hidden compaction through an independent access root

Managed-storage defaults remain **disabled**. This qualifies data maintenance
through the existing all-owner collection, not production activation or a full
network restart. Tests and application runs use synthetic isolated profiles.

## Confirmed failures and changes

| Failure | Confirmation | Result |
|---|---|---|
| An encrypted access-root password was required in the hidden keep-set | Packaged normal UI and three native red cases | Authenticate that exact enumerable root separately; only hidden credentials define the keep-set |
| After hosted-session teardown, the router still pointed at the managed master | Packaged normal UI and four gated native red cases | Select the shared hidden source only after confirmed session/node retirement; retain the master access locator |
| A rejected Run could leave the app in preparation, or return before recovery | Packaged cancellation and gated widget red case | The owned operation joins authorized rejection recovery, including early/synchronous failure |
| Settings completion reads a disposed widget ref | Packaged exception and real-screen widget red case | Do not refresh a replaced settings screen |
| Maintenance recovery activates the first hosted identity | Packaged selected-view observation and controller red case | Restore the prior hosted label only during the authorized maintenance reopen |

Plaintext access does not ask for a fictitious password. Each plaintext owner
still requires explicit approval to update links; opening its access root does
not grant that approval. The encrypted access credential is checked against the
exact authorized root and exported keys before publication, never against an
arbitrary visible identity. Wrong-password and incomplete-owner cases leave the
source unchanged. A hidden child is retained only with its own verified keys.

Unconfirmed teardown cannot grant a raw probe or publication behind a live
source handle. Retiring session/stack ownership blocks admission. A missing
profile-availability witness or uncertain publication without a recovery witness
does not authorize automatic unlock. Route removal waits for the operation and
its recovery; lock/wipe/identity changes revoke that authority. The temporary
hosted selection is not persisted and is cleared on completion. Controls prove
that lock prevents recovery and a later ordinary unlock retains its usual first
identity behavior.

## Application observations

A normal-main macOS QA app created an independent encrypted master with two
hosted children, including a hidden child. The existing profile also contains an
independent hidden space and separate encrypted/plaintext owners. Through the
real settings UI the collection accepted both hidden passwords, independently
authenticated all enumerable owners, required plaintext consent, and published
native compaction. The existing hidden note survived byte-for-byte, including a
cold process restart and access through the repaired master reference.

The final application run also returned to the selected hidden view with its
exact note and no uncaught exceptions in the retained application log. This
qualifies selected-view/data recovery only. The fixed payload-idle or timing of
network traffic is not involved and no performance claim is made.

**Identity oracle correction:** initial comparisons of the reported hidden node
ID were invalid: after that child's native node failed, the debug application
reported its deterministic loopback ID. Those comparisons are explicitly
excluded from cryptographic identity qualification. The cold note comparison
remains valid; matching a demo ID is not evidence of persistence. Initial ID
changes are not classified as data corruption on this evidence.

The application runs expose remaining startup work: one or both hosted nodes
can fail apply-config with address-in-use. A fresh process with a distinct QA
listener base still reproduced a child failure, so the collision is not
attributed simply to another installed app. A ready UI or another child's live
stack does not qualify the failed child's network identity. The earlier four
locked-storage reads during identity creation and one framework build-time
provider-notification exception remain separate unresolved observations; their
absence in the final run does not prove fixes.

## Validation and provenance

- Native collection/controller suite: twelve cases, including managed encrypted
  access, passwordless plaintext access and wrong access-root credential.
- Hosted-source suite: four actual native storage cases covering confirmed and
  unconfirmed retirement during both collection and publication.
- Dialog/settings and hosted-selection controls: nine cases. The real-screen
  red fixture was corrected to retain a replacement Scaffold; its credited red
  reproduces the actual disposed-ref stack, not a missing-Scaffold assertion.
- Final relevant sequential regression run: **185 passed, zero skipped** across
  23 suites, including opted-in native entry tests. Static analysis: no issues.
- Normal-main debug QA bundle rebuilt from exact current build-input manifests,
  with only its isolated bundle metadata changed. No installed user app/profile
  was replaced. The selected native libraries and Dart kernel were verified;
  current SQLite framework reconstruction was independently byte-compared to
  its pinned raw input and actual bundle. An earlier transformed SQLite hash
  did not match and is not claimed as provenance for this build.
- Failed teardown/admission attempts and demo-ID comparisons are not credited
  as successful compactions or network restarts. Complete native data operations
  and cold note readbacks are counted separately from network qualification.
- Owned stand apps were locked and stopped; their launcher exits, processes and
  diagnostic listener closure were checked. No push or release.

## Remaining activation work

Resolve the packaged hosted-node startup failures and identity-edit service
admission observations, then repeat full real-node identity checks. Physical
Android/OEM and complete cross-platform destructive/recovery qualification,
Windows source-directory durability, custom source-name journal binding,
all-target native pin updates, release AOT and default activation remain open.


Follow-up: [hosted diagnostics and status remount](../hosted-node-metrics-2026-11-15/README.md)
resolves the diagnostic-port and framework-notification observations above and
qualifies actual node identities through compaction and cold reopen. The earlier
demo-ID comparisons remain excluded; other listed activation gates remain open.
