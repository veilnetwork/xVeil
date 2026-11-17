# Group screen selection keeps its owner and reports capture failure

Base: `24f4b43b`. This corrects the group counterpart of the earlier
[direct-call selector](../screen-selection-owner-2026-11-17/README.md).
It does not attribute the Windows 10 camera complaint.

## Evidence

Group selectScreen captured an engine before awaiting screen discovery, then
used it and the shared selection without checking whether the room, engine,
profile or selection request had changed. It also ignored a false stop reply.
An exception starting the new source skipped restoration, while failure of
both sources left the service advertising screen ON.

Seventeen new cases on the unchanged base give **13 assertion failures and
four passing controls**, without elapsed-time thresholds. They run the actual
group service and media controller with controlled discovery and engine ports:

- delayed discovery after leave, another call, same-call engine replacement,
  a newer selection or profile switch, plus current and sharing-off controls;
- stop refusal/exception, new-source refusal/exception, and failure or exception
  restoring the former source;
- leave reentered from the native stop boundary;
- a paused observer resuming after capture recovery, with/without engine rebuild;
- the Android screen-source adapter's current-stop delivery and a paused old
  event after its source has been replaced.

The checks observe actual source commands, the active synthetic source, retired
engine access, service state and renegotiation. Sharing off may still accept a
valid source selection for the next start. Cleanup releases every held discovery
reply and joins commands before disposing the service.

## Change

Selection binds the session request, media epoch, engine, profile-preferences
lifetime and its own selection revision before discovery. Admission is checked
again after discovery and around source restart. A refused stop does not start
another source. A rejected source is not saved as selected; restoration tries
the exact previous source, including after an exception. If neither source
starts, the controller clears sharing and reports the observed stop, preserving
the call, audio and receive path.

Stop notifications retain their engine/request/epoch internally and are checked
when delivered. The public stream remains Stream<void>. A resumed subscriber
does not apply a retained stop to recovered capture or a replacement engine.
The existing Android producer uses the same scoped notification path; its valid
current-stop event remains observable.

No native code, ABI, media pin, protocol, group membership, capture permission,
codec, storage layout or own-device mailbox policy changes.

## Qualification and limits

**926 tests pass with zero skipped** across twenty related call, group,
capture/source, slot, audio-policy, diagnostics and profile-lifetime suites.
With diagnostics enabled, **476 pass with zero skipped** across five overlapping
suites; these counts are not additive. The analyzer and whitespace checks pass.
All **1,956 tracked Dart/package-manifest inputs** retain their final-run hashes.

Three deliberate mutants give the intended failures: omit post-discovery
admission **1**, ignore stop refusal **1**, allow stale stop events **3**.
They are restored before final testing. The initial fixture's one style finding
was corrected before final runs; it was not counted as a regression failure.

Discovery and capture are controlled ports; the tests do not enumerate actual
windows or capture physical media. The Android case executes the real group
controller's Android branch against a synthetic screen-source adapter, not an
Android device. Windows 10 hardware, actual screen capture and audible calls
remain outside this qualification.

Tests use TMPDIR=/private/tmp/. No GUI windows, OS input, phone installation,
user container or seed is changed. Test processes exit; the existing user app
remains running. No push or release.
