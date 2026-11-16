# Three storage modes

Status: implementation in progress; not part of the 0.13.101 release.

Managed storage remains disabled in production defaults. The live full-profile
wipe, persistent recovery journal and cold-start recovery owner are implemented;
the chronological sections below record their individual qualifications. Android
saved-entry presence/removal and ordinary metadata reads avoid key initialization.

The [Android release/AOT qualification](validation/managed-storage-android-aot-2026-11-16/README.md)
now verifies an isolated ARM64 APK, its native inputs, signature and privacy,
then normal first launch and encrypted-default creation in a headless Android 15
emulator. It exposes an open Saved Messages visibility symptom; data loss and
its cause are not established. A separate selected-mode accessibility defect is
fixed with 17 host checks. Android all-mode/persistence and activation work is
not declared complete by this run.

The [macOS release/AOT qualification](validation/managed-storage-macos-aot-2026-11-16/README.md)
now compiles the ordinary entrypoint with managed storage enabled for isolated
ARM64 QA. The packaged app passes native-load, signature and artifact-path
checks; its exact release native libraries pass 15 host checks including mixed
all-online traffic and post-ACK process-death recovery in all modes. No graphical
AOT app was launched. Other target/platform and activation work remains open.

The [mixed native-session follow-up](validation/mixed-native-session-2026-11-16/README.md)
completes all six master-protection/hosting combinations and separately qualifies
the ordinary three-node all-online boot with actual native crypto and traffic.
Active-view switches and owned reclamation preserve hosted nodes; lock releases
them and cold reopening restores exact histories and native ratchets. Ten host
checks pass, without changing production defaults or claiming platform-wide
qualification.

The [model-import owner follow-up](validation/model-import-profile-owner-2026-11-16/README.md)
fixes a delayed chat bundle import acquiring fresh installation authority after
profile wipe. Old targets now remain bound to their original work owner through
inspection/dialog waits; explicit fresh imports still work. The 115-check host
qualification includes native wipe/storage regressions. Packaged/platform and
remaining activation inventory gates stay open.
The Settings follow-up closes the same boundary before file-picker dispatch:
late import choices cannot recreate erased models, and an old export choice
cannot export a replacement profile lifetime's files. Its 68-check host run also
verifies that explicit new import/export actions still preserve exact bytes.

The [native ratchet first-root follow-up](validation/native-ratchet-first-root-2026-11-16/README.md)
fixes publication of a first conversation with a durable sending reservation
but no recoverable root snapshot. The real two-node host probe now survives
post-ACK process death and continues messaging in each of the three modes;
102 regression checks pass. This extends the earlier unratcheted storage test
below; packaged/platform and activation gates remain open.

The [mixed-session crash qualification](validation/mixed-session-ack-crash-2026-11-16/README.md)
now verifies 36 acknowledged messages across simultaneously open hidden,
encrypted and plaintext identities after SIGKILL and cold reopen, with a
negative control against fabricated ACKs. Its 31-check run qualifies the host
storage/ingress boundary; native ratchet, platform and activation gates remain.

The [Windows source-barrier follow-up](validation/windows-source-recovery-barrier-2026-11-16/README.md)
replaces blanket refusal of reference repair with a checked existing-directory
flush. Fourteen native recovery cases pass with administrative rights disabled;
four Windows process-death cases remain explicitly skipped. Host regression,
worker recovery and source-binding checks pass. This closes the missing barrier
implementation, not packaged/platform crash qualification or default activation.

The [Windows process-death follow-up](validation/windows-reference-process-death-2026-11-16/README.md)
now qualifies all four previously skipped reference-repair boundaries with an
owned AOT writer. Windows passes 18 native cases without administrative rights
or skips; macOS passes the same 18-case suite. Keybox bytes, sibling payloads and
both hidden-space payloads survive. Packaged UI/OEM and other activation gates
remain; this closes the standalone Windows process-death gap only.

The [hosted compaction follow-up](validation/managed-compaction-access-root-2026-11-15/README.md)
separates access-root credentials from hidden keep-set authority, restores
confirmed source ownership and the selected hosted view, and fixes completion
on a replaced settings route. Normal-main macOS compaction and cold hidden-note
readback pass, with 185 regression checks. Hidden network-ID comparisons that
used a debug loopback fallback are withdrawn. The
[hosted-node follow-up](validation/hosted-node-metrics-2026-11-15/README.md)
fixes colliding diagnostic ports and status remount, then verifies actual native
IDs through compaction/cold reopen and the exact hidden note, with 160 regression
checks plus a real two-node startup test. The
[identity-work admission follow-up](validation/identity-storage-service-admission-2026-11-15/README.md)
then seals service startup while a master/child facade is changing. Fresh normal
onboarding, master conversion, both actual node IDs, isolated notes and cold
reopen pass with 149 regression checks. Remaining platform gates still block
activation.

Packaged application qualification is now in progress. The isolated macOS app
has created an encrypted identity through normal onboarding and reopened that
same identity after process death, rejecting a wrong password. Its real lifecycle
run also exposed service-recreation/startup-read races during lock. The
[shutdown qualification](validation/managed-app-session-shutdown-2026-11-15/README.md)
records their fixes, three real unlock/lock cycles and the 543-check final run.
The [mode-switch follow-up](validation/managed-storage-mode-switch-shutdown-2026-11-15/README.md)
also qualifies normal plaintext/hidden onboarding, cold reopen and note
persistence, with existing sibling payloads unchanged. Immediate switching
exposed additional retired-provider/startup-publication races. Their fixes pass
570 checks and six real ready/lock cycles with zero uncaught errors. The
[Windows bootstrap follow-up](validation/managed-storage-windows-bootstrap-2026-11-15/README.md)
fixes fresh-worker DLL lookup and qualifies normal startup/cold coordination-role
reopen on an isolated Windows 11 debug build. The
[Windows preference follow-up](validation/windows-preferences-private-create-2026-11-15/README.md)
fixes inherited file permissions with private creation and verifies real worker
write/reopen plus a cold read in a separate AOT probe process, including an
already-open stale reader. The
[Windows mode qualification](validation/managed-storage-windows-modes-2026-11-15/README.md)
now covers normal onboarding and cold reopen for all three modes, exact note/ID
readback, plaintext read without a key, and return to both enumerable identities.
It also exposed inherited runtime/control-key permissions; the
[runtime-DACL follow-up](validation/windows-runtime-private-create-2026-11-15/README.md)
fixes private creation and unsafe ancestry admission, with nine Windows native
cases and the normal rebuilt app. The
[Android bootstrap follow-up](validation/managed-storage-android-bootstrap-2026-11-15/README.md)
fixes rejection of Android's app-owned 0771 parent directory and missing-media
build admission. The
[Android mode qualification](validation/managed-storage-android-modes-2026-11-15/README.md)
covers normal creation/cold reopen for all three modes on an Android 15 AOSP
emulator, exact identity/note readback, a no-key plaintext read and return to both
enumerable modes. Physical Android/OEM, complete platform destructive/recovery
qualification, application release AOT and activation are not yet complete.
The [Android maintenance follow-up](validation/managed-storage-android-reclaim-wipe-2026-11-15/README.md)
qualifies actual owned reclamation of both visible modes with sibling payloads
unchanged, then whole-profile deletion and cold onboarding. It also repairs
stale lock-screen wipe admission for owned and unowned managed routers. These
small-fixture runs make no space-savings claim and do not close platform crash,
credential/model-inventory, mixed-roster maintenance or physical OEM gates.
The [persisted-padding follow-up](validation/managed-storage-persisted-padding-2026-11-15/README.md)
isolates a configuration defect: managed files disabled padding only for their
open session while native compaction inherited the header's hidden-storage
default. New managed files now persist no-padding at creation through the
updated hidden-volume constructor. Host A/B/A and recovery checks pass; native
libraries must be rebuilt/qualified for every target before packaging this
binding change. Hidden defaults and existing stores are not converted.
The [Android persisted-padding qualification](validation/managed-storage-android-persisted-padding-2026-11-15/README.md)
now verifies the rebuilt native library in an isolated ordinary-entry Android
debug app: actual three-role headers, normal owned reclamation, password-based
cold readback and hidden default/isolation checks pass. This emulator run does
not close physical OEM, release AOT, other native targets or mixed-roster gates.
The [compaction storage-scope follow-up](validation/compaction-storage-scope-2026-11-15/README.md)
fixes legacy password coverage/roster repair for independently owned children
and refuses credential operations against an active managed root. The 75-check
run includes prepared native publication/refusal and unchanged sibling files.
Cross-owner references held by managed masters still require recovery wiring;
the mixed-profile compaction guard remains enabled.
The [external-reference recovery follow-up](validation/external-compaction-reference-recovery-2026-11-15/README.md)
adds a private cross-owner backend with actual process-death recovery checks,
selected-root recovery and source-name durability admission. It also fixes
legacy compaction treating unreadable rosters as absent by requiring strict
maintenance reads. Worker/UI/cold-start integration and Windows source durability
remain incomplete; managed defaults and the mixed-profile guard are unchanged.
The [entry-admission follow-up](validation/compaction-entry-admission-2026-11-15/README.md)
extends strict live reads to manual single-password and automatic pre-session
compaction, refuses incomplete collected key maps, and owns repair credentials
through publication. Native controls verify refusal preserves both identities
and their files while healthy solo maintenance remains available. This does
not activate managed defaults or remove the mixed-profile guard.
The [worker recovery integration](validation/managed-reference-worker-recovery-2026-11-15/README.md)
now connects selected-root recovery to ordinary profile opens. Pending roots
are not served before repair; the catalog worker quiesces its shared grants,
authenticates the selected identity and acquires exclusive recovery ownership.
All-owner compaction-dialog preparation, Windows source durability, full worker
crash-boundary qualification and activation remain open. Unjournaled opens do
not probe the hidden source or acquire exclusive maintenance ownership.
The [worker-local prepared-owner follow-up](validation/prepared-worker-owner-2026-11-15/README.md)
adds a synchronous native capability for the worker that holds full-profile
leases, without dispatching publication to another isolate. Plugin checks and
actual process-death checkpoints qualify its publication/abort behavior. The
application's all-owner dialog and worker operation still need to be connected;
this prerequisite does not change defaults or bypass the mixed-profile guard.
The [preference-owner follow-up](validation/preference-grant-quiescence-2026-11-15/README.md)
fixes a confirmed composition gap: ordinary preference-file ownership blocked
selected-root recovery's exclusive admission. Recovery now quiesces matching
local preference actors and restores existing grants before later file I/O.
Normal bound-preference bootstrap/read/write remains usable after repair;
new actors refuse during maintenance and need explicit retry.
The [full-profile compaction-worker follow-up](validation/managed-legacy-compaction-worker-2026-11-15/README.md)
now owns prepared publication and private-reference repair in the same worker
that holds exclusive profile roles. The profile owner coordinates preferences,
serializes close and restores metadata selection. Native checks cover actual
process death before publication and after commit but before its reply, plus
bounded uncertain outcomes. The all-owner dialog/controller entry, custom-source
journal binding, Windows source durability and complete app/platform recovery
qualification remain open; defaults and the ordinary mixed-profile guard are
unchanged.
The [all-owner collection follow-up](validation/managed-compaction-collection-2026-11-15/README.md)
now connects the dialog and controller to that full-profile publisher. Hidden
keep-set credentials and visible-owner permissions stay separate; plaintext
owners require explicit consent. Selected-owner probes retain ordinary private
journal recovery and are owned by the router through close. Real native cases
qualify source/ref preservation, interrupted-intent recovery and post-publication
reopen errors; narrow widget controls qualify collection and uncertain outcomes.
The ordinary mixed-profile fallback remains guarded; only a complete explicit
collection admits the coordinated route. Ordinary packaged lifecycle, physical
OEM/platform recovery, custom-source binding, Windows durability, complete
credential/model inventory, release AOT and all-target native packaging remain
open. Managed defaults stay OFF.
The [custom-source binding follow-up](validation/custom-source-compaction-binding-2026-11-15/README.md)
now carries the configured profile-local container leaf through bootstrap,
compaction and authenticated private recovery intents. Default-path and custom
native crash/recovery checks pass; packaged macOS publication is qualified,
while its post-publication cold readback remains incomplete. Windows source
durability, physical OEM/platform recovery, complete credential/model inventory,
release AOT and all-target native packaging remain open. Defaults stay OFF.
The [whole-profile wipe source-binding follow-up](validation/managed-wipe-source-binding-2026-11-15/README.md)
requires the retained preference source and router to name the same container,
not merely the same parent directory. Native controls cover default/custom
source refusal before side effects and successful exact-file deletion with a
same-key neighbor preserved. This is a boundary fix, not default activation.
The [startup-consent follow-up](validation/managed-startup-consent-2026-11-15/README.md)
separates enumerable identities' quick-entry consent, so changing one identity
cannot hide or authorize another's saved entry. It preserves accepted historical
enrollments and serializes fallback migration with explicit choices. Background
settings/start-over and native preference-file reopen checks qualify this layer;
physical authentication and the remaining activation gates stay open.
The [unfinished-setup admission follow-up](validation/pending-master-admission-2026-11-15/README.md)
now checks pending master state before roster classification, including when a
profile already exists. Both setup markers guard each legacy/managed member
before network planning; unfinished targets cannot be bound into a master.
Native preservation checks pass across all three modes. Authenticated recovery
of a pre-roster master or unbound child still needs its original durable intent;
this admission fix does not invent it or enable the new default.
The [master-intent preparation follow-up](validation/master-setup-intent-preparation-2026-11-15/README.md)
adds a private, atomic base-intent/pending-marker publication and one-way child
key attachment. Host-native process-death checks cover all three modes; 120
regression checks pass. This is a preparation backend, not yet the ordinary
application creation/recovery path. Planned-child reconciliation, completed
roster publication, a final receipt and application recovery remain open;
managed production defaults stay OFF.
The [ordinary master-creation completion follow-up](validation/master-setup-creation-completion-2026-11-15/README.md)
now uses that intent in routed conversion: persist the planned child, record
its actual keys before payloads, verify child completion, then publish the
roster and atomic non-replayable receipt/cleared marker. Native interruption
and process-death controls cover preparation and completion. Application
recovery UI/replay, planned-child reconciliation, transactional existing-master
appends and remaining activation gates are still open; defaults remain OFF.
The [application master-recovery follow-up](validation/master-setup-app-recovery-2026-11-16/README.md)
now connects authenticated continuation to the recovery screen and edit owner.
It handles the planned child's absent/partial/known states without replacing a
failed open, then completes and re-enters the ordinary roster. Host-native
controller and headless screen checks pass; lock/disposal and lost final replies
preserve the accepted state. Existing-master appends, packaged/physical recovery
and the remaining activation audit stay open. Defaults remain OFF.
The [transactional append follow-up](validation/master-append-recovery-2026-11-16/README.md)
now journals ordinary routed additions to an existing master. A compact roster
commitment preserves the existing large-roster limit, accepted child keys are
recorded before payloads, and exact refusal can retire an unadvanced plan.
Transient failures offer authenticated continuation; a lost completion reply
requires ordinary reread instead of restoring stale cached membership. Extra
master settings/files remain intact. The legacy non-router path and remaining
packaged/platform/default-activation gates stay open; defaults remain OFF.
Earlier section-local “remaining” notes are historical; this
opening status and the newest qualification reports describe current evidence.

The owner requested an enumerable encrypted default, optional hidden storage,
and an explicitly unencrypted store. Existing hidden containers must retain
their current protection until the user requests and confirms a migration.

| Mode | Local contents | Identity directory | Reclamation |
|---|---|---|---|
| Hidden | Encrypted, deniable spaces | Never enumerate hidden spaces publicly | Preserve the unknown-space boundary; no automatic rewrite that discards unknown spaces |
| Encrypted (new default) | Encrypted, one store per identity | Opaque local locators and protection mode may be public | Reuse freed pages and reclaim only this identity's data |
| Unencrypted | Plaintext, including local identity secrets | Same independently owned layout | Reuse freed pages and reclaim only this identity's data |

Transport encryption, peer authorization, ratchet barriers and durable delivery
acknowledgements remain mandatory in all three modes. An unencrypted local
store must explicitly warn that someone with filesystem access can read its
contents and impersonate the local identity. It is never the default or an
automatic fallback after an encrypted store fails to open.

## Initial implementation and subsequent qualifications

The legacy `StorageMode.plain` onboarding choice only persists a preference;
bootstrap still supplies `HiddenVolumeStorage` for both choices. It is not a
working plaintext backend. Merely relabeling this choice would misrepresent
the protection and would not solve storage growth.

The current implementation already has lower-growth padding enabled by
default. Hidden-volume also reuses retired slots under its churn rules
(`third_party/hidden-volume/DESIGN.md`, section 9.1). Unbounded growth is not a
necessary definition of hidden storage. A snapshot cannot, however, safely
attribute every unknown chunk to garbage: another hidden identity may own it.

Production onboarding/unlock still select the legacy backend. An isolated QA
build can opt into the initial application wiring with
`--dart-define=XVEIL_MANAGED_STORAGE=true`, as qualified below. This is not
a release switch: master mutations, mode-aware erase/rotation/recovery and
packaged-platform qualification remain incomplete.
The catalog rejects hidden entries, credentials, network identifiers, unknown
fields, duplicate locators and paths outside a strict local ID format. It
does not silently replace malformed existing metadata with an empty catalog.
The pure layout does not claim to solve filesystem symlink races.

The plaintext-only connection now uses `sqlite3` **3.5.2** with the ordinary
SQLite hook. The current Flutter SDK pins a dependency that prevents using
3.7.1; no SDK constraint was overridden. The selected macOS arm64 asset matches
the package-pinned SHA-256 and passed GitHub attestation verification against
the upstream repository. Flutter and Dart rewrite install names and ad-hoc
sign the library on macOS. Both actually loaded copies were independently
reconstructed from the verified download with those transformations and matched
byte for byte. This does not qualify the engine on other platforms.
The SQLCipher hook, C keying symbol and key-digest code were removed. Requests
to open encrypted storage through this connection fail before filesystem I/O;
there is no fallback to plaintext.

New-file creation reserves the leaf exclusively, then opens it without SQLite's
CREATE flag. Reopen never recreates a missing file. Existing files, directories
and final-component links are refused for creation. This is not path admission:
callers must still own the containing directory, handle unpublished stubs and
protect against ancestor/rename races before exposing the backend.

The plaintext KV/log adapter keeps payload mutations, the commit sequence
and a bounded 1025-entry inclusive branch-root history in one transaction. It selects
`synchronous=EXTRA`, rollback journals, secure deletion and full auto-vacuum.
Namespace erasure does not load the whole history into Dart. Five host cases
cover connection reopen, failed COMMIT rollback, bounded growth under 64
rewrites of a fixed 2 MiB log set, shrink after deletion with a sibling file
unchanged, fork/history retention and locator mismatch. Five connection cases
cover encrypted-request refusal without file creation or modification, explicit
plaintext readback, creation/open boundaries and errors omitting SQL, bound
values and paths. One further ordinary-SQLite negative control demonstrates
that plaintext storage does not authenticate data-page replay.

**The encrypted SQLite prototype was rejected before application integration.**
A historical SQLCipher qualification replayed an old data page while leaving
fresh metadata and commit roots intact: the experimental store accepted the
old reservation under the new anchor. The first probe failed on a PRAGMA result
type and was not counted; after correcting the probe it failed on the intended
old-value assertion. That prototype and its evidence were archived before the
provider cleanup. The current plaintext replay control is not a rerun of the
removed cipher. Neither refusing encrypted requests nor changing the provider
fixes SQLCipher page replay. No released application selected this prototype.

Ordinary encrypted identities therefore retain hidden-volume's existing
authenticated-state foundation, separately owned per visible identity. The
SQLite adapter is limited to explicitly unencrypted storage, where hostile
filesystem access already exposes the identity secrets. Fresh-process crash,
filesystem admission, bounded managed-file reclamation, application
password/biometric handling, UI and worker integration remain unqualified
except for the selected native boundaries described below.

A bounded maintenance blob is now implemented for the future dedicated
managed-encrypted maintenance space. Two fixed log banks stage at most 64 KiB;
a small authenticated-store head selects the complete payload only after all
chunks commit. It uses a log-only namespace rather than mixing KV and logs,
keeps at most 129 logical records, and refuses missing/corrupt published state
instead of silently initializing it. The extra SHA-256 binds the complete
chunk set; it does not replace hidden-volume authentication or make the rejected
encrypted SQLite prototype acceptable. Callers must serialize the exclusively
owned maintenance space and validate its managed role before using this port.

Six focused cases cover all before/after commit interruptions of a five-chunk
update, lost head responses, incomplete initialization, input buffer mutation,
malformed/missing/mismatching chunks, size limits and repeated maximum rewrites.
A seventh native case actually SIGKILLs three owned writer processes: before
the first new chunk, before publishing the complete new head, and immediately
after that native commit. Cold reopen returns the exact old or new 49,155-byte
payload, and a subsequent write succeeds. The final fixture is seeded random
data, not a trivially compressible repeated pattern. This qualifies selected
POSIX commit boundaries on macOS, not interruption inside native commit, power
loss, content repack, or Android/Windows managed storage.

The test library is the published macOS arm64 hidden-volume **2.7.2** asset,
SHA-256 `eb7c89a517464f059c2b8603a10b9b063b61cc5333d7188035a119bf66483571`.
Its checksum manifest passed cosign verification for the tagged release
workflow; the submodule/tag resolves to
`072b402de7435884973edac7e95a360679e8ea89`. No Rust build or cached-library
provenance assumption was needed. Temporary fixture files were deleted and
each writer's PID/exit status was observed after SIGKILL. No application or
real identity was opened. This primitive is not wired to the current app.

Managed generation/checkpoint state and encrypted role tags are now implemented.
A role tag binds a keybox, content or maintenance space to its opaque local
identity; existing files with absent/wrong tags are refused, not adopted.
The checkpoint codec shares one 1025-root inclusive history between active/prepared
generations, fitting in 41,130 bytes at maximum. It rejects malformed counts,
integer overflow, trailing data, contradictory checkpoints and unordered roots.
Roots from the copy phase before the new generation's floor are filtered rather
than assigned logical numbers belonging to the original content history.

A prepared state chooses the old or new mapping by the generation tag actually
authenticated from content. It never guesses publication from a callback or
resets the logical anchor. Current roots must agree with retained roots; wrong
owner/generation or content below the recorded checkpoint fails closed. The
existing external host-anchor policy still judges the resulting logical head;
this metadata is not an additional independent external anti-rollback device.

Thirteen policy/codec/role cases and one real native compaction case pass.
The native case covers normal completion plus actual process SIGKILL after
the durable PREPARED state and after native publication, before completion was
recorded. Cold-open preserves all four fixture records and the old host anchor,
selects the expected generation and permits the next durable write/reopen.
The first attempt was not qualified: an unresolved Future let the Dart VM exit
before the requested kill. The corrected writer retains a live event source;
PID markers, successful kill requests and exit `-9` were observed for both cuts.

This is a private macOS fixture, not the application compaction controller,
the original damaged-phone scenario, a power-loss test or a multi-process
managed-directory admission test. The probe serializes its own files; admission
and application bootstrap still need mode selection before a mode can be enabled.
The factory/worker binding below now enforces the identity lease for its sessions. No existing container or onboarding choice changed.

The native `ManagedKeybox` port now initializes role and 64 random internal
password bytes in one transaction. User-password-derived outer keys remain
those of the keybox; the actual user password is not persisted by this port.
Owned secret copies and the port's buffers are wiped at the defined close/
failure boundaries. A caller must retain copies until async native work settles
and then wipe them. Internal content and maintenance passwords are separate
32-byte CSPRNG values, not user-derived weak passwords or a plaintext key file.

Initialization requires the native bootstrap sequence **1** and refuses
already-written spaces. An earlier prototype incorrectly expected zero; the
published native test exposed that mistake before integration. A missing/wrong
role or unreadable keybox never invokes initialization as a fallback. The
native fresh-space test is not directory admission: creation ownership must
still be established by the future file owner. The port accepts already-opened
HV handles, chooses no KDF preset, and cannot replace the requirement that the
future user-password owner select the existing HEAVY preset. Tests use MIN
only for synthetic fixtures.

Five native keybox cases pass: password and pre-derived-key reopen with exact
secret preservation, caller-buffer ownership and at-rest ciphertext checks;
wrong password/keys/owner without replacement or a leaked lock; refusal to
adopt existing data/wrong roles; and atomic role+secret initialization when a
commit response is lost before or after the native write. Existing written
spaces retain their original data. No real container or OS vault was used.

The compaction fixture now uses all three files with actual keybox-generated
internal passwords. The child opens its keybox by password and retains that
lock while content is closed/prepared/published. At both kill barriers a second
process's key-based open returns `Busy`; after SIGKILL, key-based cold-open
works, supplies the original internal passwords, and the previous logical
anchor and exact fixture records remain valid. All six native cases pass on
the signed published macOS arm64 library. This verifies the keybox boundary
needed for biometric entry, not an actual OS biometric prompt or a connected
application backend. Filesystem admission and file-factory opening are now
qualified below on macOS; application mode selection, password
rotation, erase and platform qualification remain
unfinished; these ports are not selectable in the application yet.

`ManagedEncryptedKvLogStore` now implements the actual `KvLogStore`, logical
commit-anchor and grouped-log-read ports over owned keybox/content/maintenance
handles. It returns stable **outer** keys, validates encrypted role/checkpoint
state and durably settles PREPARED metadata before returning an application
handle. It does not discover/open paths or prove directory admission; callers
must open the inner files with the keybox's internal passwords and transfer
exclusive ownership. The managed worker below now opens these files; production
application bootstrap selection is still pending.

All app operations target content. Namespaces 254/255 are reserved; the entire
batch is checked before a native mutation. App-data erase therefore keeps the
backend role/checkpoint records rather than making the remaining file look
uninitialized. Full identity/directory deletion is a separate unfinished owner
operation. Slot occupancy and hardening warnings include all three files.
A close attempts every owned handle, blocks new I/O immediately, reports an
error if one close fails and allows retrying the remaining handle.

Eight native adapter cases and the existing native compaction/blob crash cases
pass together: **10 PASS, no skips** on macOS. The selected checks cover:

- KV/log/grouped reads, durable cold reopen, logical commit results, stable
  outer keys and aggregate occupancy/warning routing.
- Reserved namespace protection, all-or-nothing rejection, malformed/wrong
  owner state preserved without reset, and recovery with a lost response.
- A controlled close failure leaving the content lock until retry while the
  other handles close; blocked app I/O during that interval.
- The current schema's 8 live base namespaces + 86 log shards + 1 role root
  fit the native limit of 95. Adding the retired namespace 3 at that ceiling
  fails atomically. Explicit migration must rebuild retired layouts as needed;
  blindly copying every historical namespace is not qualified.
- Real `HiddenVolumeStorage` profile/message operations, a 17,000-byte native
  attachment, chunked outbox and opaque synthetic ratchet-state persistence.
  Wrong password/outer keys return failure. A foreign peer's ACK does not
  retire the frame; the intended peer's ACK does. This is not a real ratchet
  handshake or a network-delivery test.
- Erasing one identity leaves its application data absent on cold reopen and
  preserves its backend roles. A second identity retains its profile, message,
  attachment, outbox and ratchet bytes; its three native files are byte-for-byte
  unchanged by the first identity's erase. External blob-tier ownership and
  actual filesystem cleanup are not exercised by this internal attachment.
- After two actual compaction SIGKILL cuts, the new adapter itself resolves
  the prepared state, recognizes the previous host root, writes new data and
  cold-opens by the original outer keys. The blob case adds three actual
  SIGKILL boundaries. Writer PIDs, kill results and terminal statuses were
  observed. The earlier shared run exposed an empty-marker race in the test
  harness; markers now publish by flushed temporary file + atomic rename.
  That failing run was not credited as adapter/crash qualification.

Focused analysis of seven changed files is clean. The same signed published
hidden-volume 2.7.2 macOS arm64 asset was selected and its SHA rechecked; no
native source, ABI or release pin changed. All fixtures/processes are disposable
and contain no user data. This port is a working domain-storage boundary, not
a completed three-mode feature. Filesystem/catalog admission and managed-file
opening and the managed worker binding are implemented below; application
selection, automatic reclamation, all-online routing, mode/unlock UI,
biometric-vault scope, password rotation, recovery and erase still need wiring
and platform qualification. Existing containers are not converted.

## Public managed catalog persistence

`ManagedCatalogStore` now persists the strict visible-only catalog in an owned
ordinary-SQLite connection. Each registration reloads the current bounded
payload under `BEGIN IMMEDIATE`, updates payload and local revision together,
and returns after COMMIT. Independent owners do not overwrite each other's
old snapshots. Repeating an ID/mode after a lost response is idempotent; changing
the mode of an existing ID is rejected, never treated as a plaintext fallback.
Contention is an explicit retryable SQLite failure, not an empty catalog.

Opening verifies an exact versioned catalog schema and public application tag.
Missing rows, corrupt/oversized JSON, hidden entries, credential fields, extra
schema objects, future versions and non-DELETE journal modes fail closed. A
new initializer refuses an existing catalog/schema. Invalid open consumes and
closes its connection without resetting metadata. Public revision counters are
not cryptographic freshness witnesses. No automatic orphan removal or deletion
API exists at this stage.

Seven host cases exercise cold reopen, exact public payload, duplicate retry,
independent owners with stale initial snapshots, native write-lock contention,
rejected native COMMIT, count/mode/revision bounds, corrupt metadata, foreign
schemas and close/privacy boundaries. A further macOS native case actually
SIGKILLs two writer process groups: once at SQLite's pre-COMMIT hook and once
after the registration returns. Fresh processes read the complete old/new
catalog respectively, and retrying the lost response creates no duplicate.
This is process-crash qualification, not physical power-failure qualification.
The layout also names the plaintext database, all three encrypted role files
and identity-local blobs separately. A final joint run passed 32 cases with no
skips, including the existing real encrypted domain adapter; focused analysis
of 11 changed/affected Dart files is clean.

This remains an **owned-connection port**. The root/catalog admission wrapper
below now handles first initialization, and the managed-file factory handles
identity creation/opening. Catalog membership never authorizes file
ownership or cleanup; actual stores must authenticate their identity and role.
Application mode selection, migration, reclamation, password/biometric and routing
remain unfinished.

## Managed root admission and bootstrap

`ManagedDirectoryCatalog` now owns a catalog connection inside an admitted local
profile. `openExisting` returns null only when the entire managed root is absent.
An existing root with a missing catalog always fails, including a root already
containing identity directories. A corrupt catalog is preserved and refused;
neither case is silently reset to an empty list.

Explicit `createOrOpen` initializes a catalog in a newly reserved PRIVATE sibling
directory, closes it, syncs the directory and publishes the entire directory
without replacing any existing destination. Another creator's complete root
wins; the loser opens it without overwriting its catalog. A process killed
before publication leaves an unpublished sibling, never a final root with a
half-initialized catalog. Unpublished siblings are neither adopted nor swept.
Normal failed bootstrap cleanup is non-recursive and removes only the same
fresh directory and exact recorded file; a replacement or unexpected child is
preserved. Failure after publication leaves the complete root available to retry.

On POSIX the new root is created as 0700 and its catalog is restricted to 0600
before schema/payload writes. Existing ownership, permission/type and ancestor
checks refuse symlinks and unsafe paths. A trailing slash is removed before
`lstat` so it cannot turn a final-component link into an apparently ordinary
directory. Observable root/catalog replacement invalidates an open owner.
SQLite recovery sidecars (`-journal`, `-wal`, `-shm`) are admitted before SQLite
can open them. The sidecar regression's pre-guard control reached SQLite and
failed with CANTOPEN; it did **not** demonstrate an accepted escape in the pinned
SQLite engine. It verifies the earlier explicit filesystem-admission boundary.

Darwin extended ACLs are checked independently from mode bits: only empty or
deny-only ACLs are admitted, including the usual deny-delete entry. An allow
ACL is conservatively refused even if chmod still reports 0700. Initial tests
caught incorrect treatment of Darwin's absent-ACL/end-of-list results; those
failing runs were not credited. A separate headless run created and reopened a
fixture beneath the real home-directory ancestors, outside the temp fixture tree.
This remains a conservative policy, not a complete Darwin effective-ACL evaluator.

The Android ancestor policy recognizes the platform's protected `system`
UID/GID 1000, as defined by [AOSP filesystem permissions](https://source.android.com/docs/core/permissions/filesystem).
The identity root/catalog still must belong to the current application and be
private. Other application, media/OEM groups and non-sticky world writes remain
refused. Actual ancestor ownership/modes were read from an attached Android;
this is not an Android application-backend qualification.

Windows code uses the process token's SID, the existing handle-bound ACL probe,
file identity/attributes, normalized final-path comparison and protected
current-user/System/Administrators directory ACLs. Reparse leaves and remote
profile roots are refused. Publication uses
[MoveFileExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw)
without REPLACE_EXISTING, with WRITE_THROUGH; protected ACL construction follows
[Microsoft's security descriptor format](https://learn.microsoft.com/en-us/windows/win32/secauthz/security-descriptor-string-format).
The existing pinned win32 dependency is now direct; its version did not change.
The Windows policy/path tests run on the host; native Windows filesystem
behavior has **not** yet been qualified by these tests.

A final macOS joint run passes 54 cases with no skips: the prior 32 plus 14
root/admission cases, five Windows policy/path cases, two POSIX/Android policy
cases and one actual process-crash case with two SIGKILL boundaries around root
publication. The earlier catalog-COMMIT crash case also runs in this set.
Focused analysis of ten changed/affected Dart files is clean. No user stores
or installed application were changed; no Rust build or release pin changed.

Remaining boundaries are explicit. These path witnesses do not claim descriptor-
relative backend access or defense against hostile same-user ABA substitution.
They require a private root and trusted platform ancestors. Linux/Android use
renameat2 with NOREPLACE, refusing unsupported kernels/filesystems rather than
falling back to ordinary rename. Bionic exposes that libc symbol only from
[API 30](https://android.googlesource.com/platform/bionic/+/master/libc/include/stdio.h).
The Linux/Android binder now uses libc's variadic `syscall` when that symbol is
absent; this retains the same no-replace kernel operation. Native
Android/Windows/iOS managed-file operations and full Linux backend integration,
power failure, application bootstrap and the mode/identity UI remain unqualified or
unwired. Identity reservation/publication and keybox/content opening are now
qualified below on macOS. The existing
onboarding default and legacy stores are unchanged.

## Managed identity file factory

`ManagedIdentityFiles` now creates and opens the actual encrypted/plaintext
backends under an admitted root. A fresh random local ID owns a private
staging directory, role metadata, permanent empty lock marker and private blob
directory. Encrypted identities own `keybox.hv`, `content.hv` and
`maintenance.hv`; plaintext identities own `data.store`. Creation commits its
initial payload, closes the files, syncs the staging directory and publishes
without replacing an existing identity. It then reopens and validates the
backend before durably registering the catalog entry and returning a handle.
A catalog entry alone never grants permission to initialize a missing backend.

The outer keybox selects the existing HEAVY password KDF (256 MiB, time 4,
parallelism 4). The two independent random internal passwords use the native
DEFAULT preset. Exported 64-byte keys remain the keybox's stable outer keys.
Plaintext reopen uses a public deterministic locator, not a password or an
assertion of encryption. Credentials are copied for synchronous native calls
and owned copies are wiped afterwards. No raw native error text, path or local
locator is included in factory failures; safe original stack locations remain.

Each session retains its root ownership and an `identity.meta` lease until
all payload handles close. Role metadata contains only local ID and mode.
An exact-schema EXCLUSIVE SQL transaction is held on all platforms. POSIX also
holds `flock` on the separate permanent `identity.meta.lock` inode; Windows
uses SQLite's handle-bound locks. Neither open nor contention recreates a
missing/invalid marker. A second root, isolate or process cannot cooperate as a
second owner while the first lease is held. Closing the root with an active
session reports busy. Failed open/close resources remain attached for retry;
the lease is released last.

A new regression reproduced an important POSIX limitation in the initial
SQL-only lease: opening and closing the database through a raw file descriptor
released SQLite's process-scoped lock, permitting a second process to open.
[SQLite documents this close/locking behavior](https://sqlite.org/howtocorrupt.html).
The independent marker lock preserves ownership when unrelated descriptors to
either metadata or marker are closed. Placing flock on the metadata inode itself
was rejected after the macOS test exposed self-contention with SQLite locking.
A native `FILE*` finalizer supplies a GC safety net; it does not replace explicit
worker teardown or promise prompt release after killing one shared-group isolate.
Live database backup must still use a coordinated, quiescent owner boundary.

Interrupted creation leaves complete pending/final files intact. Explicit
`resumeEncrypted`/`resumeUnencrypted` requires a known local ID and correct mode;
encrypted recovery authenticates the existing role and payload before publication
or registration. Retrying after a lost registration response is idempotent.
Both pending and final directories present is an ambiguous recovery failure,
with both copies preserved. No automatic orphan discovery/sweep, recursive
cleanup, hidden-store fallback or legacy conversion is performed.

The final joint macOS run passes **72 cases, no skips**, including eight lease
cases, a native independent-process contention case, eight file-factory cases
and a factory process-crash case in addition to the previous 54. Actual native
checks cover exact KV/log/anchor data, cold password/key reopening, HEAVY outer
KDF parameters, plaintext/ciphertext boundaries, duplicate/root contention,
wrong credentials, foreign role files, payload symlinks and four publication/
registration fault boundaries. The factory crash case performs three actual
SIGKILL cuts: before directory publication, after publication and after catalog
commit before handoff. Each explicitly resumed identity retains exact payload
and one catalog entry, then cold-opens by its original outer keys. The earlier
root/catalog crash tests also run in the joint set. A first factory crash run
with an unarmed bootstrap hook failed in the harness and was not credited.

This is the managed file ownership layer, not the enabled application feature.
UI/default selection, application lifecycle routing, orphan recovery UI, automatic
bounded encrypted reclamation, all-online routing, password rotation, erase,
biometric integration and native qualification on other platforms remain.
Power failure and abrupt shared-group worker-isolate cleanup are not qualified.
No real identity, installed application, native source or release pin changed.

## Older Android atomic publication

The Linux binder now admits only known ARM EABI, arm64, IA32 and x64 ABIs;
UAPI syscall numbers were cross-checked against the Android NDK headers.
Only an absent libc `renameat2` symbol selects the direct syscall path. A failed
wrapper call is returned as a failure, never retried through another mechanism.
Missing syscall support or an unknown ABI fails closed, before guessing a call
number. The binding uses machine-width `long` values, native pointers and
[Dart's explicit variadic FFI signature](https://api.dart.dev/dart-ffi/VarArgs-class.html).
`AT_FDCWD` and `RENAME_NOREPLACE` remain unchanged in both native paths.

A standalone real Linux arm64 probe passed ten filesystem scenarios in JIT and
again as an AOT executable: existing empty/populated directories and symlinks
are preserved, successful publication moves exact payload, and a missing source
cannot create a destination. Each set runs first through libc and then with
only its rename wrapper hidden from symbol resolution, forcing the actual
syscall. The old wrapper-only candidate passed five cases then failed at the
first forced-syscall case; that is the recorded red control. A first AOT build
failed because its ephemeral compiler home was read-only; it was not credited.
Both successful runs used an immutable official Dart 3.12.0 Linux image, with
network disabled and source/FFI package mounted read-only. The source needs no
new native build, main binary feature or dependency.

The macOS joint suite now passes **76 cases, no skips**, adding four ABI/binder
checks to the preceding 72. Focused analysis is clean. These probes qualify the
Linux arm64 publication primitive, not Android libc/seccomp/OEM behavior, other
architectures, the full managed backend on Linux or power-loss durability.
No connected Android was available in this round. Android packaging/runtime
qualification still precedes enabling new storage modes in the application.

## Worker close ownership prerequisite

The existing single-store worker no longer kills its native owner when close
reports an error. The serving loop admits only further close attempts after
shutdown begins. The facade rejects ordinary I/O, shares concurrent close
waits and retains one wire request after a caller timeout. Late failure keeps
the worker supervised for retry; late success is accepted only from the real
success envelope. A dead worker's uncertain release remains an error on later
close calls instead of becoming an idempotent success.

Five gated regression cases failed against the prior facade: retry after
refusal, concurrent wait, timeout/retry, late refusal and repeated close after
worker death. A sixth test exercises the production command server itself with
a disposable synchronous store that refuses its first close. The server remains
available and its second close succeeds. Together with existing close/death and
headless-import checks, **30 cases pass**. Native-close failure and abrupt
native-worker abandonment are not manufactured or claimed by these fixtures.
The domain storage facade now also retains a separate retiring owner after a
failed close. Ordinary reads/writes see a locked store, but close and both
password/key reopen paths retry that exact owner before opening a replacement.
Close errors propagate instead of being logged as a dropped handle. Accepted
file/ratchet/sequence work still drains before retirement; derived caches are
invalidated on both success and failure.

All four new facade regression scenarios failed against the former swallowed-
error path and now pass. The related facade/file/roster lifecycle suite reports
41 PASS and one opt-in native skip; the skipped real-container roster case was
then explicitly enabled and passed separately, preserving master/child keys
through promotion, shrink and cold key-based reopen. No skipped case is counted
as passed. Focused analysis of the three changed facade/test files is clean.
The managed factory's worker binding is qualified below; the application's
mode selection and UI remain unwired.

## Managed worker binding

`ManagedWorkerIdentity` now exposes explicit visible-mode create, password/key
open and interrupted-creation resume APIs through the existing supervised
`WorkerKvLogStore`. Each worker opens/adopts its own root and identity session,
then retains both until store and root close complete. No native owner crosses
the isolate boundary. Password KDF and data I/O use the worker; there is no
inline fallback or hidden-container probe on failure. Key-based open requires
the caller's selected protection mode and checks it against catalog membership
before opening the payload, including plaintext locators.

Credentials and initial KV/log operations are snapshotted before asynchronous
spawn; caller mutation cannot change the request. The parent and child wipe
their owned copies after their opening/registration work settles. Worker error
messages for managed storage carry a bounded category, not raw backend text,
paths, locators, keys or SQL. Existing legacy error handling is preserved.

A failed open whose cleanup also fails keeps a cleanup-only worker alive. Its
close capability is transferred to the caller's private retirement registry,
which attempts release and retains the owner on timeout/refusal. A later request
for that profile/local ID must drain these owners before spawning again. The
registry normalizes lexical profile aliases; actual filesystem admission still
runs in the worker. It does not claim to resolve hostile filesystem aliases or
repair native handles after abrupt worker death. Unknown close replies never
count as release.

Six real macOS worker cases pass: mutation-safe plaintext creation; actual
independent-process lease contention/release; encrypted and plaintext profile/
file round-trips through the domain facade; cold password/outer-key reopen;
wrong credentials/mode without replacement; multiple active identities with one
closing while the other stays usable; missing/hidden refusal; idempotent resume
and all-or-nothing reserved-namespace rejection. This is six grouped test cases,
not six devices or a full all-online qualification. Two additional gated worker
checks cover invalid close acknowledgements and failed-bootstrap retirement
without filesystem access before release. The latter uses a disposable stub
owner; it does not manufacture a real native close failure.

The final joint storage/worker/lifecycle suite reports **157 PASS, one opt-in
native skip**. That skipped roster lifecycle case passed in a separate explicitly
enabled native run. The worker/headless/native subset reports 40 PASS with no
skips; headless import traversal follows parts and transitive packages. Focused
analysis is clean. The selected published hidden-volume and ordinary-SQLite
libraries retain their independently checked hashes; no Rust build, native ABI,
release pin, installed application or real identity changed.

Application bootstrap/default and mode UI are still not enabled. Automatic
bounded encrypted reclamation, all-online sessions, recovery UI, password
rotation, erase semantics and packaged/platform/AOT/biometric qualification
remain required. A compiled native-worker application and native Android
storage behavior are not qualified by these macOS Flutter test-VM cases.

## Inclusive anchor-window correction

A larger native workload exposed two unreleased managed-adapter errors. A live
native session can return more authenticated historical eras than its cold-open
window; rejecting that valid input made managed anchor reads fail after enough
commits. The resolver now validates those eras and retains only the bounded
logical output window. That window is inclusive: an anchor exactly 1024 commits
behind remains valid, requiring 1025 entries. Both managed maintenance encoding
and plaintext SQL retention now match the existing host/native policy, including
the plaintext namespace-erasure commit path. No native library was changed.

Three boundary regressions failed before the correction. The final focused
suite passes **26 cases, no skips**, including a real native session beyond the
horizon and cold reopen with the remembered boundary hash. Prepared/settled
metadata round-trips preserve that boundary; older anchors still age out and
malformed/future/conflicting roots still fail closed. The encoded maximum grows
by one 40-byte root and remains below the existing 64-KiB metadata limit.
These adapters remain disabled in application mode selection.

## File-owned encrypted reclamation

`ManagedIdentityStore.reclaim` now checks separately persisted content and
maintenance growth budgets inside the authenticated maintenance file. Explicit
force can repack both payload files. Plaintext stays on SQLite FULL auto-vacuum;
this API does not create encrypted side files or request a password for it.
The eligibility hints are not authorization state: missing means never repacked,
malformed records are preserved/refused, and new baselines are recorded only
after payload reattachment completes. Growth hysteresis uses a 64-MiB content floor and 8-MiB maintenance
growth allowance; substantial observed live-chunk deletion can also qualify a
large content file. A force operation on a small file may grow it slightly;
processed/repacked is not a claim that bytes were freed.

The file owner consumes the data adapter, closes its payload handles and retains
the identity lease and immutable keybox throughout native prepared compaction.
Staged paths must remain private siblings. The new content generation is accepted
only after durable PREPARED metadata; reattachment settles the actual authenticated
generation and checks the in-memory source head. Maintenance copies must retain
exact checkpoint and budget bytes. Failure keeps owned handles tracked for close
retry, and a refused operation can still have advanced maintenance state.
Ordinary I/O and close cannot cross a pending reclamation operation.

A source-replay regression found an important defect in the first maintenance
candidate: generation/role checks alone accepted an old, valid content image
restored in place after source-close. A controlled negative run returned the old
fixture value while its host-anchor verdict was clean. The implementation now
commits a fresh 32-byte source seal in the same native authenticated state before
closing content and requires its exact value in the staged copy. A replayed image
cannot supply that seal. Reattachment cannot expose a source behind the verified
head. Removing just the seal comparison reproduced the old-value/clean-anchor
failure; restoring it passed. The seal is a snapshot witness, not an encryption
key or a new cipher. Application writes cannot access its reserved namespace.

A successful content repack advances the logical head by two maintenance commits:
the source seal and the new generation. Abort before publication retains the seal
commit; it never resets the logical counter. Previous in-range host roots remain
recognizable and exported outer/biometric keys and keybox bytes remain unchanged.
Seven native file-owner cases cover real growth/deletion/shrink, exact records,
key/password cold reopen, sibling isolation, pending-operation exclusion, refusal
at publication stages, plaintext behavior and in-place replay. The first small-
churn shrink oracle was rejected: native slot reuse already bounded that workload,
and forced repack added metadata. The qualified shrink fixture grows a real live
log, deletes it and verifies actual file-size reduction.

One further native case SIGKILLs five owned process groups: after source sealing/
close, after durable content preparation, after content publication, and before/
after maintenance publication. Fresh key-based opens preserve exact records,
immutable keybox bytes, the prior host anchor and the next durable write. The final
joint suite reports **192 PASS and one opt-in native skip**; that skipped native
roster case is also run explicitly. Focused analysis is clean. These are macOS
process-crash checks, not power-loss or native Android/Windows qualification.

The managed worker now schedules an eligibility check after 128 successfully
committed operations (including a single batch), after nonempty namespace
erasure, or after a successful scrub. This is a check against the size and
garbage budget above, not unconditional compaction every 128 writes. An explicit
`ManagedWorkerIdentity.reclaim` request uses the same serving queue; legacy
hidden workers reject it and never schedule this new maintenance.

Reclamation pauses the actual worker command subscription while native payload
handles are detached, retaining queued reads, writes and close in order until
reattachment. An already durable mutation gets its successful reply before the
automatic check; a later maintenance failure cannot turn it into a failed write.
Failure leaves a bounded warning, and an explicit request returns a bounded
typed error without native paths or details. A close timeout retains supervision
until the queued native close really completes. Ten gated worker cases cover
these queue, retry, warning and legacy boundaries. A native macOS worker case
uses a synthetic garbage-seeded encrypted content file, crosses the automatic
threshold, verifies actual file shrink, exact data, unchanged outer keys/keybox,
the prior host anchor and fresh key-based reopen. It is not a natural-history
growth benchmark or Android/Windows qualification.

With worker scheduling enabled, the joint storage/worker lifecycle suite reports
**203 PASS and one opt-in native skip**; that native roster case also passes
when run explicitly. Focused analysis reports no issues. The earlier file-owner
crash/replay checks remain in this joint run.

Mode-aware maintenance in the application UI remains to be wired. No automatic
legacy conversion or unknown-space sweep exists.
Abandoned native temporary copies after process death are preserved; their safe
recovery/accounting is a remaining boundary. New storage modes remain disabled in
the application; all-online routing, password rotation, erase/recovery UI and
packaged/platform/biometric qualification still precede enabling the default.

## Application storage binding

`ManagedIdentityStorage` now binds the existing domain `Storage` facade to one
immutable catalog entry and its independently owned blob directory. The normal
domain-open path performs deletion/ratchet recovery, and the facade retains a
failed-close worker for retry. Credentials and keys pass through the managed
worker; KDF, native data operations and maintenance stay off the UI isolate.
The binding wipes its owned UTF-8 password buffer while preserving borrowed
roster/vault keys.

Creation is a separate explicit intent: an existing binding cannot create data,
and a creation binding cannot adopt an already occupied locator. Only an actual
authentication refusal returns `false` from the domain open method. Missing
files, invalid metadata and mode/ownership errors remain errors; no alternate
ID, hidden-container probe, plaintext fallback or replacement creation follows
them. After a successful creation the same facade reopens only that existing
identity. An interrupted creation still uses the separate explicit worker
resume API; the binding does not guess how to recover it.

Seven native macOS cases exercise this through the application's domain port:
both modes create and cold-reopen by key and password, failed credentials and
duplicate/wrong-mode/missing selections preserve files, and two simultaneously
open identities store distinct large files under the same logical file ID.
Erasing one leaves the sibling's blob bytes unchanged and readable after cold
reopen. This tests owned data erasure, not removal of a whole catalog entry or
power-loss secure deletion. Plaintext storage's existing large-file tier still
uses sealed pieces with their decryption keys in the plaintext database; this
provides no protection against filesystem readers and is not an encrypted mode.
The focused domain/lifecycle joint suite reports **99 PASS and one opt-in native
skip**; analysis of the new binding and native test is clean.

Production onboarding/defaults remain unchanged. Entry selection, persisted
locators, master rosters, all-online ownership, quick-unlock scoping and
mode-aware maintenance/erase/password-change UI must be wired consistently
before switching the application to this binding. Historical `StorageMode.plain`
is still a legacy preference and never selects the new plaintext backend.

## Roster locations and mixed online hosting

`IdentityStorageLocator` now makes the location explicit in a master's stored
roster. A legacy locator names only the profile's historical container; it has
no hidden-space ID or enumeration. A managed locator contains only the opaque
local ID and protection mode. It never carries a filesystem path, network
address, password or keys. Missing location fields in historical roster rows
retain their legacy meaning and stored bytes. An explicit malformed/unknown
location throws a bounded error instead of becoming an absent roster or a
legacy child. Roster copies and anonymity edits preserve the location.

The boot planner validates all rows before opening any: labels, legacy keys
and managed IDs cannot be duplicated, and keys must have the native 64-byte
shape. In particular the same managed ID cannot acquire owners in two modes.
An unconfigured managed opener refuses the entire plan before touching the
legacy container. The planner snapshots all borrowed keys before the first
await and wipes those copies after planning, so a concurrent lock or roster
edit cannot change a later selection. The in-memory multi-space fixture now
copies its admitted keys too; retaining and then wiping the caller's buffer
would be a false native model.

`MultiIdentitySession` hosts legacy children over its shared native backing
and managed children over independent workers. The standard builder supplies
the profile directory explicitly. Storage is retained before awaiting its
managed open, and native post-unlock cleanup goes to the correct owner.
Disposal waits for in-flight preparation within its budget, stops further
boots, and retains a failed managed close for another attempt. The application
controller also retains unpublished/unreleased sessions after clearing UI
providers and drains them before a new unlock/creation/selection.

Two pre-fix tests reproduced duplicate labels passing the planner and a failed
session close being forgotten by the controller. Gated tests additionally
exercise a late managed open, disposal retry, immutable selection and refusal
to route a managed locator through a legacy-only host. A native macOS case
persists and cold-loads a mixed master roster, hosts one legacy, encrypted and
plaintext child, injects an accepted message through each real messaging
pipeline, verifies exact isolated histories, then closes and independently
key-reopens all three native stores. Its transports/node boots are local
fixtures, not a real network or mobile/desktop GUI qualification.

Before the close-protocol follow-up, the sequential storage/controller suite
reported **449 PASS and one
opt-in native skip**. A separate native-roster/controller run reports **31
PASS with no skips**, including the skipped native case and the additional
guard against probing managed credentials during legacy attestation cleanup.
Analysis is clean. The first parallel joint attempt had three child-process
failures during shared Dart SQLite asset-hook preparation, including a reported
copy error; that attempt is not counted as a successful qualification. Asset
hashes matched before the sequential repeat. Use `--concurrency=1` for this
suite while the child `dart run` hooks share their output paths.

The follow-up `WorkerMultiSpaceBacking` close audit is now implemented. The I/O
admission flag is separate from confirmed release. Concurrent callers and
timeout retries join one close attempt, including startup still in flight.
An error reply retains a close-only serving worker and its death supervision;
a later attempt actually reaches the same backing. A late error is still an
error, and worker death remains terminal on repeated close. Only the correct
multi-space success reply with a null close payload confirms release; foreign
protocol objects, bare values and other success payloads are refused. Test
fixtures now use their respective real protocol acknowledgements instead of
the old non-null/bare-boolean stand-ins.

Thirteen gated protocol cases cover refusal/retry, concurrency, timeout and late
error, malformed/foreign acknowledgements, death, bootstrap rollback, no-spawn
close, and the production serving loop with a failed-close backing. The initial
eight cases all failed against the pre-fix behavior. A native case separately
checks an explicit bootstrap refusal on an absent file: no backing was created,
so normal and repeated close succeed without manufacturing files. This explicit
refusal differs from an unwitnessed bootstrap death/failure, which cannot prove
release.

There is a second boundary below retryable worker protocols. The pinned native
bindings mark a handle closed and detach its finalizer **before** calling their
consuming native free. After a free error the next wrapper call would be a no-op,
not a release witness. Both native app adapters now use `NativeHandleClose` to
preserve that terminal error and original stack instead of reporting success or
attempting a possible double-free. Two deterministic tests cover consuming-error
retention and successful idempotence. These are callback/adapter contract tests;
actual native free failure or panic is not injected or claimed qualified. Healthy
native release and cold reopen remain covered by the file and mixed-session cases.

With the close follow-up, the sequential storage/controller/native suite reports
**466 PASS and one opt-in native skip**. Focused worker/adapter/lifecycle checks
report **47 PASS**, and analysis is clean. The separate native-roster/controller
run reports **31 PASS with no skips**, including the opt-in native case.
These checks retain the distinction
between retryable protocol errors, terminal unwitnessed death and a consuming
native free error; none of them is relabeled as successful resource release.

Single-active locator routing, durable active selection, vault scoping and
mode-aware UI remain required before enabling the new application default.

## Initial application wiring (QA only)

`ProfileStorageRouter` owns immutable storage facades and the public catalog
actor. A transition joins accepted native preparation and confirms closure of
its predecessor before publishing another facade. Failed closes remain owned
and block same-profile reopening until release is confirmed. A late write keeps
its original facade; selection never retargets it into another identity.

The QA onboarding presents all three modes, initially choosing encrypted. Plain
storage explicitly warns that messages, files and identity keys are readable by
anyone who can read the app's files. It skips the password step and offers an
explicit **Open** action on restart. Historical `StorageMode.plain` retains its
old meaning and is not reinterpreted as unencrypted data.

The lock screen can choose a visible opaque ID plus mode, or the legacy hidden
container. The latter is always offered, without probing whether hidden spaces
exist. Only an authenticated selection of a visible identity is remembered in
catalog v2; unselected catalogs retain their exact v1 encoding. A catalog with
visible entries and no remembered selection requires an explicit choice. Lost
soft onboarding preferences cannot hide this catalog and restart onboarding
silently. No names, credentials or hidden-space locators enter it.

OS quick-entry namespaces include the managed root, local ID and mode. Legacy
namespace bytes remain identical to installed versions. A biometric result from
a prior selection cannot open the newly chosen store. These are host tests of
scope/lifecycle behavior, not a physical biometric qualification.

Host tests now drive actual application onboarding and cold unlock against both
native managed backends, with network boot replaced by a no-op node. They prove
backend selection, profile persistence, wrong-password refusal, isolation of
legacy preferences and startup with lost preferences. An incomplete managed
profile refuses session boot rather than silently minting a new network
identity. This does not yet cover interruption after profile publication but
before all onboarding credentials have settled.

One-active selection and non-destructive master edits now follow explicit roster
locators: switching, anonymity changes, bind and unbind. The master access
locator remains stable while its children are opened. Binding a visible identity
requires its explicit ID/mode; password guessing across public entries is never
used. The dialog warns when an unencrypted master would expose linked keys.

A host-native round covers all three master modes with mixed hidden/encrypted/
unencrypted children, exact per-child data, on-disk roster preservation and cold
reopen. An additional encrypted-master round hosts all three simultaneously with
fake network boots. Rejected edits restore all-online hosting, rather than
silently leaving only the active child online. These are storage/controller
checks, not real-network or packaged-platform qualification.

A baseline comparison confirms that one-active selection previously used the
legacy facade for a managed child's keys. A separately injected cancellation at
facade construction confirms provider publication even after its caller loses
lifecycle authority; it is not attribution to a historical user incident.

New identity/master creation now routes each role before opening it. The form
initially selects encrypted storage for both. Plaintext modes omit passwords;
hidden mode uses the historical container without a public hidden-space entry.
Converting a single identity retains its original locator and data as a child.
Appending re-reads the master's durable roster, retains every current row and
compares the supplied credential's keys with the already authenticated master.
A password for another hidden master cannot redirect the write there.

Child creation keeps the prior access locator. The opened new master becomes
the remembered root only after roster publication and catalog confirmation.
An access-session password recognizer is kept only in RAM and explicitly
restored after an authorized child-view switch. Rebuilding an unrelated storage
provider does not inherit it. It is consumed on session end/disposal, without
retaining the original password. The screen can therefore lock after managed
creation and master switching as well as after a cold unlock.
A hidden-to-hidden conversion clears the opted-in old quick-entry wrapper,
which otherwise opens the former child in the same legacy namespace. Other
visible namespaces retain their own saved entries. Pending master setup is
marked inside the protected store and cannot boot as an ordinary identity in
single-active or all-online mode. Matching an existing hidden identity's
password refuses creation without overwriting it. The two passwords supplied
for a protected new child and master must differ; no global password registry
or probe of unknown hidden spaces is introduced.

Host-native tests cover creation, append and cold reopen across all three
storage modes, hidden-password collisions, a foreign-master credential, stable
source data and keys, and adding a child while all identities are hosted with
fake network boots. An opened-root/catalog-refusal test checks access publication.
These tests do not qualify power loss between creating an unbound child and
committing its master roster: already published files remain owned/preserved,
and interrupted-creation discovery/resume still needs implementation.

During staging, mixed-master decoy creation and legacy whole-profile
compaction/wipe remain refused before writes when visible catalog entries exist.
Managed settings show automatic owned reclamation instead of legacy
unknown-space maintenance. These temporary restrictions are reasons to keep the
QA switch off in production, not a completed mode-aware management feature.

The active visible identity now reports logical file lengths from its owned
directory, including its database/keybox, role metadata and large-file pieces.
The shared catalog, sibling identities and legacy container are excluded. The
measurement runs on the storage worker and joins accepted blob writes before
walking the tree; queued KV requests, reclamation and close wait for it. A
timed-out close retains its owner until the inventory and queued release finish.
All-online settings use the active child's facade, not the closed master root.

Enumeration streams entries with bounded traversal depth and no symlink
following. Unsafe/replaced paths or missing required files fail the measurement
instead of returning a partial size or zero. Unknown safe files and empty
directories are counted separately, without making them cleanup candidates.
These are logical lengths measured per file, not an atomic filesystem snapshot,
allocated blocks, reclaimable-space estimates or a secure-erasure promise.
Native tests exercise both protection modes, actual encrypted blob pieces,
sibling/legacy exclusion, unsafe paths and recovery after a failed inventory.
Gate-based tests cover ordering with accepted file writes, KV operations and
close, including a caller's close timeout.

The worker/file layer now provides explicit whole-identity erasure for visible
stores. It reserves the immutable local ID, acquires the exact role lease and
preflights the entire owned tree. A public catalog entry alone never authorizes
private-payload deletion. Encrypted erasure authenticates the ID-bound keybox
without opening possibly damaged content/maintenance files; plaintext erasure
requires explicit mode selection and checks any supplied roster keys. A live
data owner, mismatched mode, unknown entry or symlink refuses the operation.
Fresh IDs identify one creation and must never be reused for another identity.

Payload handles close before unlinking names, while the role lease stays held.
Blob pieces and content are removed before the final keybox (or plaintext data
file), with directory synchronization at publication boundaries. Catalog
removal clears only that identity's selection and precedes releasing the lease.
Ordinary listed openers recheck catalog membership after acquiring their lease,
so an old enumeration cannot reopen payloads after deletion. Remaining public
role files and empty directories are removed nonrecursively. Even a zero-byte
payload file prevents unauthenticated metadata-only cleanup. A metadata-only
tail, or an already absent directory, can be finalized by an explicit retry;
these are not claims of successful password authentication. Unknown creation
staging directories are retained and refuse erasure until separately recovered.

Requests snapshot borrowed credentials, erase their owned copies on completion,
and preserve FIFO ordering with catalog operations and close. Failed native
closes remain owned; the consuming catalog/lease connection releases have their
own guards instead of caching errors around the entire retryable protocol.
These are logical deletions, not forensic erasure or power-loss guarantees.
Host-native tests include credential refusal without file changes, another live
owner, stale catalog admission, all deletion checkpoints, forced process death,
sibling/legacy byte preservation, idempotent retry and queued worker close.

Application management now journals deletion inside the authenticated master
before invoking the kernel. The intent contains an immutable target locator
and keys, bound to the access root and a digest of the master's own keys. It
contains no display name and never enters the public catalog or preferences.
Two legacy masters share a locator but have different keys; copying an intent
between them refuses. Self/master and last-child deletion refuse before writes.

The app stops hosted children before erasure. It keeps an independent parent
open for visible-child removal, or closes/reopens the same parent while erasing
a legacy space in its shared container. After erasure it reloads the current
roster and removes only the exact locator/key reference, preserving unrelated
rows and labels reused by a new identity. The new roster is durable before the
intent is cleared. Lost write replies or process death at either boundary leave
an idempotent recovery obligation. A cold authenticated master unlock completes
it before all-online boot planning or presenting its children.

Cancellation fences accepted operations to the same parent/target; they cannot
publish a ready session after lock. Late roster buffers are adopted before the
cancellation check and retired if no session keeps them. A pending intent with
an absent/empty roster or unavailable recovery route cannot boot as an ordinary
identity. After authenticated erasure fails, a dedicated recovery phase closes
the parent and keeps its authorized keys/roster only in RAM, like the identity
picker. It pins navigation to a recovery screen and blocks ordinary identity
leases, child selection, roster edits and another sign-in. No child boots from
a cached roster that may name already erased data. Unauthenticated open failures
still use the ordinary locked/error path.

Recovery offers retry, the existing allowlisted diagnostic report and lock.
Retry is serialized, reopens the same parent and resumes its durable intent.
Deletion and recovery entry synchronously stop global recording/playback
controllers and invalidate pending media-permission responses before the view
changes. Stopping nodes alone does not stop those independent controllers.
If the initial intent write failed, the original authorized target can be kept
in RAM for an explicit retry; no automatic deletion is promised after locking
when that intent never reached storage. Lock remains available during retry,
destroys temporary authority and prevents late work from publishing a session.
A later authenticated unlock resumes any durable intent. Retry success restores
the prior active identity/hosting policy when available. The RU/EN/ES recovery
screen is exercised at a narrow viewport with large text.

Ordinary retry still preserves unrecognized entries. A separate review button
can authenticate the journaled managed target and report counts/size of its
unrecognized regular files and directories. Review is read-only, releases the
role lease before showing confirmation, and returns no paths or credentials to
the UI. Confirmation explicitly authorizes irreversible deletion of those
entries together with the selected identity; cancel performs no deletion.

The storage actor keeps at most eight opaque, single-attempt consents for ten
monotonic minutes. Each binds the exact immutable ID/mode, authenticated keys,
root/ancestor object witnesses and the complete unknown-entry manifest (names,
type, object identity, file length and modification time). A newer review of
the same target invalidates the old one. Confirmation reacquires the role lease,
authenticates again and compares a full fresh manifest before its first
mutation. A changed directory or restarted actor requires another review.
The parent deletion intent is durable before any confirmed removal, including
when the original intent write had failed. Lock cannot publish a late session;
it also prevents initiating a new confirmation without fresh authentication.

Reviewed entries are removed deepest-first with repeated no-follow witnesses
and nonrecursive directory deletion. New/unreviewed entries are never swept;
errors retain the parent intent for another review/retry. This is not a
transactional rollback of already approved removals or hostile same-user ABA
protection. Review is bounded to 4096 unknown entries / 2 MiB of manifest and
refuses an oversized set in full. Normal owned-data inventory/erasure stays
streamed. Symlinks, unsafe paths, ambiguous staging, missing role and lost
encrypted keybox refuse review; catalog membership alone never authorizes
removing private payload. Metadata-only ordinary deletion tails remain
retryable without inventing credentials. Export/recovery of unknown content
is not provided by this destructive confirmation. Host-native process tests
SIGKILL the lease owner after the first approved unlink/directory sync in both
managed modes; remaining files require a fresh review, siblings and legacy data
remain byte-identical. This qualifies process interruption, not power loss.
Absent-target review preserves its catalog reference; a confirmation against an
absent catalog refuses rather than reporting a successful reviewed deletion.

Host-native application cases cover all three master modes, visible and legacy
child removal, single-active and all-online restoration, cold intent-only /
child-removed / roster-published states, and last-child preservation. A gated
native response checks lock after child removal and before roster publication,
including retirement of late key buffers and successful subsequent unlock.
Separate native processes exercise SIGKILL after intent persistence, child
removal, roster publication and intent clear for encrypted and plaintext parents.
These do not qualify packaged platform behavior or filesystem power loss.

### Mixed-storage duress masters (QA)

A duress master is always a hidden space, even when its authenticated parent or
selected children use enumerable storage. Creation retains the original access
root and public catalog selection; its exact selected rows/keys/locators and
anonymity flags are written only inside the hidden space. The input selection
is snapshotted before the first await. Before copying, creation reopens the
actual parent by its cached keys and compares the fresh durable roster with the
authorized snapshot. A changed/unfinished parent refuses and locks rather than
booting a stale roster or silently widening the selected set.

The operation stops capture/playback and every hosted identity before changing
facades. It checks password collisions only against the already authorized
parent/roster: known encrypted stores may be opened read-only with the supplied
candidate password, but no public-catalog sweep or unrelated hidden-password
probe is performed. Existing profiles, rosters, node configuration, sovereign
credentials, unreadable records and pending setup/erasure markers refuse
replacement. Hidden one-space auto-compaction is disabled in known shared
spaces before another hidden root is published; a refusal stops creation.

A protected setup marker precedes the duress roster and is cleared only after
its durable save. The target closes before success, and the original active
view/hosting policy is restored. A failed restore/close never reports successful
creation; a durable duress roster may already exist after a lost reply or
restore failure, and a retry cannot overwrite it. Lock/dispose fences late
work and retires temporary keys. Host-native fixtures cover all three parent
modes, single-active/all-online, managed-only sources with no pre-existing
hidden container, exact cold selected-roster access, stale parent and collision
refusal, native accepted open/marker/save/close cancellation, and disposal.
These fixtures use fake network nodes/recorders and do not qualify packaged
platform media or OS-vault behavior.

The UI explains that entry uses the always-available hidden-storage selector.
Enumerable identities remain in the catalog; a plaintext master still exposes
all linked keys. Duress is not a promise to hide those public/plaintext facts.
Explanations open on demand, with narrow/large-text RU/EN/ES widget checks.

### Manual reclamation of the active enumerable identity

An optional `OwnedStorageReclamation` capability connects the authenticated
managed worker to the active storage facade. Settings exposes an explicit
reclaim action for that identity; a password list is unnecessary because its
outer keys remain stable and no other root is enumerated. Encrypted stores
use their existing prepared content/maintenance repack; plaintext remains on
SQLite FULL auto-vacuum and never invokes the encrypted compactor.

The facade queues reclamation behind accepted file publications. Close and erase
drain the same gate, retaining the exact owner until the operation settles. The
worker independently serializes its native detached-payload interval with reads,
writes and close. Controller maintenance excludes overlapping creation, edits,
selection, unlock and other compaction; wipe joins accepted maintenance. Lock and
dispose invalidate late success without reopening anything. Other hosted roots
stay online; the UI disables repeated taps, refreshes usage after success and
shows a generic failure without exporting backend text.

Host-native application checks exercise encrypted/plaintext standalone roots
and active managed children under hidden, encrypted and plaintext masters,
including all-online hosting. They compare outer keys, facade/session identity,
catalog bytes, retained data and cold access. Gated port/controller checks cover
accepted file publication, close after success/refusal, retry, overlapping work,
lock/dispose and legacy refusal. Two pre-fix gated cases reproduced maintenance
being admitted during hosted identity activation (whose phase remains ready);
both collection and independent maintenance now check the live selection count.
Narrow, large-text RU/EN/ES widget cases exercise
busy, success, failure and route disposal. These are synthetic host fixtures,
not packaged platform or real-network qualification.

This does not enable shared hidden-container compaction when enumerable entries
exist. That path still requires a durable cross-root key-remapping protocol;
manual password rotation, migration and whole-profile erase remain separate
unfinished work. The managed-storage default switch remains off.

### Profile lifetime coordination for destructive maintenance

A complete managed-root bootstrap now publishes `profile.meta` and its permanent
empty lock sidecar together with the catalog, in the same no-replace directory
publication. The role contains only a fixed format identifier, no identity
locator, key or hidden-space fact. Previous QA roots missing this metadata are
preserved and refused rather than silently upgraded. Migration remains explicit;
this layout is still behind the disabled application feature switch.

Every `ManagedDirectoryCatalog` owner retains a shared `ManagedProfileLease`,
including the catalog actor and each independently opened data worker. Normal
catalog writes use their separate database and remain possible with these
readers. `openExclusiveMaintenance` admits an existing root only after all shared
owners have actually released; it creates nothing and never waits in a retry
queue. `requireExclusiveMaintenance` also refuses an owner with live identities.
Neither method by itself deletes data or grants authorization to erase it.

SQLite read transactions acquire their shared lock through an actual validated
role read. POSIX also uses handle-bound `flock` on a separate inode: an unrelated
file descriptor close must not release ownership, and BSD flock/fcntl interaction
must not downgrade a writer on the metadata database. Windows uses SQLite's
handle-bound locks. Normal identity-exclusive leases retain their existing
behavior. Paths and role/sidecar object witnesses are checked before catalog use;
foreign roles, missing metadata, links and changed objects refuse without repair.
Catalog/native cleanup precedes release of the profile lease.

Host checks exercise shared/exclusive contention within and across isolates,
normal writes by multiple catalog owners, role corruption, unrelated file
closes and bootstrap publication. A persistent independent Dart process checks
reader/writer exclusion and actual SIGKILL release for both shared catalog and
exclusive maintenance owners. Native encrypted/plaintext data-worker and catalog
actor cases retain ownership until confirmed close. These are macOS fixtures;
Windows and mobile filesystem/runtime behavior are not physically qualified.

A permanent `storage-lifetime` directory at the profile level now extends this
barrier to unpublished and absent managed roots. Its permanent role files hold
only a different fixed tag and an empty lock sidecar, with no catalog, identity
count, locator, credential or hidden-space fact. The separate erasure intent
below may temporarily retain the public catalog. The constant role must remain
when user data is erased, so a new creator cannot bypass an old exclusive owner
by replacing the lock inode. Explicit profile/catalog-worker initialization
creates it even when there are no managed identities. Read-only absent-root
probes still create nothing.

Root creators take parent shared admission before any identities staging. All
published-root owners retain that admission, and a live catalog worker retains
its own parent reader even with no root present. Acquisition order is parent,
root, then identity; confirmed identity/catalog cleanup precedes releasing those
leases in reverse order. A parent exclusive owner can therefore exclude new
creators while the managed root is absent or after its removal. Root maintenance
requires both parent and root exclusive admission. Contention refuses without
an implicit delayed writer.

The permanent role is initialized privately and published without replacement.
A losing parent bootstrap refuses rather than adopting the winner and continuing
an older initialization across somebody else's maintenance. Only exact owned
unpublished files may be cleaned up; unknown pending directories are retained.
This differs deliberately from losing managed-root publication: those creators
already hold parent readers, which exclude a simultaneous wipe.

Host checks additionally cover independent shared/exclusive parent owners,
absent-root catalog workers, creators paused before root publication, permanent
role preservation after synthetic root removal, and actual SIGKILL before/after
publication of both directory levels. Corrupt/swapped roles, links, nonempty
locks, replaced paths and foreign staging content refuse without repair. These
are synthetic macOS process/filesystem fixtures, not a production wipe or
mobile/Windows qualification.

This remains a coordination primitive, not whole-profile erasure. Application
startup recovery with a partially removed catalog, complete owned-entry cleanup
and OS-vault integration remain required. The destructive
action and new storage default stay off.

### Durable intent before managed-root removal

`ManagedRootErasure.prepare` is now an actor-side prerequisite for the future
whole-profile wipe. Under exclusive parent/root admission it validates catalog
membership, every identity's public role and recognized no-follow inventory.
Unknown content, incomplete stores or unconfirmed resource close refuse without
publishing. It records a bounded exact manifest (32,768 entries / 8 MiB), file
object witnesses, sizes/modified stamps, profile/coordinator binding and the
public catalog. Format v2 also requires immutable hashed OS-vault scope names,
recorded before any deletion rather than derived from a catalog that may later
be gone. It reads no encrypted payload, password or hidden-space roster.
Oversized plans refuse rather than approving a truncated inventory. Earlier
unreleased v1 QA plans are preserved/refused, not silently upgraded.

The immutable plan is flushed in a private staging directory and published
without replacement as `storage-lifetime/erasure-pending/plan.json`. No payload
removal precedes durable publication. Once any object occupies the pending name,
ordinary profile admission, catalog workers and root creation refuse, including
when the managed root is already absent. Malformed/linked intent is a refusal,
not permission to initialize an empty catalog. An unpublished plan is retained
only on crash; normal failure cleans only its exact owned staging files.

`openPending` acquires the permanent exclusive parent independently of a
surviving catalog, inner lease or payload. It rechecks the bounded plan and its
binding; copied plans, traversal, object replacement, changed files and unexpected
entries refuse before removal. The required scope-retirement callback must
verify OS-vault absence (including accepted enrollment) before any planned
unlink. Callback failure preserves all managed payloads; retries repeat it.
This callback is only a contract here, not a claim that actual platform scopes
are already integrated or verified.

Removal retains exclusive parent ownership, closes no unrelated handle, checks
ancestors/objects before each unlink and never recursively sweeps foreign
entries. Missing planned entries permit restart after partial removal. The
public identity list and exact hashed vault scope names remain readable in the
intent even after catalog removal, so scope cleanup does not depend on a
surviving catalog or later preference/path reconstruction. A newly inserted
file is preserved and prevents nonrecursive parent removal. Reentrant cleanup
and close while the accepted callback is running refuse.

Host fixtures exercise plain/encrypted payloads, ciphertext blobs, scope refusal,
mutation/path/schema/bounds controls, publication failures and independent writer
SIGKILL before/after intent publication, after catalog unlink and after root
unlink. A guard-disabled negative control fails all three ordinary-admission
tests; it is a compiled mutation control, not a historical production defect
reproduction. The first test run's one failure was an overly narrow busy-error
matcher (SQLite busy is also a valid exclusion), corrected before qualification.

The broad 49-file run passed 317 cases. Two later red filesystem-failure cases
showed raw paths escaping from publication/removal errors; these are now wrapped
as bounded `ManagedFsFailure(io)`, retaining the original stack without native
message/path fields. The whole new admission/removal/crash files are requalified
after that change; broad results are not presented as one final-source green run.

The intent intentionally remains after all managed files disappear: this port
does not yet finalize a full-profile wipe or expose one to the UI. Integration
must first cover the legacy container/blobs, every known OS scope and pending
enrollment, preferences, interrupted startup and explicit recovery reporting.
Unknown/orphan staging content needs owned review; it is not swept by this
manifest. Actual packaged mobile/Windows behavior, power loss and real OS-vault
cleanup remain unqualified. Whole-profile erasure and the new default stay off.

### Shared scope queues and owned OS-vault retirement

Two deterministic tests exposed a pre-existing wrapper-lifetime race: a new
`QuickUnlockVault` for the same store/scope completed forget or reconfiguration
while an old wrapper still had an accepted protected write outstanding. Releasing
that write could recreate a saved password after verified absence or leave an
older protected slot. Both tests were red on the preceding code; the unrelated
scope/backend control already passed.

Generation cancellation and serialization now belong to the same backend
instance/scope across wrapper recreation. Weak scope-state entries retain no
obsolete scope after wrappers and accepted jobs disappear. Existing ordinary
forget still permits a later explicit configuration; separate scopes/backends
remain independent. This is coordination in the owning UI isolate, not a claim
about unrelated plugin isolates or arbitrary wrappers for the same OS service.
The production provider reuses its existing constant store instance.

`StorageUnlockScopes.forProfile` derives one legacy-container scope plus every
public local identity/mode scope using the existing exact namespace function.
It never discovers hidden spaces or scans all OS keys. The immutable set refuses
empty, duplicated, malformed and oversized input (maximum 129 for 128 public
identities plus the legacy container), snapshots borrowed input and contains no
paths, passwords or network identity. Native fixtures supply/restore these
names through the v2 erasure plan, including after catalog/root removal.

`QuickUnlockRetirement` is an actor-owned adapter for the required erasure
callback. It starts retirement of every recorded scope before its first await,
joins accepted old enrollment through the shared queues, verifies removal and
waits for all scopes even when one refuses. It reports a bounded failure without
backend messages or scope names. Retry retains unreadable cleanup metadata and
repeats actual absence verification; opt-in flags do not witness absence.
Old/live wrappers for retired scopes cannot re-enroll or release passwords.
The enclosing wipe must retain this retirement owner until finalization; normal
fresh-profile reopening remains part of that unfinished protocol.

Tests use only in-memory OS ports/mocked platform channels. They cover late
writes, replacing wrappers, independent scopes/backends, partial refusal and
retry, malformed cleanup metadata, a retained unrelated identity, no OS reads
from sealed entry buttons, and the native file-removal callback preserving all
payloads until scope retirement succeeds. Four writer SIGKILL boundaries retain
the exact names without a surviving catalog. No developer Keychain/Keystore or
real profile was accessed. This does not yet qualify real platform retirement,
wire a full-profile wipe in AppController, handle all legacy payloads or retire
the journal's final phase. The destructive guard/default remain off.

The wider 60-file qualification passed 420 cases and exposed one obsolete
selection fixture that still expected a completely empty profile. It now checks
only constant role metadata (including unchanged bytes), no identities/catalog,
and successful explicit later creation. That whole selection file and the new
scope/retirement/removal/crash files are requalified after this fixture-only
change; the broad result is not represented as one green final-source run.

### Saved-entry cleanup before individual managed erasure

The inventory audit found a real application gap: managed target removal did
not retire its own OS quick-entry scope before removing the public catalog
reference. A later whole-profile wipe could therefore lose the name needed to
clean that entry. This is fixed at the existing authenticated erasure boundary,
not by scanning OS keys or changing the hidden-space namespace.

After validating the exact target role/keys and any unknown-entry consent, the
storage worker closes payload handles, retains the identity role/root leases
and requests a bounded UI-side admission. The application captures the target's
own namespace using the same factory as ordinary quick entry, verifies its
saved-record deletion and checks the original edit lifecycle before replying.
The current master/other identities and the global opt-in preference are not
removed. There is no OS side effect during read-only review, wrong-key attempts,
unapproved unknown content or invalid review tokens.

Refusal preserves payloads, approved unknown entries and catalog membership;
the existing authenticated parent journal remains retryable. Only success allows
file/catalog removal. This retains known scope discovery until verified cleanup,
including after restart or a metadata-only erasure retry. An absent-root retry
may retire the caller's explicit scope without creating a replacement catalog.

The private callback bridge sends only an operation reply capability and a
boolean acknowledgement, never paths, keys, plugin text or a new authorization
claim. It joins accepted UI work before releasing its local endpoint even if the
worker's RPC fails. Worker close/snapshots stay queued while admission is held;
no timeout turns an unacknowledged OS operation into permission to unlink.
The ordinary native authentication/consent gates remain authoritative.

Two application recovery cases are red with the old application wiring and
green with this callback. The initial fixture used the pre-normalized directory
spelling; it was corrected to the router's exact namespace and asserts that it
matches the ordinary parent provider. The corrected fixture was rerun against
the old wiring to confirm both failures again. Native encrypted/plaintext cases
cover wrong credentials, refusal/retry, retained sibling bytes, role contention,
queued close, read-only/forged consent and absence. Explicit managed cleanup
without its profile context refuses before OS access instead of inventing a
fallback namespace. All secret-store ports are in memory; real OS integration,
packaged platforms and whole-profile finalization are still unqualified.

The wider 64-file run passed 432 cases and found two lifecycle fixtures that
had not injected the newly required OS port. With an explicit in-memory store,
those original lock/late-roster-key assertions pass unchanged; the fixture also
checks that target cleanup actually used its port. A protocol-only supervised
peer is forcibly terminated after requesting UI admission: the production erase
facade still waits for the accepted cleanup, reports worker death, and does not
invent a successful close. This does not qualify native FFI death or a real OS
dialog. Headless import coverage stays Flutter-free. Requalification includes
the whole affected files, not a claim that the earlier broad run was green.

### OS quick-entry cleanup before whole-profile erasure

Whole-profile erasure with visible catalog entries is still refused pending
a recoverable deletion protocol built on the coordination described above. Its OS-credential
boundary is being qualified separately; this is not permission to recursively
remove the managed root or bypass per-identity erasure authentication.

The existing legacy wipe now verifies deletion of the selected OS quick-entry
scope even if its soft opt-in preference is absent or false. That flag controls
whether quick entry is offered; it cannot witness absence of a protected
password after preference loss or interrupted enrollment. Ordinary startup still
performs no OS-vault reads without explicit opt-in. Forgetting advances the
vault's generation and joins accepted enrollment before declaring absence.
Another scope's OS entries are not swept.

Removal/re-enrollment distinguish an absent record from unreadable, oversized or
unknown cleanup metadata. Unreadable data is retained and the operation refuses
without replacing the only potential pointer to a protected slot. A recognized
slot is retired even when its option flags are off. Failed OS access/deletion is
reported as unverified, while the existing best-effort wipe continues deleting
the owned container. These are synthetic port/controller checks, not a physical
Keychain/Keystore deletion qualification. Cleanup across every enumerable scope,
pending writes owned by retired vault objects, and profile-wide deletion remain
required before enabling the new storage default.

### Interrupted setup inspection and explicit continuation

An authenticated space without a profile no longer automatically boots a new
identity. Before compaction/network startup, an optional read-only capability
inspects every application namespace (KV and logs), accepting only canonical
bootstrap settings. A commit-sequence sandwich rejects writes crossing the
inspection. The encrypted backend verifies its private role metadata on the
owning worker; ordinary application reads still cannot access reserved tags.
Legacy config/credential-only identities remain supported without replacing
their existing cryptographic identity. Unknown data is preserved and refused.

An inspected blank space opens a pinned setup screen with an explicit choice
to run the usual certificate ceremony in that exact authenticated location.
The storage protection is fixed; another password/locator cannot redirect the
operation or create another catalog entry. A duress-master explanation points
back to the original master rather than silently creating an ordinary identity.
Lock/dispose retires cached authority; no ordinary views, edits, maintenance or
identity switching are allowed while this screen owns the session.

Creation refuses existing profiles and rosters as well as node credentials,
and keeps existing onboarding preferences on refusal. A protected, bounded
creation journal now records the exact submitted choices and a separate original
credential (up to the existing 16-KiB reader limit), inside the selected space.
Metadata is bounded to 128 KiB; a fresh native file pair fits the existing
atomic commit budget. A root locator AND a digest of the space keys bind the
journal, including multiple hidden spaces with the same legacy locator. No
password, key, phrase, journal pointer or hidden locator enters the public catalog.
The memory backend snapshots committed input bytes, matching native persistence.

A pending marker precedes journal publication. Stage 1 requires explicit
reauthentication and a fresh comparison of existing profile/config/credential
values before replay. Unknown namespaces/settings refuse it; inspection is
read-only even when a backend lends read buffers. Stage 2 records that payloads
are already durable and only boot remains: replay never calls the profile,
config or credential writers, and does not roll back newer durable state. All
creator/binder guards also reject this stage and unknown nonempty stages.

The recovery screen offers explicit completion in the same location, uses the
password only for that attempt (none for actual plaintext), blocks overlapping
attempts, and keeps lock/report available. Failures and lost replies expose the
recovery door immediately where readable; transient read failures preserve a
returning-user marker. Owned intent/credential/key buffers retire after every
outcome; lock and disposal prevent late activation. The existing offline-ready
behavior on node-start failure remains: stage 2 retains the original boot secret
until the real node starts. Retrying uses the authenticated journal rather than
an abandoned identity's one-shot RAM value.

Stage 0 is saved after successful boot (or the no-native loopback path), then
staged credential and metadata are retired in that order. Cleanup failures do
not revoke a completed identity; cold entry verifies the completed payload
before retrying cleanup, preserving a backup if the main credential disagrees.
Replay also preserves a changed/unreadable credential rather than overwriting
it with an older journal copy. This is not a downgrade of ratchet/authorization
floors or a promise to reconstruct unknown post-boot changes.

Host-native tests cover all three modes at five durable checkpoints, unchanged
keys/catalog, a full-size credential, conflict and cross-space refusal, lost
publication replies, write refusal, cleanup retry and lock during accepted
replay. Five independent writers are actually SIGKILLed (exit -9) before/after
atomic journal publication and after profile/credential/pre-boot publication;
cold entry preserves either explicit blank setup or the exact staged identity.
Decoder mutation/bounds and narrow large-text RU/EN/ES controls are checked.
These use synthetic credentials and fake network nodes: packaged platform and
real media/OS-vault qualification are still required.

Pre-journal partial payloads have no trustworthy original intent and remain
preserved without replacement. Pre-roster pending-master replay, unbound-child
recovery, whole-profile erase, manual mixed maintenance/password rotation where
applicable, explicit migration and packaged Android/Windows/macOS runs remain
before default activation. Existing containers are never converted automatically;
the managed-storage default switch remains off.

## Recoverable erasure finalization primitive

The managed-root erasure actor now has an explicit terminal phase. After the
managed root is absent, a **required enclosing verifier** must join accepted
jobs and verify all other profile files, legacy storage, preferences and OS
quick-entry scopes absent. This is a trusted integration contract, not a new
permission granted to ordinary startup. Actual whole-profile application
binding and the new default remain disabled until those obligations and the
remaining integration below are implemented and qualified.

Under the permanent exclusive coordinator, the actor atomically publishes a
private `erasure-complete.json` file without replacement and syncs its parent.
It contains bounded filesystem object witnesses and the immutable plan digest;
no catalog, scope roster, password or hidden-space locator. It then removes
only the exact plan, syncs the pending directory, removes that directory
nonrecursively, and finally unlinks the terminal file and syncs its parent.
Ordinary admission refuses either marker, including malformed files and links.
The exclusive grant is held until actual close, even after finalization.

Cold terminal recovery accepts the original plan, an empty original pending
directory, or its absence; foreign/replaced entries refuse cleanup. It does not
need a deleted catalog/scope list or repeat the already witnessed enclosing
verification. A final unlink followed by a failed parent sync retains the live
exclusive owner: retry confirms absence and syncs; close refuses until that
succeeds. A fully finished live owner accepts a lost-reply retry, while a closed
owner cannot finalize a later profile. In-memory phase events expose no paths.

Selected macOS host tests cover normal encrypted/plaintext roots, verifier and
publication refusals, all tail sync boundaries, stale owners, no-replace file
publication, malformed/bounded/cross-object metadata, links and late foreign
entries. Five **actual SIGKILL** boundaries cover before terminal publication,
after durable publication, after plan unlink, after pending-directory unlink,
and after synced terminal unlink. These complement the four existing intent /
managed-root deletion crash boundaries. The new-marker negative control failed
on the old coordinator (three terminal admission cases), while existing pending
cases passed; this is an integration guard for the new phase, not an attributed
released defect. These checks do not qualify power loss or packaged Android /
Windows, and do not implement legacy cleanup, startup recovery UI, migration
or the other outstanding three-mode application work. Saved-entry ownership
after finalization is qualified separately below.

## Saved-entry ownership after profile erasure

`QuickUnlockRetirement.forManagedErasure` captures the immutable intent's scope
set and an opaque binding while the plan is readable. A fresh saved-entry
lifetime requires **both** verified OS retirement and a `ManagedErasureRelease`
for that exact intent. The filesystem actor issues this receipt only after
terminal finalization and successful native coordinator close. A deleted root,
a pending final sync, another profile's receipt or a later erasure at the same
path cannot stand in for that release. Terminal recovery retains the original
binding even when the plan and its scope list have already been removed.
These are cooperating-application lifetime proofs, not cryptographic authority
against someone who can replace their own public metadata.

The handoff validates the complete set of shared backend/scope states before
changing any registry entry, with no intervening await. Accepted mutations must
have settled. It then permanently detaches the old states; it never un-retires
an old object. Repeated forget/configure/retirement through any old wrapper
cannot read, write or delete a fresh profile's credentials. Other scopes and
backend instances retain their existing ownership. The same OS store must still
use the canonical shared provider instance within the UI isolate.

`admitFreshStartupUnlock` applies this handoff and invalidates both cached vault
and cached options providers. A disposed provider owner cannot consume it.
Read-only options and biometric opens also recheck generation/retirement after
awaits: late metadata cannot revive buttons, start a post-clear biometric
prompt or return an old password. Three deterministic gated retirement cases
failed on the previous code. The same checks cover ordinary forget, which
remains explicitly re-enrollable outside permanent profile erasure.

Host-native tests combine actual managed-root removal/finalization/reopen with
an entirely fake OS vault, including wrong/replayed receipts, final-sync refusal,
terminal-only recovery, duplicate old owners, queued deletion, late reads and
provider replacement. No real Keychain/Keystore or identity is used. These
ports are ready for the full wipe binding; they do not themselves wire the
legacy file/preferences cleanup or pending-erasure startup UI. The owned
erasure worker and lost-reply reconciliation are qualified below. The managed destructive guard and new default remain disabled.

## Erasure when the enumerable root was never created

`ManagedRootErasure.prepareAbsent` requires the existing permanent profile
coordinator under an exclusive lifetime grant. It records absence without
creating an ordinary catalog, identity, payload file or enumerable root. The
same private no-replace publication path is used by both preparation variants.
Each current v5 plan retains the fresh 128-bit public operation nonce added in
v3. Its digest binds the final release proof even when successive empty-root plans otherwise
have identical contents and the filesystem reuses the old directory number.
The prior v2/v3/v4 layouts are rejected, rather than silently
upgraded or given fresh authorization. These unpublished feature formats have
no automatic compatibility migration.

The known saved-entry scope names remain durable even for a hidden-only profile;
no hidden roster, hidden credentials or hidden-container contents are inspected.

An empty `entries` inventory in the bounded v5 plan is valid only with an empty
public catalog. It means the root **must remain absent**, including after the
scope-retirement callback. A directory, regular file or link appearing there
refuses publication/recovery/removal and is preserved. Recovery still binds the
original profile/coordinator objects, blocks ordinary admission, repeats verified
OS retirement and requires the enclosing cleanup verifier before terminal
finalization and release. It does not treat missing managed files as proof that
the legacy container, preferences or OS vault are empty.

Focused host cases cover this contract, real role-file ownership,
unchanged role files, no root initialization, unreadable saved-entry metadata,
late foreign content, copied/malformed plans, publication failures and an actual
fresh saved-entry lifetime with a fake OS store. A deliberate omission of the
absence check makes three gate cases fail; this is a new-port integration
control, not attribution to a released defect. A second negative case models
ordinary directory-number reuse with real file I/O: the prior plan allowed an
old release to authorize the next empty-root operation. The nonce closes that
case; missing/invalid operation fields and the old format refuse intact.
Eight actual writer SIGKILL
boundaries cover before/after intent publication, after synthetic retirement,
and all five terminal checkpoints. Before publication no data is deleted and
unpublished staging remains for explicit ownership review. After publication,
recovery completes the journaled protocol without manufacturing a catalog.

The full wipe still needs application binding to the owned worker, cleanup of
the selected legacy files/preferences/auxiliary payloads and abandoned staging
with proved ownership,
router replacement, and explicit pending/terminal startup recovery. Manual mixed
maintenance/password rotation, master/unbound-child recovery, explicit migration
and packaged-platform/real OS-vault qualification also remain. The new default
and managed full-wipe application guard are unchanged.

## Owned erasure worker and lost-release reconciliation

`ManagedErasureWorker` uses the existing supervised storage-worker transport,
callback admission and confirmed-close protocol. Filesystem inventory and all
native role/cleanup work run on its worker isolate. A new operation derives the
complete saved-entry scope set from the actual catalog under exclusive admission;
the UI supplies the ordinary profile namespace and exact legacy-path spelling,
not a potentially stale catalog. Preparation, journal recovery and lost-release
reconciliation are explicit separate entry points, with no inline fallback.

`ManagedErasureSnapshot` is immutable public progress without native handles,
credentials or hidden-space pointers. It is deliberately not OS-retirement
authority. `QuickUnlockRetirement.forWorker` requires a live UI-side scope lease:
a retained old snapshot/lease cannot capture fresh OS state after the worker
starts finalizing, closes or dies. Terminal recovery has no fabricated empty
scope list; an existing UI lifetime retains its earlier retirement owner.

Accepted UI scope retirement and external verification remain owned until they
settle even if the worker dies. Closing waits for this work. Native close errors
and timeouts retain the owner; retries use the existing close attempt. If only
the already-authorized final unlink sync failed, a later close retries that sync
without rerunning external cleanup. A returned release also requires successful
worker close. Worker death alone is never declared native release; a later
explicit recovery must actually acquire its exclusive native role. Live failed
owners are drained before another bootstrap touches the profile.

A worker can finish unlinking the last marker and releasing its role, then die
before its receipt reaches the UI. Explicit `ManagedErasureReconciliation`
requires the original opaque binding, unchanged profile/coordinator objects,
absence of both markers and the enumerable root, and a fresh **read-only**
external absence verification under a new exclusive grant. It rechecks state
after that await, syncs the coordinator directory to confirm marker absence,
and actually closes before issuing the receipt. It creates no
catalog and never deletes a newly appearing legacy file or OS record. The
retained verified retirement owner can check known OS metadata absence without
new deletion. New data, a marker, another profile or a failed check refuses.

Host cases exercise actual encrypted/plaintext and absent-root inventories with
fake OS storage, callback refusal, closure during accepted UI work, terminal-only
recovery, late content, stale leases and final-sync failure. A gated actual worker
is killed only **after** native release is independently witnessed and **before**
its reply; explicit read-only reconciliation then recovers the exact binding and
fresh saved-entry lifetime. A refused reconciliation sync retains the native
owner and issues no receipt; retry requires verification and sync again.
Separate protocol-only death testing uses no native
handles. Compiled negative controls omit external re-verification (three failures),
the accepted-work close barrier (one), and stale-lease admission checks (two).
These qualify selected host boundaries, not arbitrary FFI abort cleanup or real
Keychain/Keystore interactions. The full application wipe/startup/router binding
and production activation remain unfinished and disabled.

## Router replacement ownership

The managed bootstrap now retains a `ProfileStorageRouterOwner`, rather than
capturing one immutable router in a provider override. Suspension immediately
makes the managed route unavailable; it never returns null to select the legacy
fallback. Provider observers are invalidated on suspension and publication,
without relying on a caller remembering to bump the selection revision.

The owner confirms the original router's close before admitting a replacement.
It retains failed closes for retry, coalesces pending operations, and closes an
unpublished candidate if suspension or disposal superseded its opener. A failed
close of that candidate remains owned too. Disposal owns the current lifetime,
not a closure accidentally bound to the first router. Normal native admission
still refuses a pending erasure; router replacement alone grants no fresh
OS-vault lifetime or authority to delete external data.

Host-native tests exercise provider replacement, actual exclusive-role admission
before and after close, refused closes, a held close barrier, late candidates,
pending erasure followed by actual final release, and wrong-profile refusal.
The complete AppController wipe and startup recovery binding remain unfinished;
production activation is still disabled.

## Startup while profile erasure is pending

Managed bootstrap now checks the two permanent-coordinator intent names before
constructing an ordinary router. The read-only hint creates neither a role nor
an identity, validates its parent objects, and treats any file, directory or
dangling link at either name as pending. Native admission repeats its own check
under the actual role grant; a publication after the initial hint is reported
as pending when the normal opener refuses it. Other managed initialization
failures cannot silently select the in-memory development store.

The main entrypoint presents a localized erasure-pending application outside the
ordinary provider/router tree, including in debug builds. It does not read saved
credentials, start networking, offer onboarding, delete remaining files or claim
completion. It is currently a refusal/status screen, not a completed recovery
workflow. The live AppController full wipe and durable cleanup of external
legacy/model/preference data still need binding before enabling these modes.

The legacy best-effort wipe is also refused for an empty managed catalog: absence
of visible entries does not imply absence of a hidden container. Normal legacy
development wiring remains unchanged. The accepted-operation join was examined
but not changed: its tracked completion futures already signal quiescence
independently of the operation result.

## Model writers during a profile wipe

The existing application wipe now seals a shared `ProfileModelWork` owner before
its first await and joins accepted model work before deleting files or consent
preferences. Cancellation alone is not a completion witness: an installer may
have passed its last cancellation check and still publish. Failed operations
also remain owned until their actual completion. These model-work completion
signals do not carry the operation's result or skip another accepted writer.

Speech download/import/removal, automatic preflight and consent persistence,
translation import/removal/export and interrupted-install recovery all use this
owner. The GitHub model sheet also registers its archive download, because its
cache lives inside the installed-model root. Per-resource lanes are claimed
before asynchronous inspection/root resolution; a second controller cannot
write into the same staging area while an old controller's job is still active.
Controller generations suppress stale callbacks across provider rebuilds.

Consent persistence is independently tracked: a completed or failed payload
does not leave retry waiting for unrelated preference I/O, while wipe still
joins that accepted preference write. After cleanup, fresh providers acquire a
new owner; the old owner remains permanently sealed. There is no timeout that
declares a still-running model writer quiescent. A stalled backend can therefore
delay wipe rather than recreate data after a successful report.

Deterministic fixtures reproduced real late file publication after the old wipe
returned. Other tests cover a translation import held before root resolution,
late automatic preflight, consent I/O, controller rebuilds, fresh post-wipe
downloads, and GitHub archive admission. They do not qualify real model hardware
or complete the still-pending managed full-wipe/external-inventory protocol.

## Durable inventory for profile-owned auxiliary files

The current unpublished intent format is v6; the terminal witness is v4 (see
application operation kind below). Explicit
`ProfileErasureAuxiliaryTargets` opt a profile into inventory of its opaque legacy
container, exact native rewrite temporaries, profile preferences and their atomic
write temporary, encrypted blob pieces, speech
model/partial/import files and translation pairs/imports/GitHub archive cache.
Artifact names come from a shared platform-free layout module; the public store
and bundle APIs retain their existing names and values.

The auxiliary base is derived from the owned managed profile's parent, not read
from the journal. Only the legacy leaf and fixed role choices are persisted.
The plan records object identities, file sizes and modification witnesses;
capture and retry reject links, changed objects, new recognized roots and unknown
children. Entries are removed deepest-first with non-recursive unlink and parent
sync. The 8 MiB/32,768-entry intent bounds apply to the combined inventory. The
speech model's parent is never recursively deleted: it also holds the container.
Unrelated profile files remain untouched. This retains the existing private-path
boundary, not a descriptor-relative guarantee against hostile same-user ABA.

Auxiliary removal is a separate supervised-worker command with required joined
OS-retirement admission. Native finalization independently requires auxiliary
absence before and after the enclosing verifier. The small terminal retains only
relative absence scope, no per-file inventory/catalog/OS-scope list or absolute
paths. That scope survives terminal-only recovery and is retained privately in
the opaque binding for read-only lost-reply reconciliation. A newly appearing
container or matching rewrite refuses recovery and is preserved, never adopted
as old deletion authority.

Release rechecks root and auxiliary absence before starting native close, covering
the gap after terminal finalization. A consuming-close retry continues only that
already-owned close; it does not acquire new filesystem or deletion authority.

Host tests cover worker restart, OS retirement refusal, changed content/objects,
unknown files, malformed manifests, terminal-only recovery and lost final reply.
Five actual SIGKILL boundaries cover partial auxiliary deletion and terminal
cleanup, including a replacement after plan removal. These qualify the native
inventory port. The live application preference/wipe binding is described below;
cold recovery and complete lifecycle/platform qualification remain required before
production activation. Optional auxiliary scope is not a substitute for that
full application contract.

## Durable preference absence during erasure

Every auxiliary scope now includes both fixed profile preference files. The
scope explicitly requires `preferences: true`; a missing, disabled or malformed
field is refused. These checks first landed in unpublished intent v5 and terminal
v3; current v6/v4 also require the explicit application operation kind below,
rather than silently expanding old deletion authority. The installation's
active-profile pointer and other profiles' preference files remain outside this
scope. Capture reads only filesystem witnesses, not preference contents.

Preference files and their temporaries are non-recursive leaves subject to the
same original-object/size/mtime checks as other auxiliary data. Added, changed,
linked or directory replacements are preserved on refusal. Their absence remains
part of terminal-only recovery, the final check before native release, and
read-only lost-reply reconciliation after the per-file inventory has gone.
The caller must retire and drain its preference owner before capture; the joined
retirement callback is repeated before unlink. This is not coordination with
uncooperative external writers or a hostile same-user filesystem attacker.

Host qualification includes actual queued preference writes followed by worker
erasure, retention of unrelated profile settings and the installation pointer,
new preference files at each finalization boundary, and SIGKILL after unlink of
the main preference file while its temporary remains. Complete managed-wipe
UI/recovery binding is still required; these native ports do not enable the new
storage modes.

## Profile preference lifetime

Application preference access now returns a view bound to the exact installed
backend. Retirement seals new reads/writes synchronously and joins accepted
saves, initialization and cache reloads. A late reference cannot adopt a newly
installed global backend. A fresh view waits for earlier accepted reloads before
refreshing the plugin's shared cache. Reinstalling a retired backend does not
revive it or bypass an intermediate lifetime's pending writes. A quiescent
in-memory backend needs no asynchronous retirement barrier.

The file backend independently seals direct mutations and drains queued atomic
writes. String-list inputs and returned lists no longer alias future file
snapshots. A failed initialization can be retried while the same lifetime remains
active; save failures are returned unchanged. These barriers prove settlement,
not successful persistence, deletion or OS-vault retirement.

Production access sites and the common provider use this entry point. Host tests
cover stale references, gated saves/reloads/initialization, failed saves, backend
replacement, retry and actual queued file writes. Full managed-wipe binding is
still pending: it must seal this owner before teardown, use the durable
preference-file absence scope and install a fresh backend only after complete
erasure release. This work does
not enable managed storage or turn the existing pending-erasure shell into full
recovery.

## Preference startup admission

Managed startup resolves the selected profile read-only, validates that a
container override remains beside its preferences, and opens a supervised file
actor before carrying the installation pointer or reading/migrating preferences.
The admitted support-directory answer is retained for the later container/router
bootstrap instead of resolving it again. That actor creates only the fixed shared
storage-profile role, not an enumerable identity catalog. The actor retains its native grant until confirmed close;
ordinary erasure cannot acquire an exclusive grant while it is live.

All managed preference reads and writes run beside that grant in the same actor.
Atomic file I/O is synchronous on the worker, so no detached async filesystem
rename can continue after it exits. The legacy asynchronous writer remains the
ordinary default and shares its existing permission checks through a pure file
module. A refused owned read/write never falls back to local I/O. Application
retirement joins accepted operations; `releaseFile` separately confirms native
close and remains retryable after refusal. Settlement alone cannot grant erase.

Each additional legacy-migration destination acquires its own file actor before
read/write and closes it afterwards. A refused destination is preserved and the
whole legacy source is retained. Pending erasure takes an early startup route
before normal providers/router/vault access; other managed admission failures
propagate instead of selecting ephemeral preferences. The early route is still
a refusal/status shell, not complete recovery. The legacy-source cleanup port
below is now available, but the complete wipe orchestrator still must bind it:
retaining a migration source is not proof that it was erased.

Qualification uses synthetic preferences, admitted/denied native writes,
selected/sibling pending plans, malformed intent markers, explicit native
contention in a separate process and confirmed release before re-admission.
Omission controls fail when either selected or sibling admission is bypassed.
No packaged OS vault or real application profile is qualified here. Managed
storage remains disabled pending complete wipe/recovery, migration, maintenance
and platform qualification.

## Retained legacy preference copies

Guarded installation retains the original platform backend in a private context,
including when startup stops at pending erasure. It does not reconstruct that
source from the current global file backend. Normal released/legacy startup
keeps its previous behavior. The shared legacy-key routing helpers are pure and
remain exported through the old preference API.

A separate namespace retirement requires a live whole-profile erasure worker,
the matching legacy scope tag, the matching physical profile parent and an
auxiliary scope that includes preferences. Root-only erasure, a closed worker
and another profile cannot authorize deletion. Only matching `flutter.` keys
are removed, with longest-known-profile suffix routing. The installation pointer
and other profiles' keys remain. An unreadable roster refuses cleanup rather
than treating every suffix as default-profile data.

Each removal needs an accepted platform acknowledgement and absence readback.
Failed removals remain retryable even when a false acknowledgement followed an
actual deletion; an empty observed map alone does not prove successful retirement.
Verification is read-only and refuses newly appearing data. Pending cleanup is
joined on worker close; explicit recovery captures a new live lease and rechecks
the source. A receipt for the exact current operation is required before the old
source lifetime detaches; an older operation cannot erase fresh source state.
The registry assumes the canonical backend instance and cooperating application
code. It does not coordinate unrelated plugins or old binaries writing that
platform store, or delete historical OS/cloud backups.

The host regression first reproduced preference resurrection after file erasure,
then repeated erasure and cold bootstrap with the original source retained: the
selected settings stayed absent and a blocked sibling remained intact. Other
cases cover named/dotted profiles, acknowledgement failure, refused reads,
interrupted cleanup, wrong scope and receipt, and read-only verification. Platform
preferences are synthetic in these tests; no actual system preference domain,
OS vault or real profile was erased. The live binding below now composes this
owner with vault retirement and native release. Cold-start recovery and broader
lifecycle/platform qualification still prevent managed-storage activation.

## Network teardown before destructive ownership

An empty session/stack provider is not proof that native shutdown completed.
The application now retains the original stack disposal, including unpublished
late-boot rollback, until its actual result is known. A second lock joins the
same operation. Failure and a consumed/detached native stop remain unconfirmed;
repeated checks cannot turn them into a successful teardown. The native-stop
outcome is captured for the original operation; a later mutable controller
status cannot retroactively authorize it.

All-online sessions retain node and messaging disposers and timed-out boot
reapers. Repeated disposal joins the accepted future instead of replaying a
potentially consumed native handle. The shared backing can still close after a
bounded wait, but the controller retains a session with unconfirmed network work
and refuses another storage acquisition. Eventual successful completion clears
the retained owner. An opaque failed disposer requires process restart rather
than an invented successful retry; independently retryable managed-storage
closes retain their existing behavior.

Regression qualification uses gated/failing fake node, transport and native-stop
outcomes through the actual application controller and session code. It does not
claim to have forced a real detached native thread or qualified platform service
shutdown. This repairs a prerequisite for the live binding below. Cold recovery
and broader lifecycle qualification remain incomplete; managed storage stays
disabled.

## Live full-profile wipe and fresh lifetimes

`AppController.wipeContainers` now dispatches a bound managed owner when its
real guarded preference source and router are available. Unbound/custom setups
still refuse instead of falling through to legacy best-effort deletion. The
controller seals ordinary lifecycle admission, ends the old generation, retires
accepted model work and pins navigation to a live retry screen. Failures keep
that boundary sealed; lock/start-over cannot escape it into ordinary storage.

The phrase-gated confirmation names all identity storage modes, settings, saved
sign-in and owned downloaded models in the selected profile. Legacy container-only
confirmation keeps its existing scope and wording.

The owner joins lifecycle teardown and accepted work, including an ordinary
unlock whose node is not published yet. Its final rollback/retirement is checked
again after that join; a late stop refusal prevents intent publication. The
owner checks runtime absence,
actually suspends/closes the router and releases the preference file role before
acquiring the native exclusive erasure worker. Vault and original platform-source
retirements start together and both must settle before native payload removal.
Native auxiliary scope always includes all known profile-owned model roots,
including stale models after a configured-root change; it never targets external
model overrides. Path aliases cannot cause the active configuration to omit
owned old files from this full-profile operation.

Finalization uses read-only external absence checks and the actual native release
receipt. Old vault/source wrappers stay sealed. A one-use source bootstrap is
bound to that released operation and its old global backend: it cannot reinstall
preferences again after a successful fresh handoff. The fresh installer uses the
original platform backend, not the retired file backend, and pins the selected
profile and legacy path. Only after fresh preferences/router admission succeeds
does the controller publish new model/settings lifetimes and onboarding. A
failed fresh-router open retries that stage without deleting newly appearing data.

Router facade retirement also synchronously rejects stale password/key openers.
An accepted late opener is joined and its actual handle closed before release;
ordinary session close remains reversible. Without this additional seal the
host control reopened an old hidden facade and recreated the deleted container.

Live retry now also observes erasure-worker death and resumes only its retained
exact binding. A new exclusive native grant either recovers that same immutable
pending inventory or reconciles an absent intent read-only. A different pending
operation, a newly created root or new auxiliary payload is preserved and
refused. Death is not treated as native release. Accepted UI cleanup remains
joined before replacement, and the original platform-source retirement is
rebound to the recovered live lease while other old wrappers stay sealed.

Terminal recovery uses the live operation's retained, previously verified OS and
source retirements; it never reconstructs a scope roster from an absent plan.
Every finish attempt independently rechecks external absence, including a retry
on the same worker after a failed final directory sync. A newly appearing OS or
platform-source record blocks the fresh handoff without being deleted. Deleted
biometric-slot addresses are retained only in the retired in-memory lifetime, so
this read-only check covers protected slots after their public metadata is gone;
no secret values or slot roster are added to the disk intent or terminal. Failed
adoption remains retryable with the same recovered owner. Native boundary tests
cover death during accepted source removal, four terminal-publication/removal
stages and loss of the released reply, plus new OS/source/file records.

Host qualification covers real hidden-volume and enumerable encrypted/plaintext
stores, frontend-derived OS scope names with an in-memory vault, retained legacy
platform source, OS refusal/retry, delayed model work, unowned runtime residue,
stale facade writes, owned/external model roots and failed fresh-router handoff.
It is not a real OS-vault or complete packaged UI/platform qualification. Cold
restart recovery is still the existing refusal shell. Shutdown of all optional
application services and late callbacks, cold application-process recovery and
cold preparation failures without a published intent,
shared hidden maintenance, explicit migration and
all-online/platform qualification remain before activation. No released build
or default is changed by this binding.

## Application preparation identity and operation kind

An application wipe now creates its random request identity before the first
worker await, after retaining its original preference/router owners. The first
native call publishes an application-profile plan; an ambiguous initial reply
uses a distinct recovery entrypoint and must match that exact request. It never
publishes another intent. A missing intent, another request, an inventory-only
operation or an already terminal operation refuses preparation recovery. This
includes a pre-publication failure: retry cannot silently capture newly appearing
data into a different wipe. Restart/review is still required for that case.

The unpublished plan format is now strict v6 and its terminal strict v4. Both
carry an explicit boolean workflow discriminator, included in operation binding
comparison. Previous experimental v5/v3 records are preserved and refused, never
interpreted as application shutdown. The application kind requires all known
profile-owned auxiliary roots. A terminal with its plan still present must agree
with that plan's kind. It retains no request ID, catalog or OS-scope roster.

The discriminator selects the intended enclosing protocol; it is not by itself
an external-service shutdown or cleanup grant. Current live shutdown remains
subject to the activation gates above. This change qualifies initial enclosing
reply loss and actual worker death before the live job captures its binding. It
does not yet enable cold-start continuation or instantiate ordinary providers
while startup sees an intent. The startup refusal shell and disabled managed
storage default remain in place pending the cold platform/lifecycle owner.

## Saved-entry mutation ownership

An erasure retirement retains its live worker lease or direct native owner,
rather than only a captured scope roster. It checks that authority when cleanup
is requested, when queued work starts, after every OS await and before declaring
success. A closed owner cannot issue later vault mutations. A call already
issued to the OS is still joined; loss of ownership preserves the public cleanup
intent instead of issuing another deletion or reporting successful retirement.

Recovering a removing plan rebinds mutation authority to the replacement worker
of that exact operation. Shared retired scope state retains protected-slot
witnesses across the replacement. Read-only terminal checks remain possible
without inventing new deletion authority. Host tests cover stale direct/worker
owners, closure during an accepted read, owner loss during metadata write or
protected deletion, and continuation through the recovered durable plan. OS
ports in these tests are in-memory; actual Keychain/Keystore qualification and
the complete cold application recovery gates remain open.

The Android secret-store adapter now also waits for the pinned plugin's
asynchronous preference writes to reach persistent storage. RAM readback cannot
substitute for that barrier. Failure preserves the public cleanup intent and
blocks native payload removal; host-native tests exercise refusal and retry.
See [Android quick-unlock persistence](validation/android-quick-unlock-persistence-2026-11-15/README.md)
for the modeled persistence boundary, Android compilation and remaining
real-device/cold-terminal limits.
The [Android restart follow-up](validation/android-quick-unlock-restart-2026-11-15/README.md)
adds 40 SIGKILL/fresh-process checks using the actual plugin, preference files
and Keystore on an Android 15 emulator, including a strong-biometric key. It
does not qualify physical devices or complete application recovery.
The [raw-record follow-up](validation/android-saved-entry-records-2026-11-15/README.md)
also avoids cipher initialization for Android absence checks and explicit
single-record removal. Removal owns its synchronous data-store commit; unknown
presence or unconfirmed removal still refuses cleanup. Its runtime qualification
is separate from the earlier 40-check persistence series.

Terminal admission first joins cleanup already accepted by the worker, while
refusing new operations. Entering finalization seals that owner's scope-mutation
grant. A failure cannot restore it from cached removing progress. Only a fresh
native retirement check of the same valid, still-removing operation reopens
cleanup after a pre-terminal refusal. Unknown state and committed finalization
remain sealed, including after a later progress refresh. Direct native actors
validate the same phase boundary. Read-only verification and finalization
retries remain available; a terminal never recreates a scope roster.

## Windows live helper ownership

Windows VPN status observations distinguish authenticated helper reports from
local read/validation errors. An invalid token, malformed phase or unavailable
process observation preserves the session and its stop capability; none can
authorize profile erasure. A zero-duration kernel process wait replaces parsing
localized command output. Confirmed process exit can complete an explicitly
requested stop when the helper's transient terminal-status file is already gone.

Start, stop, status and probe operations share a serialized owner. Concurrent
stops share their accepted control request, but a newly accepted start separates
the old and new requests. Queued starts retain immutable copies of their original
routing inputs. Status polling cannot retire a session during pending stop I/O.

Host tests cover these lifetime boundaries and refusal/retry through the real
application wipe controller and native stores. A disposable Windows process test
qualifies live/exit observation against the kernel; it does not qualify elevated
VPN route/DNS cleanup. A fresh backend still lacks independent cold discovery of
an older helper. Cold recovery and the other activation gates remain open; this
change does not enable managed storage or alter its default.

## Android daemon resource retirement port

The SDK has a separate process-local daemon retirement owner. It seals future
starts, fences queued old start/stop generations, releases known wake locks and
foreground state, and verifies this application's daemon component through the
platform before returning a resource receipt. Failed observation remains sealed;
read-only recheck and exact-owner release support retry without starting a node.
Late destruction of a cleaned instance does not revoke replacement presentation.

The live managed-profile wipe acquires this owner before quiescence or inventory
publication. Resource absence is checked around scope retirement, before native
payload removal and on finalization attempts. Ordinary node and call commands,
including delayed caller presentation, share a permanently retiring Dart facade.
Accepted calls are joined, including reentrant requests; the next profile gets a
fresh facade only after the original native release and preferences/router handoff.

Background readmission failure keeps recovery UI and the same owner. A lost
successful reply retries that exact native release without probing a consumed
token or repeating deletion; newly created payloads remain intact. Closing the
wipe owner never restores service admission by itself.

Ordinary `stop()` still has its accepted-intent contract. Actual Android lifecycle
qualification, VPN/capture/other-writer retirement and cold recovery remain open.
This boundary does not claim completed `onDestroy` and does not enable managed
storage or alter its default.

## Saved-entry recovery capture

Vault retirement now seals all selected scopes and joins accepted enrollment
before capturing an immutable set of OS-record addresses. An optional persistence
callback must settle before removal, and an address that appears after capture
is preserved rather than silently added to that set. Decoded witnesses can
verify absence without reading passwords or granting deletion authority.

The [capture qualification](validation/saved-entry-recovery-capture-2026-11-15/README.md)
includes absent-record initialization refusal, persistence ordering, changed-slot
preservation and native-profile composition. The enclosing
[application recovery journal](validation/application-erasure-journal-2026-11-15/README.md)
now publishes those addresses before OS-record deletion, blocks ordinary startup
through native terminal removal and supports read-only journal-only recovery.
The native terminal remains roster-free. The
[cold application owner](validation/cold-profile-recovery-2026-11-15/README.md)
now connects those records to isolated startup recovery and fresh preference/UI
handoff. Packaged platform qualification and remaining activation work still
precede enabling the new default.

The ordinary Android metadata reader now also avoids plugin initialization.
The [read-only saved-entry qualification](validation/android-public-saved-entry-read-2026-11-15/README.md)
covers fixed-file parsing, existing-key decryption, pinned-plugin format
interoperability and the unchanged absence/error boundary. Enrollment remains
an explicit plugin write; device and packaged platform smoke remain outstanding.

## Implementation boundaries

1. Managed stores need independent directories for their database and blobs.
   A database, journal, temporary replacement or blob for one identity must
   never share cleanup ownership with another identity or the hidden file.
2. A publicly readable catalog carries only an opaque random local ID and
   protection mode. Keys, passwords, public network addresses and decrypted
   display names remain outside it. Hidden-space availability is not inferred
   from this catalog; the hidden-unlock action remains independently available.
3. Use the existing authenticated-state engine for encrypted identities, one
   separately owned keybox, content and maintenance files per identity.
   Preserve its Merkle/rollback and ratchet
   guarantees. Evaluate SQLite only for genuinely unencrypted identity data;
   page authentication plus a command hash chain is insufficient for encrypted
   ratchet-state freshness. Neither backend is enabled in production builds.
4. Reuse reviewed encryption and bounded memory-hard password derivation for
   encrypted identities. Managed-file reclamation must also work when a user
   entered using biometric pre-derived keys rather than a password; it must
   not guess that unknown spaces belong to the active identity.
5. Run database operations, KDF and reclamation off the UI isolate. Do not
   weaken delivery ACK, authorization-floor, ratchet or teardown barriers to
   improve storage speed. Measure steady-state growth with repeated overwrite
   and deletion, rather than only comparing an empty database's size.
6. Wire mode choice before opening any store; visible identity selection,
   per-identity accounting, cleanup, all-online sessions, biometric reopen,
   compaction rekeys, erase and recovery must follow the selected locator.
   Any future standalone password-change or cross-mode migration action must
   follow it too; adding either new UI is not an activation prerequisite.
7. Existing `hiddenSpace` and historical `plain` preferences both name legacy
   container-backed data. Never interpret the historical flag as permission
   to read/write plaintext or to convert the existing container automatically.
8. If cross-mode migration is offered, it needs an explicit source/target choice, authenticated copy,
   readback and retained source until successful publication. A crash must
   leave at least one readable copy. Migration to plaintext needs separate
   informed confirmation; a failed unlock must not trigger migration.

## Qualification before enabling the new default

- Native cold reopen for encrypted and plaintext stores; wrong password and
  missing cipher provider cannot select plaintext or create replacement data.
- Independent-process crash before commit, after commit, and after observed
  delivery ACK, with exact message/identity and ratchet-recovery oracles.
- Repeated overwrite/delete workloads with bounded journal and file growth;
  per-identity size attribution and reclamation while other identities remain
  untouched and readable.
- Catalog corruption, path and symlink substitution, interrupted creation,
  cleanup/reopen races and interrupted supported rekey operations. Standalone
  password-change/cross-mode migration qualification applies when those actions
  are exposed; their absence is not a new feature requirement for this work.
- Mixed hidden/encrypted/plain identities, identity switch during I/O,
  all-online ownership, erase, content serving and one-prompt biometric reopen.
- Actual packaged native libraries, provenance/privacy checks and Android,
  Windows and macOS smoke tests. Host-only tests do not qualify these targets.

References: [SQLite reclamation and durability pragmas](https://sqlite.org/pragma.html),
[SQLCipher key and authentication semantics](https://www.zetetic.net/sqlcipher/sqlcipher-api/),
[Dart SQLite hook/provenance options](https://github.com/simolus3/sqlite3.dart/blob/main/sqlite3/doc/hook.md).
