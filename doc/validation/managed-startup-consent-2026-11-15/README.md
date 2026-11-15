# Independent startup-entry consent for enumerable identities

Managed-storage defaults remain **OFF**. This fixes the application consent
layer above the existing independently scoped OS-vault records. It does not
change container passwords, biometric cryptography or platform authentication.

## Reproduced behavior

OS saved-entry namespaces already include the enumerable identity's local ID,
mode and profile root. The UI offer gate still used one profile-wide opt-in.
Two actual settings-screen tests reproduce both consequences:

- Disabling startup entry for A deletes A's record and removes the shared gate,
  hiding B's still valid saved entry.
- Enabling A writes the shared gate, allowing B's otherwise unconsented existing
  record to be offered when B is selected.

Both tests fail at B's offer verdict on the old code. They use separate real
`QuickUnlockVault` state machines with one in-memory secret-store port, and the
actual settings form/provider. No OS secret store or real biometric prompt is
involved. This is a confirmed QA-mode composition defect, not an attribution of
the earlier physical fingerprint reports.

## Scope and local recovery

Enumerable identities now have separate consent markers keyed only by their
already public local ID and protection mode. Legacy hidden-container marker and
vault namespace bytes remain unchanged; no hidden-space entry, password, display
name or network identity is added to public preferences. Missing scoped markers
honor the old shared marker so accepted local enrollments remain accessible.
Explicit per-identity denial overrides that fallback.

Changing the historical shared marker first materializes its *prior* meaning
for the already public siblings. Thus removing legacy consent retains older
managed enrollments, and a new legacy enrollment cannot authorize unrelated
old managed records. Explicit scoped choices are preserved. Each required
preference write must succeed before changing the shared marker; partial refusal
retains its previous fallback and can be retried.

Whole consent operations share a queue on the profile lifetime's stable
preference view. Migration cannot overwrite a concurrent later explicit choice;
an exceptional write does not strand subsequent work. Caller-owned sibling
lists are copied before waiting. Ordinary backend/file lifetime barriers still
apply; this queue is not a cross-process lock or a substitute for native
profile ownership.

The settings form captures its access locator with the identity lease, checks
both after screen-lock authorization and during enrollment, and persists consent
before touching the OS store. Start-over captures the same target vault/locator
before awaiting preferences and removes only that saved entry. Startup options
retain their captured target vault while awaiting preferences. Full-profile
wipe still uses its existing complete inventory and erasure protocol; consent
is never evidence of OS-record absence.

## Qualification

Final sequential qualification: **136 passed, zero skipped**, twelve suites.
They cover settings enrollment/removal, actual start-over, legacy compatibility,
migration failure/retry, concurrent choices, an exceptional write, scope queues,
retirement/wipe, screen-lock lifecycle, native mixed-mode master creation and
preference-file reopen. Full application and both new-test static analysis reports
no issues.

Three native preference-file cases use actual encrypted identity/catalog files
and the ordinary owned preference bootstrap. After releasing the old actor and
opening a fresh preference backend, per-identity denial, sibling permission and
legacy on/off choices retain their exact values. This is native file-owner
reopen, **not independent-process death or physical platform biometric smoke**.

The previously qualified native library is explicitly selected and its hash
verified unchanged; no Rust build/source or native pin changes. All checks run
in background with `TMPDIR=/private/tmp/`, without launching/activating application
windows or injecting user input. Raw paths, identities and artifacts remain
outside the repository. No user container or OS credential is touched. No push
or release.

Physical Android/OEM/Windows authentication, the full mode/credential/destructive
matrix, packaged custom-source post-compaction cold readback, Windows source
name durability, native pin rebuilds, release AOT and default activation remain
open. A new exact-manifest package build is required before any agreed foreground
qualification of these source changes.
