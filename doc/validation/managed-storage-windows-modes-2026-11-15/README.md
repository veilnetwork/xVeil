# Windows application storage modes

Production managed storage remains disabled. This is an isolated Windows 11
qualification of the normal application paths, following the
[worker bootstrap](../managed-storage-windows-bootstrap-2026-11-15/README.md) and
[private preference creation](../windows-preferences-private-create-2026-11-15/README.md)
fixes. It is not Windows 10 call, camera, notification or release qualification.

## Stand and oracles

The ordinary `lib/main.dart` debug application used its own executable/product,
application-data namespace and QA profile. All identities, passwords, recovery
certificates and notes were synthetic. Existing user containers were not opened.
Onboarding was driven through actual Flutter controls. Certificate export used
the native Windows Save dialog; its owned Save button was clicked without
changing the suggested filename. Before/after checks found a new valid recovery
certificate for the full minted identity, and the wizard's normal saved-file
gate allowed continuation.

Read-only VM inspection located only the unique mounted onboarding state and
its public node identifier. It did not mutate controllers or retrieve the
recovery code. Application debug hooks saved/read real CloudService notes and
reported their digests. Each identity oracle requires a positive ready state,
the exact full node identifier and the exact saved note digest; empty observer
results never count as equality or successful absence.

Source manifests were checked before/after the Windows build. The selected
Veil core, hidden-volume and SQLite assets matched the reviewed DLL digests.
The Veil core has embedded-node/testnet features. No media engine was included,
and no peer-delivery or audio/video claim is made. A real local node booted after
unlock; this is not a network-connectivity qualification.

## Results

| Mode | Normal onboarding | Reopen after process death | Data oracle |
|---|---|---|---|
| Encrypted | Certificate export, password setup, real node boot | Password opens the same identity | Exact note digest; explicit wrong-password verdict before correct reopen |
| Unencrypted | Explicit selection and plaintext warning; no password step | Normal “Open without password” control, with no password field | Same identity and exact note digest |
| Hidden | Explicit opt-in, certificate export, password setup, real node boot | Explicit hidden-storage selection, then password | Same identity and exact note digest |

The earlier encrypted cold-open run preceded the runtime-DACL correction.
Plaintext and hidden cold opens and the final return to both enumerable
identities used the rebuilt application with that correction. The
[runtime qualification](../windows-runtime-private-create-2026-11-15/README.md)
records the separate confirmed defect and its red/green checks.

After plaintext creation and again after hidden creation/cold reopen, all three
previously unopened encrypted payload files matched their original digests.
Afterward, normal lock-screen selection reopened the existing encrypted and
plaintext identities, verified both original notes and locked each session.
The hidden identity's newly exported certificate named a different identity
from both existing ones.

An independent Python SQLite reader opened the plaintext store read-only,
without a key. It found the SQLite header, `unencrypted` protection metadata and
the synthetic note title. After hidden creation, the enumerable catalog still
contained exactly the encrypted and unencrypted entries. This verifies the
intended plaintext behavior and absence of a hidden catalog entry; it is not a
claim that arbitrary filesystem snapshots cannot reveal hidden-store activity.

## Observer corrections and limits

- A background/occluded Windows app can expose no semantics. Those attempts were
  not credited as a blank-screen defect, password-free open or successful test.
  A later normal foreground run positively located and activated the controls.
- Hidden cold start required an explicit storage choice. The first observer
  overlooked that requirement and found the unlock button disabled; selecting
  hidden storage before typing allowed the actual cold-open test to proceed.
- An immediate action after selecting another mode raced the UI transition and
  returned “not found”. The observer was corrected to wait for the selected
  mode's actual control before entering data. The existing app was inspected
  and continued; no duplicate identity was created.
- The first generic identity comparison treated the hook's nested identity map
  as a string. That observer assertion was corrected to compare the complete
  node identifier. It was not an application identity mismatch.

These are debug Windows 11 runs with limited payloads. Android packaging,
biometric reopen for the new modes, full destructive-operation/recovery paths,
long-running multi-identity workloads and release artifacts still need their
own application qualifications. The production default is not enabled by these
results. Raw artifacts and synthetic credentials remain outside the repository.

The owned app process was stopped after locking. The five owned scheduled tasks
were removed after verifying process exit. Synthetic exported certificates were
removed only after exact path/name and digest checks; the obsolete rollback
bundle was removed, retaining the current QA bundle for further qualification.
