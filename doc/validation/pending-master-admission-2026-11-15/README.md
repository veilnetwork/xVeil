# Unfinished setup cannot enter roster classification or network planning

Managed-storage defaults remain **OFF**. This repairs setup-admission gaps found
while qualifying interrupted creation. It does not implement a missing original
master-creation intent or declare unbound-child recovery complete.

## Reproduced gaps

The ordinary unlock path classified a nonempty roster before inspecting the
pending-master marker. A crash after `saveRoster` but before clearing the marker
therefore exposed an unfinished master to the identity chooser. The shared
profile loader read that marker only when the profile was absent, so an existing
profile could also reach ready state despite unfinished master setup.

Separately, all-online admission checked only the literal master stage `1` in
the legacy opener. Unknown master stages and pending identity-setup stages could
reach network planning; the latter could also persist migrated seed posture.
Binding an existing profile into a healthy master checked the identity marker
but omitted the master marker, admitting an unfinished target into its roster.

These are reproduced code/QA cases, not attribution of a historical user report.

## Changes

- Ordinary authenticated unlock checks pending-master state before reading or
  classifying a roster. The profile loader checks it even when a profile exists.
- Only absent/empty or explicit completed stage `0` permits ordinary master use.
  Unknown nonempty stages retain the recovery boundary. Creation, append and
  existing-target binding use the same predicate before changing their rosters.
- `planIdentityBoots` checks both master and identity setup markers for each
  member before that member's seed/P2P planning. This common path covers legacy
  and managed members as well as direct planner callers, rather than a single
  legacy-open branch. Prior healthy members may already have been planned if a
  later member refuses; no whole-roster transactional planning claim is made.

Unfinished master data is routed to the existing authenticated setup-recovery
boundary. Keys, profiles, marker and roster references remain preserved; there
is no node start, replacement identity minting or automatic clearing of an
unknown marker. A pending master without an authenticated replay intent still
cannot be completed by guessing its original roster. That recovery feature
remains open. The existing explicit identity-setup journal replay stays separate.

## Qualification

A qualified baseline run has four passing existing controls and **eight failing
new controls**: roster/profile master bypass, an unknown-stage all-online boot,
and identity stages `1`, `2` and unknown entering the planner. An independent
native bind reproduction returns true for a target that must be refused.

Native files cover hidden, encrypted and unencrypted storage, each with either
an already published roster or a profile plus an unknown master stage. Correct
password entry parks in recovery with zero fake-node starts; the original keys,
profile/roster, sentinel value and marker read back exactly. The public catalog
encoding does not change. These are real storage/app-controller checks with a
fake network node, not actual remote call/message delivery.

Mixed native routing controls also mark an unbound encrypted target pending,
then attempt binding under hidden, encrypted and plaintext masters, including
all-online hosting. The target remains unchanged and absent from the parent's
roster. Clearing the synthetic marker to `0` restores the existing healthy-bind
control. Final sequential regression qualification: **184 passed, zero skipped**,
nine suites covering creation, decoys, cancellation, healthy binding and identity
journal recovery as well as the new refusal cases. Full application and all
changed-test static analysis reports no issues.

Initial expanded-test compilation used a nonexistent backing `dispose` method;
it was corrected to the real `close` method before the qualified baseline run.
An initial native fixture omitted private-root creation, and one bind fixture
used a controller getter instead of the existing state field. Those invalid
invocations are not credited. Empty failed-fixture directories were removed;
qualified checks retain the original refusal and preservation oracles.

The selected previously qualified native library's hash is verified unchanged.
No Rust source, native pin or protocol change. All checks run with
`TMPDIR=/private/tmp/` in background processes. No application window is launched,
activated or receives injected input, and no real OS credential or user profile
is touched. Private paths, identities and raw logs stay outside the repository.
No push or release.

Still open: authenticated pre-roster master/unbound-child recovery and explicit
cleanup, the complete mode/credential/destructive matrix, physical OEM/platform
qualification, Windows source-directory durability, native pin rebuilds, release
AOT and default activation. Existing containers are not migrated automatically.
