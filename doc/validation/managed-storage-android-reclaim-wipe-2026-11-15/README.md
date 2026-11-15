# Android reclamation and whole-profile wipe

Production managed storage remains disabled. This follows the
[three-mode application qualification](../managed-storage-android-modes-2026-11-15/README.md)
on the same isolated Android 15 arm64 AOSP emulator. All four identities and
their notes are synthetic; the real application and user containers are not
opened. This does not qualify physical OEM firmware or release artifacts.

## Confirmed lock-screen admission defects

The lock screen still hid **Clear all data** when the visible catalog contained
entries, including when the complete profile-erasure owner was bound. This
affected both the direct button and the **Start over** dialog. The backend now
implements owned whole-profile erasure, but the old interface guard made that
operation unreachable. Conversely, an empty managed catalog without its erasure
owner exposed legacy deletion even though the backend correctly refused it;
an empty public catalog can still coexist with hidden data.

Both entry points now use the same admission rule: a managed profile requires
its whole-profile erasure owner. Only an actual legacy configuration with no
managed router uses the legacy action. This changes action availability, not
deletion authority. The existing controller, durable intent, quiescence,
inventory and recovery protocol remain authoritative. The existing typed-phrase
dialog still names deletion of all hidden, encrypted and unencrypted identities
in the selected profile, settings, saved sign-in and models.

The original code fails both owned/populated entry tests and the empty/unowned
refusal test. Four regression checks use a real temporary public catalog and
router, with a recording controller at the final deletion boundary. They verify
both entry points, displayed scope, disabled confirmation before/correct after
the phrase, cancellation without a request, one request after fresh consent,
and refusal for both empty and populated unowned catalogs. Together with the
existing lock and localized confirmation suites, 28 checks pass with no skips.
Analysis of the three changed Dart files is clean.

An existing legacy wipe test also failed on unchanged production code: it
asserted onboarding after animations settled while real filesystem/model I/O
was still pending. Its observer now yields real event-loop turns and checks a
terminal phase or explicit stopped report within a bounded observation window.
The assertion still requires onboarding. This is not a latency threshold, a
second wipe request or a substituted success result.

## Actual application reclamation

The ordinary application opens each visible identity, verifies its full public
ID and saved note digest, and activates **Reclaim space** in storage settings.
Completion requires the visible **Done** result, continued ready state and
matching identity/note. Native file digests are captured before and after.

| Mode | Active-file witness | Isolation/readback |
|---|---|---|
| Encrypted | Content and maintenance files rewritten; keybox byte-identical | Five other payload/role files, including the hidden container, unchanged; cold ID/note readback passes |
| Unencrypted | Normal owned maintenance completes; logical size stays 40,960 bytes | Seven other payload/role files, including the encrypted files and hidden container, unchanged; cold ID/note readback passes |

Both operations use the already authorized identity and require no other
identity's password. Subsequent normal opens also verify the original encrypted
and hidden notes. These small-fixture runs qualify operation routing, isolation
and persistence, not space savings. The encrypted identity's sampled logical
length actually rises from 1,937,408 to 2,195,456 bytes across the application
operation; background/application metadata work is not isolated from those
samples. No shrink or steady-state growth improvement is claimed. Large churn,
repeat-maintenance bounds and platform crash tests retain their own gates.

## Actual owned-profile deletion and cold start

The rebuilt debug APK retains the separate application ID and intended testnet
assets. All four native libraries are byte-identical to the preceding verified
APK; their exact strip reconstruction and source/provenance checks remain in
force. The app's real **Clear all data** action opens the full-profile warning.
A wrong phrase leaves confirmation disabled. Cancelling preserves exact digests
of the nine old payload/role files. The action is reopened through **Start over**
and only the exact phrase enables **Delete forever**.

After confirmation, the real controller/worker/platform composition reaches
onboarding. All nine old files are absent, including the shared hidden container
and all three enumerable identity stores. A synthetic file placed in a different
profile directory retains its original digest. This is a scope sentinel, not a
claim that a second complete profile was opened or functionally qualified.

The owned app is stopped and its exit observed, then the same installed APK is
launched without reinstalling or clearing data. It starts in onboarding. The
old payload paths and catalog remain absent, with explicit missing-file and
dangling-link checks; no old identity selection is reconstructed. The separate
profile sentinel remains unchanged. The final bare-router refusal tightening
does not change this bound-owner branch; its empty/unowned behavior is covered
by the additional red/green check above. The final source is also rebuilt,
installed with an independently checked APK digest and started after the wipe:
onboarding, old-payload absence and the separate-profile sentinel checks pass.

## Observer corrections and limits

- A transient semantics-node ID did not resolve on a later hook call. The
  observer instead focuses the unique visible phrase field by its bounds and
  enters text through the normal editable control. No controller mutation is
  used.
- An Android back key dismissed the confirmation rather than merely hiding a
  keyboard. The attempted sequence was not credited. The negative control was
  repeated using the actual Cancel button and a fresh before/after inventory.
- After cold deletion, an attempted catalog copy contained a remote missing-file
  diagnostic despite a successful local `adb exec-out` status. SQLite rejected
  it. It was not accepted as an empty database. Final absence checks use remote
  `stat`, existence/link checks and the onboarding state.

No interruption was injected into this whole-profile wipe. Native modeled
crash boundaries, live sessions, OS-vault credentials, downloaded models and
other complete profiles require their own qualifications. This run also does
not qualify mixed-roster hidden compaction or activate the new storage default.

The owned app/emulator are stopped with exit checks; the owned ADB forward and
the temporary scope sentinel are removed. No production package or infrastructure
is changed. Private logs, synthetic credentials and current/rollback QA artifacts
remain outside the repository.
