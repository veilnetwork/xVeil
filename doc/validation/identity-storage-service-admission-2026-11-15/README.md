# Session-service admission during identity storage work

Managed-storage defaults remain **disabled**. This resolves the locked-storage
startup observations retained in the
[packaged hosted-node follow-up](../hosted-node-metrics-2026-11-15/README.md).
It does not activate the new storage modes or complete platform qualification.

## Confirmed mechanism

A master edit retains the previous ready identity while it exports keys, closes
its active facade and opens a master or child through that facade. The ordinary
one-active switch also retains ready state during teardown/close. The session
service gate checked phase and session-ending depth, so those intervals still
looked like permission to construct new services for the previous identity.

The earlier packaged creation trace contained four uncaught reads: the device
bridge's own-document announcement, cloud materialized-view startup, scheduled
space-post maintenance and an own-device group-sync nudge. All reached storage
that was no longer open. Seven gated edit/cleanup controls and a separate
ordinary-switch close control reproduce the admission defect without native
network timing: the old code returns an identity where admission must be null.
Two already-preparing selected-open/adopted controls pass on both versions.

## Ownership change

Each accepted edit, one-active/queued selection and public hosted reboot now
holds one shared in-memory service-admission lease before its first await.
`sessionWorkIdentityProvider` returns null while any such owner remains. The
lease is released only after the existing cleanup/recovery has settled. A queued
selection holds its own lease while waiting for an old edit, so old cancellation
cannot unseal services during the replacement operation. This counter describes
outstanding work, not identities, and is not persisted or exported.

The existing session/node teardown continues to join current and retired
messaging shutdown hooks while storage is open. The new gate prevents a fresh
fallback/group/document service from appearing behind that drain. Already
accepted work is joined, not discarded. Native authorization, key ownership,
roster validation, durable writes and UI identity-lease checks are unchanged.
Direct hosted view changes keep their existing stable per-identity handles;
they do not take a storage-mutation lease.

The release callback captures its provider controller and is once-only. It can
retire accepted work without reading a disposed application ref. Controls cover
user lock/start-over, container disposal, queued ownership, recovery, inert
fallback streams and explicit reboot cleanup. Positive completion restores
service admission only for the resulting ready identity.

## Evidence and fixture corrections

- Final relevant sequential regression run: **149 passed, zero skipped**, nine
  suites, with the selected native hidden-volume library enabled for optional
  compaction cases. Full application/changed-test analysis reports no issues.
- Eager service construction at transient facade gates performs zero additional
  setting/conversation reads. Group/document services remain absent; an already
  admitted cleanup is held and joined before the active store may close.
- Overlapping edit/selection ownership reaches depth two and retires to zero.
  Reboot cleanup holds admission despite the retained ready UI state.
- Two wipe checks initially lacked the OS-vault port used by the current wipe
  absence protocol. They fail identically with admission accounting disabled.
  The fixture now uses the existing in-memory retirement secret store, including
  its actual absence witness. Wipe results and container-deletion assertions
  remain intact; production cleanup is not relaxed.
- A mock notifier invalidation initially was mistaken for notifier replacement.
  The corrected control asserts Riverpod retains the same mock notifier and its
  pending work/count. Actual user lock and container-disposal controls remain
  separate. Invalidation is not credited as a cancelled user session.
- An initial broad test command named two nonexistent test files and omitted
  the optional native library. That invocation is not counted; the final
  explicit file set and qualified library above are the credited run.

## Normal-main macOS qualification

A fresh, isolated QA profile went through ordinary onboarding to create an
independent encrypted identity and a known cloud note. The real Add Identity
screen then converted it into an encrypted master with the original encrypted
child and a new hidden child, reproducing the earlier creation path. The new
hidden child started a real native node; the source note was absent there and
its own new note read back exactly.

Ordinary switches in both directions preserved the two actual native IDs and
both note digests. Each identity's note was absent from the other. After lock,
process termination and a cold master-password unlock, both actual IDs and
notes still matched, including cross-identity absence checks. No oracle accepts
a deterministic loopback ID. Complete retained creation/switch and cold-run logs
contain zero uncaught errors and zero dropped entries.

The debug QA app uses normal main code with only its isolated bundle metadata
changed. Product-input manifests were reverified, as were the package signature,
Dart kernel and mapped SDK/hidden-volume/SQLite libraries. The selected native
binaries are unchanged. No installed user app or profile was replaced. The
synthetic certificate clipboard operation preserves/restores the prior clipboard;
raw credentials, identities and logs remain outside the repository.

Owned apps were locked and stopped, launcher completion and process/listener
absence checked. No push or release. Physical Android/OEM, the complete platform
mutation/recovery matrix, Windows source-directory durability, custom source-name
journal binding, all-target native pin updates, release AOT and activation remain
open. This run does not qualify remote message/call delivery or those platforms.
