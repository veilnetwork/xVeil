# Persisted padding for enumerable encrypted stores

Managed storage remains disabled in production defaults. This follows the
[Android maintenance qualification](../managed-storage-android-reclaim-wipe-2026-11-15/README.md),
which observed a small encrypted profile growing during reclamation. The work
below isolates a confirmed configuration defect on macOS native fixtures. It
does not qualify an updated Android/Windows package or enable the new default.

## Confirmed mechanism

`HvSpace.create` used the native hidden-storage constructor, whose persisted
header selects the default 1-MiB padding buckets. The managed file owner then
called `setPaddingPolicy(none)`. That setter changes the open session, not the
header. Normal managed reopen also applied the override before application
writes, masking the discrepancy. Native compaction independently reopened the
source, inherited its persisted padding and filled the replacement in buckets
before the host could apply its staged-session override.

Three regression cases create real managed keybox, content and maintenance
files, close them, then reopen disposable copies directly through the native
API without the application override. A tiny transaction previously added
966,656–1,015,808 bytes. All three cases fail on the original application/native
combination. They pass after the creation fix, allowing ordinary index and
checkpoint slots within a 64-KiB bound instead of a concealment bucket. The
original admitted files are not modified by those raw-copy probes.

## Change and boundaries

Hidden-volume commit `7b13bbb4` adds an explicit creation constructor and optional
Dart `HvSpace.create(padding:)`. It persists the selected policy in the header.
The original constructor still selects the library's existing hidden-storage
default. Both routes share creation ownership, password-copy zeroization,
Argon parameters and replica handling. The Dart route validates scalar bounds
before allocating its native buffers. One new constructor checksum is generated
from the actual library; all existing method checksums are unchanged.

The application supplies `PaddingPreset.none` when creating each independently
owned encrypted file. Existing runtime overrides remain in place. Encryption,
KDF cost, role binding, anti-rollback state and authorization/ratchet barriers
are unchanged. This does not alter hidden creation defaults, weaken a hidden
container's existing posture, rewrite old headers or automatically migrate
existing stores. Older unreleased managed fixtures retain their old header
unless explicitly migrated; native compaction continues to preserve source
posture. No stronger padding-header authentication guarantee is introduced.

## Controlled native measurement

The same newly built library and Dart bindings are used throughout A/B/A. Only
the application's explicit creation-policy argument changes. Each run creates
the same deterministic logical workload: 80 writes over four live 1-KiB log
records, followed by 32 forced reclamations. Ciphertext and keys are freshly
randomized per fixture, so ciphertext equality between runs is not claimed.

| Phase | Creation posture | Total logical file lengths after rounds 3–32 |
|---|---|---|
| A1 | Runtime-only override; header default | 2,183,168 bytes throughout |
| B | Explicit persisted no-padding | 225,280–241,664 bytes |
| A2 | Runtime-only override restored | 2,183,168 bytes throughout |

For every reclamation, the original exported outer keys, keybox bytes and four
live records match. The logical sequence advances by exactly two and the
original rollback anchor still resolves cleanly. A final ordinary reclamation
is a no-op; password-based cold reopen returns the exact data and keys. The
candidate source is restored after the controls finish.

An earlier 32-round probe against the published library also remained bounded
after its initial allocation. Thus the observed bucket expansion is not evidence
of unlimited accumulation. The candidate's small range also includes evolving
maintenance history; no asymptotic bound is inferred from 32 rounds. These are
native file-length measurements, not application throughput, disk-block savings
or a percentage improvement for user histories. The original Android sample
included background work; its entire increase is not retroactively attributed
to this one mechanism.

## Verification and provenance

- Two Rust tests cover all explicit padding presets, the unchanged legacy
  default, and prepared compaction/cold data readback with no-padding.
- Twenty-three Dart plugin checks cover creation, cold reopen, default behavior,
  scalar refusal, constructor/method checksums, prepared ownership and validation
  before native allocation.
- Forty-two application checks cover the three new regressions, owned
  reclamation, actual process-interruption recovery, worker serialization,
  reclamation budgets and facade/session ownership. No skips are counted as
  passes.
- Analysis of the changed application/plugin Dart files and the new tests is
  clean. Rust formatting checks pass.
- The older library is deliberately loaded against the new bindings. It is
  refused at the missing-constructor checksum before a destination file is
  created. There is no fallback to the old creation posture or plaintext.

The published host library used for the initial red control matches its
previously reconstructed bundle digest. The candidate is a local unreleased
build, selected by explicit path from a fresh dedicated external Cargo target.
The build monitors the external filesystem identity and free space. Its Rust
source/manifest/lock-file digest set is unchanged across compilation, and the
selected library digest is rechecked before tests and all A/B/A phases. Personal
build paths are remapped. The ABI generator's check, staged privacy scan and
native artifact privacy scan pass.

The first plugin-test invocation used the wrong working directory for its
source-inventory checks, and the new test initially assumed different wrapper
names/error classes. Those harness errors were corrected before the credited
23-check run from the plugin package root. Flutter's two generated iOS example
config edits were inspected and restored; they are not part of this change.

Only owned native fixtures and test processes are used; temporary fixtures are
closed/deleted and process completion is observed. No application stand or user
container is opened. Private evidence and libraries remain outside the repository.
Nothing is pushed, tagged or released. Before packaging this binding update,
rebuild and qualify the native libraries for every supported target in dependency
order. Existing prebuilt libraries do not provide the new constructor. Physical
Android/OEM, packaged platform smoke, mixed-roster maintenance and the other
activation gates remain open.
