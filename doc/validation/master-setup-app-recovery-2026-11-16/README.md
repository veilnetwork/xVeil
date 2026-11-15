# Authenticated application recovery of master creation

Status: controller and recovery-screen wiring implemented and qualified with
headless widgets and host-native stores. Managed production defaults remain
OFF. Packaged application, physical OEM and remaining activation gates are not
closed by these checks. No release was made.

## Resume the accepted operation

Ordinary unlock of a pending master now validates its exact private intent and
opened key witness before offering continuation. Unknown stages, absent or
conflicting intent, a foreign profile and changed accepted data do not grant
recovery authority. Existing incomplete-identity recovery remains separate.

The screen requests the master password again for protected storage. It asks
for the new child's password only when the parent has not yet recorded that
child's keys and the planned child is protected. Plaintext stores have no
password field. Inputs are cleared after an attempt and on exit. Labels and
the explanation are localized in all three supported languages. No autofocus,
application activation or external GUI automation was added.

The controller reauthenticates the exact original parent and compares its keys
with the retained authenticated context. It revalidates the current intent,
then follows its actual phase:

- Unknown child keys: reopen or create only the explicitly planned slot, require
  an inspected blank child and reject source/master key aliases, then durably
  attach the actual keys before personalized writes.
- Known child keys: reopen that exact child by the recorded key. Resume partial
  initialization or verify an already completed child without overwriting its
  later profile, node or user data.
- Verify child completion, publish the absent/exact complete parent roster and
  atomically finish with the non-replayable receipt. Only then adopt the access
  root, retire the recovery context and enter the ordinary selected identity.

The operation uses the existing exclusive edit/lifecycle owner and service
admission boundary. Accepted native work stays owned through lock/disposal;
keys and temporary plans are wiped when that work settles. There is no child
reverse pointer, persisted password, hidden-space scan, mailbox change or
network-authorization shortcut.

## Planned managed storage admission

A separate explicit planned-recovery factory runs through the managed storage
worker. It enumerates the admitted managed parent to distinguish an actually
absent slot from an existing final or staging directory. An inaccessible
enumeration is an error. Listed, staged or published data uses authenticated
resume; only demonstrated absence can reach no-replace creation. Authentication,
mode, corruption and ambiguous-path failures never fall back to creation or
plaintext. A failed opener retains ownership until cleanup finishes.

This handles a process death before child creation, before catalog registration,
or after publication. Ordinary existing/creation factories retain their
previous semantics. Managed recovery never probes the hidden container; hidden
recovery uses only the explicitly chosen password or recorded keys.

## Evidence and limits

Twenty-one application-controller cases start after real SIGKILL checkpoints.
Preparation covers all nine master/child protection combinations; later
boundaries cover a registered blank child, recorded child keys, partial child
profile and a published-but-pending roster for each master mode. Checks include
wrong master/child credentials, no early node-start request, exact existing
child keys, original source payload, successful continuation, cold ordinary
master classification and return to both identities. Completed children with
newer names/data preserve those values through parent recovery.

Three additional managed-worker SIGKILL cases cover unlisted staging, published
unlisted and registered stores. Wrong password and wrong mode are refused;
correct continuation preserves the existing payload and keys through cold
reopen. Six controlled native/controller cases cover accepted child-key
attachment or parent completion: lock and disposal cannot cause late
activation, and a lost final reply leads to ordinary cold roster classification.
An injected failure while entering the recovered session exposed a further
cleanup defect: a published stack survived the failed operation. The regression
failed on its disposal witness before the fix; failure handling now retires
session/stack services while their store is still open, before closing it and
offering recovery or returning to locked. The same control now passes and cold
ordinary entry retains both identities. This is an application disposal witness,
not a measurement of real socket teardown.

Twelve new headless screen cases cover the necessary credential fields,
single in-flight action and clearing input after refusal across all master and
child protection states. Existing recovery-screen cases remain in the final
run. These use offscreen Flutter tests; no desktop application window was
launched or activated.

The final frozen-source run passed **234 checks across 24 suites**, with no
skipped cases. Complete-library and changed-fixture analysis reports no issues.
The source manifest was checked after qualification and before the commit.
Native process-death checks prove neither power-loss nor
physical Android/OEM behavior. Controller node-start counters exercise the
application admission boundary, not real network/socket teardown. No new Rust
source or native package was built; the existing native library's hash and
source provenance were checked before the run.

## Remaining work

Existing-master appends and the non-router legacy creation path still need
transactional conversion/qualification. The complete activation audit must
also cover destructive maintenance and its Windows durability boundary,
credential/model inventory, packaged cold recovery, physical OEM behavior,
release AOT and all-target native packaging. The requested enumerable encrypted
default must remain disabled until these gates pass.
