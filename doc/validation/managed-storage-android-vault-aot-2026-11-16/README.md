# Android release/AOT: scoped OS-vault entry

Status: encrypted and hidden identities pass real Android Keystore/biometric
entry checks on the owned Android 15 AOSP ARM64 emulator. Six successful entry
cases each use one CryptoObject-bound system request. Production managed storage
remains OFF; profile erasure/recovery and other platform scope remain open.

## Artifact and platform

The same hook-free release/AOT QA APK from the
[all-mode qualification](../managed-storage-android-allmodes-aot-2026-11-16/README.md)
is reused without a rebuild or runtime-source change. Its retained and installed
digests are checked; all 3,045 product inputs still match. The earlier signature,
AOT/no-JIT, five native reconstruction and artifact-privacy checks remain valid.
Normal Android controls drive the ordinary application entrypoint. No debug
HTTP hook, fake authentication adapter or controller mutation is used.

The system fingerprint service and emulator sensor are available. A synthetic
system PIN is set only inside the owned AVD. Fingerprint enrollment uses actual
Android Settings, PIN confirmation, enrollment controls and virtual sensor
input, with a positive system completion screen. xVeil then sees enrolled
biometrics through its normal LocalAuthentication adapter. The sensor events
exercise Android APIs and Keystore; they are not a physical fingerprint or a
hardware-security attestation test.

Both identities enable Device authentication and Also unlock after restart
through ordinary Quick unlock settings, with Pattern left Off. Their existing
container passwords authorize configuration. Each initial configuration uses
two OS confirmations. Opening afterward uses the native CryptoObject-bound
read path; the six entry assertions below apply to those opening operations.

## Entry cases

| Case | Scope | Positive readback |
|---|---|---|
| First cold application entry | Encrypted | Original full sovereign ID and all four notes |
| First cold hidden entry | Hidden | Original full certificate ID and its single note |
| Cold return after hidden enrollment | Encrypted | Same full ID and four notes |
| Warm full-container lock, cancellation and retry | Encrypted | Same process; successful retry shows the same ID and four notes |
| Cold entry after owned reclamation | Encrypted | Same ID and four notes; saved entries remain intact |
| Entry after full Android/AVD restart | Encrypted | Required system PIN first, then one app request; same ID and four notes |

A cold application case checks process exit and the installed APK before
launching it. The fingerprint button is present without a graphical pattern and
with an empty password field. No container password is typed for entry.

For each credited entry, the actual Android biometric-service trace contains
exactly one request ID and `isCrypto: true`. Only the matching QA system dialog
receives the enrolled virtual sensor event. The observer requires ordinary
ready UI with no second request, then independently opens the normal drawer and
Saved Messages. Full identity and exact note bodies/counts are checked there;
other fixtures' histories must be absent. An absent prompt, dismissed dialog,
empty history or process presence alone cannot pass.

The six cases are six application scenarios, not a new unit-test total or a
claim about every Android/OEM version. Request IDs are compared within each
operation; no uniqueness across a system-service restart is assumed.

## Ownership, cancellation and maintenance

Before hidden enrollment, selecting the hidden identity offers no encrypted
saved-entry button, preserves the encrypted protected namespace and leaves
ordinary password entry available. Hidden enrollment then creates its own
three protected-namespace preference files while preserving all three encrypted
namespace files byte for byte. Both configured scopes subsequently open their
own identities successfully.

With both entries configured, selecting the plaintext identity offers neither
a biometric button nor a password field. Its normal no-key open control still
works and its exact identity/note are visible. This also checks that enabling
the legacy hidden scope does not implicitly enroll a managed sibling. All six
protected-namespace files remain unchanged.

Cancelling a warm CryptoObject prompt leaves the container locked in the same
application process. All nine native identity data/role files and all six
protected-namespace files retain their exact digests. The retry receives a
fresh request ID and opens with one request; no cached-key success is credited
after cancellation. This is a full-container Lock now path, not an automatic
screen-cover timeout test.

The biometric-opened encrypted session also runs normal Reclaim space without
re-entering a password. Positive completion UI, unchanged sibling data/role
files, unchanged protected namespace files and a subsequent one-request cold
entry all pass. The small fixture makes no space-savings claim.

The six protected files are the data/config/wrapped-key preference files for
two protected namespaces, not six credentials. The shared public metadata is
not claimed to remain byte-identical when another scoped entry is added.
OS-record retirement/deletion is not exercised or declared complete here.

## System restart and observer corrections

The owned application and emulator are stopped with exit checks, then the same
AVD disk state is resumed without reset. Before app entry, actual SystemUI PIN
resources guard entry of the synthetic device PIN through the system keypad.
The PIN panel must disappear. The app then performs its own single CryptoObject
request and cold history readback. All six protected preference files survive
unchanged. This is an ordinary complete restart, not a power-loss simulation.

One early warm-entry observer was interrupted by the QA application's native
notification-permission prompt. That observer is excluded. Only the matching
notification request was allowed; an independent warm cancel/retry run then
completed with its full request and history oracles.

The first pre-device-unlock UI observer obtained no XML at its usual external
storage dump path. The same running AVD was inspected, and a private dump in
Android's device-encrypted temporary directory produced the actual PIN hierarchy.
The observer now checks XML content rather than trusting the command's success
message. No application storage repair, data reset or authentication-policy
weakening was used to resolve either stand issue.

## Evidence audit and teardown

The final audit re-reads all six request traces, explicit positive/negative
proof fields, actual identity/history UI, cancellation, protected-file scope
preservation, reclamation, OS restart and artifact/source provenance. It does not
count the audit as another test run. Runtime sources are unchanged; no new
application defect or code fix is claimed by these passing scenarios.

The owned application and headless emulator are stopped again with process-exit
checks. Owned temporary dump files are removed, and no ADB forward remains.
The synthetic PIN, enrolled sensor, three QA identities and two saved entries
are retained privately for the upcoming erasure/recovery checks. No Mac window,
physical phone, real biometric enrollment, user profile, push, official signing,
production-default change or release is involved.

Physical OEM/hardware validation, graphical pattern entry, automatic screen-cover
behavior, complete profile erasure/recovery including OS-record retirement and
other platform qualification retain their own scope. This closes the ordinary
Android managed/legacy scoped biometric-entry prerequisite only.

## Erasure follow-up

The subsequent [packaged erasure qualification](../managed-storage-android-erasure-aot-2026-11-16/README.md)
uses these actual OS records, reproduces and fixes a cold-recovery refusal, and
checks removal plus survival/reopening of a separate named profile. It does not
expand the hardware/OEM or other-platform scope of this entry qualification.
