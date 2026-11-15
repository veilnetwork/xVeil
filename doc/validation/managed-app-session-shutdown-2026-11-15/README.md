# Packaged managed storage and session shutdown

## Actual application evidence

An isolated macOS debug bundle runs the normal `lib/main.dart` entrypoint with
managed storage and the authenticated debug driver explicitly enabled. Only its
application name and bundle identifiers differ from production host metadata.
The source copy contains no Git/build cache; 3,034 consumed inputs are hashed.
It uses testnet configuration, and onboarding deliberately selects manual peers
without adding any. No production relay or user profile is modified.

Normal onboarding exposes encrypted, hidden and unencrypted choices. Leaving the
choice untouched creates one **encrypted** catalog entry with separate keybox,
content and maintenance files. The recovery certificate is copied through the
real UI; the previous clipboard contents are restored without publication.
This does not qualify the native save-file dialog.

After full process death, a wrong password is refused and the right password
opens the same identity. The actual native node starts and the application
reaches `ready`. Its initial canonical PoW runs in debug native code; that wait
is not a release performance measurement. This cycle does not qualify plaintext
or hidden onboarding in the packaged application.

## Confirmed shutdown defects

The real lock path exposed two related mechanisms:

1. The controller retains its old identity while teardown awaits. Changing the
   transport can recreate group/document/cloud providers during that interval.
   `AsyncValue.value` may additionally retain the previous signer while a new
   signer loads. New provider jobs then access the fallback/closed storage.
2. Provider disposal initiates asynchronous close without joining startup reads.
   Cloud materialized-view and capability-metadata loading can continue after
   the session owner has already closed their storage.

The initial capture contains nine uncaught storage/session errors. An admission-
only candidate removes the recreated-service errors but still exposes two
accepted startup readers. It is recorded as incomplete, not as a passing fix.

## Change

Session-ending depth is published synchronously by the controller's existing
lock/start-over/wipe ownership counter. A shared work-identity provider requires
an ordinary ready identity and zero ending depth. Group and document services
consult it before dependencies. Signer lookup watches its storage owner, checks
the owner again after awaiting, and cannot authorize another identity. Loading,
failed, foreign and closed-store signer states cannot create a group service.
This concerns full session teardown; the cover-only screen lock keeps its
ordinary ready session.

Cloud and capability cleanup register with the existing messaging shutdown
owner so it can await them before closing storage. Concurrent close calls join
one barrier. Cloud close joins local initialization, and capability close seals
and joins accepted metadata operations. Closed initialization cannot start new
storage work. Late initialization continuations check closure before further
metadata/reconciliation work.

The barrier deliberately does not wait for a pending network registration. A
whole-start join was rejected by the existing delayed-rehost test. The final
implementation retains the install-or-close policy for late endpoints; that
regression test passes unchanged.

## Qualification

- Eleven new checks exercise actual controller lock admission behind a gate,
  retained async signer values, closed/foreign/loading candidates, positive
  construction admission, preparation/recovery refusal, and both startup-read
  barriers with duplicate close calls. The gate checks use no elapsed-time
  threshold; an event-loop yield only drains concrete in-memory adapters.
- Four compiled controls fail behaviorally: remove controller publication,
  permit the retained loading signer, omit cloud read drainage, and omit
  capability metadata drainage. Sources are restored exactly before the final
  positive run. Early fixture compilation failures are not counted as controls.
- The final run passes **543 checks in 36 serial Flutter suites**, including
  controller/master lifecycle, group bindings, cloud/capability services,
  document replication, native erasure/crash recovery and saved-entry storage.
  Sources and four pinned host libraries remain unchanged; focused analysis
  is clean.
- One older wipe control also failed at the preceding commit: its plugin-only
  mock could not answer the native Android saved-entry port. The fixture now
  explicitly supplies an empty in-memory OS-secret adapter. No production
  absence/error check was bypassed to make that control pass.
- The final rebuilt application completes three real unlock/lock cycles with
  the same identity and **zero uncaught errors** in their captured logs. The
  first incomplete application candidate is kept separately in private proof.

## Native and Dart provenance

Veil is rebuilt from the consumed SDK sources in a separate external Cargo
target. The build watchdog verifies the mounted external filesystem and free
space. The published hidden-volume 2.7.2 host asset matches its qualified digest
before bundling. Raw and signed bundle digests are recorded separately.

The bundled SQLite framework is reconstructed byte-for-byte from the package-
pinned arm64 asset by its install-name change, single-architecture universal
wrapper and ad-hoc framework signature. The incomplete thin reconstruction is
not credited as a match. A fresh load and the real process's mapped-file list
confirm all three storage/network libraries come from the bundle.

The rebuilt Dart kernel differs from the original and contains both admission
and storage-drain markers. All consumed source copies match their manifests
apart from the two documented host-metadata substitutions. Signatures verify.
Each owned application process is stopped after locking and its actual exit is
observed; this is process-death qualification, not a graceful application-exit
or power-failure claim.

## Remaining scope

The QA bundle is debug, ad-hoc and isolated. It does not qualify release AOT,
restricted VPN provisioning, Android/Windows storage, OEM behavior or the other
two packaged storage choices. Those and activation remain open. Managed storage
is still disabled by default. No push, release, production seed update or access
to a user's container is included.
