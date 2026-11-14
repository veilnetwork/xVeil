# Camera resource ownership and retirement

## Confirmed defects

Two behavioural tests failed on the previous capture implementation:

- A native close failure was swallowed after the controller reference was
  dropped. The next stop did not retry the platform release.
- A concurrent second stop returned while the first native release was pending.

The selected camera package marks CameraController disposed before awaiting its
platform operation. Calling the same wrapper again therefore cannot recover a
failed release. The Android adapter also disposes its current native camera
without using the supplied camera id to select it. Retrying an old close after
opening a replacement would be unsafe.

## Change

An owned controller retains its exact backend, controller and native id through
failure. Repeated stops join the same pending close; a failed close retries the
platform operation rather than the already-disposed Dart wrapper. A shared
backend lease prevents a replacement camera from opening before the old release
is acknowledged. Both the call/video-note plugin path and the attachment camera
use that lease. An old completed owner never stops a replacement.

Normal call hangup retains its bounded wait for a stuck camera start. The
separate retirement operation permanently fences a source, joins its accepted
starts without treating a timeout as absence, releases retained controllers and
waits for the converter isolate's actual exit message. Simultaneous starts share
one acquisition. A failed or rejected open also cleans its unused converter.

A profile-bound registry retains these resources even if an ordinary controller
has dropped its reference after stop. ManagedProfileWipe binds that registry
before awaiting other work, seals it, requires retirement before creating an
erasure intent, and verifies its owner at the existing erasure barriers. Only a
successful final release publishes fresh capture admission. Call controllers and
the video-note adapter capture the old registry before awaits; delayed work
cannot adopt the next profile's registry.

Attachment recording owns output files and asynchronous UI work in addition to
the camera. Its lease deliberately refuses automatic camera-only retirement.
Normal widget cleanup removes known abandoned files before releasing the lease;
failed cleanup retains the owner and known pending path. A still-open attachment
capture can therefore block managed erasure rather than falsely prove absence.
Complete attachment-work/cold-recovery qualification remains pending.

## Validation

- 271 checks passed across 13 Flutter suites: camera retirement, camera selection,
  existing capture guards, direct/group calls, teardown, voice/video-note
  controllers, attachment-camera lifecycle, screen-capture lifetime, the capture
  registry and native profile-wipe/guard fixtures.
- The new camera tests cover native refusal/retry, concurrent stop/start,
  superseded initialization, held discovery, actual converter-isolate exit,
  replacement protection, attachment refusal and old-profile admission.
- The native profile fixture uses the real plugin-facing capture adapter over a
  modeled camera backend. A refused close preserves actual native profile files,
  OS-key fixture records and the absence of an erasure intent; a resolved retry
  reaches the same native id and permits completion. Only device behavior is
  modeled, not profile erasure.
- Two deliberate mutants failed behaviourally: retrying the disposed wrapper
  instead of the backend, and returning retirement without joining accepted
  discovery. Production sources were restored and matched the passing run.
- Dart analysis of the 13 affected files reported no issues. Source inventories
  and four native-library hashes were checked around suites. The platform
  interface moved from a test dependency to a production dependency; its pinned
  version and checksum did not change. No native engine was rebuilt this cycle.

## Limits

The native video-note wrapper already rejects a start on a destroyed recorder.
The initial suspected revival through that wrapper is not established and is
not claimed as a new defect or as an explanation of a user complaint.

Camera-plugin acknowledgement and an isolate exit are not independent proof of
physical camera shutdown. No device was available in ADB. Native Camera2 capture,
AAudio, screen-projection retirement integration, Wi-Fi locks, attachment output
work, cold recovery and packaged migration/maintenance still have separate
requirements. This registry does not infer absence of unregistered backends.
`XVEIL_MANAGED_STORAGE` remains off. There is no push or release in this cycle.
