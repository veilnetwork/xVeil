# Attachment camera work and output retirement

## Confirmed boundary

The attachment widget previously disposed its controller without retaining
pending picture/video-start results. A result arriving after navigation could
lose both its output-file owner and the backend lease. Closing the widget is
not completion of accepted platform work. A picture result returned through
CameraController can also be hidden by its post-await access to a disposed
notifier.

The group-camera route additionally registered a temporary video as a persistent
streaming source, then deleted that path after posting. Future content requests
could therefore address an absent source. Camera output now takes the existing
bounded encrypted-copy path; ordinary picked persistent sources keep streaming.
This call-site change is code-reviewed and analyzed; a physical group-camera
send is not qualified by the host model.

## Ownership

AttachmentCaptureWork binds the profile capture lifetime before discovery or
permission awaits. It owns accepted discovery, initialization, picture and video
operations, controller leases and untransferred files independently of the
widget. Retirement seals the session immediately and requests hardware stop
promptly. The backend lease remains held until accepted work and late replies
settle; final disposal runs before allowing another controller on that backend.
Old widgets cannot adopt a fresh profile's lifetime on resume.

Picture/video output calls use the captured platform port directly, retaining
returned paths even after the controller notifier is disposed. An early video
stop can precede a pending start reply. Such a session submits a final stop after
both replies settle, retaining and cleaning both known output files before
releasing the backend. A failed stop or unknown output refuses erasure rather
than treating a closed camera as proof of file absence.

A handed-off file has its own registered owner. One accepted consumer can read
it; erasure waits for that consumer and for deletion. Failed deletion retains
the same file for retry. A cleanup refusal after a successful send does not
request a second send. Files are removed only as regular files, with a final
absence check; unknown paths and non-file objects refuse cleanup.

## Validation

- 304 checks passed across 18 Flutter suites, including attachment operations,
  output-file ownership, existing camera/direct/group-call/voice/video-note
  lifetimes, bounded file reading, group composer and native profile-wipe/guard
  fixtures. Tests ran serially with the prescribed temporary directory.
- Held platform futures exercise widget disposal during photo/video start,
  prompt hardware-stop requests, refusal of a replacement backend lease while
  work remains, late-output cleanup and final post-start video cleanup. The
  latter uses two distinct real temporary files.
- File tests use actual filesystem removal, delayed consumers, coalesced delete,
  cleanup refusal/retry, one-consumer admission and original-error preservation.
  Unknown/empty output paths cannot become a successful erasure proof.
- The native profile fixture verifies that refused camera-file cleanup preserves
  payloads, six OS-key fixture records and absence of an erasure intent. The
  resolved retry removes the same output and completes erasure. Another case
  holds a file reader through the production wipe and verifies deletion starts
  only after it settles.
- Three deliberate mutants failed behaviorally: releasing the backend lease
  during early hardware close, omitting the accepted-consumer join, and omitting
  post-start video cleanup. No compilation failure was counted as a red test.
  Production sources were restored before the final passing suite.
- Analysis of all 11 affected Dart files reported no issues. Frozen source
  inventories and four pinned native-library hashes matched before and after
  test runs. No native engine, APK or release artifact was rebuilt.

## Limits

Platform calls in capture tests are modeled. Profile-wipe fixtures use actual
native erasure and synthetic files/OS-key records; they do not prove physical
camera shutdown or real OS-vault behavior. An unknown output deliberately keeps
a refusing owner after hardware close. Resolving it after process restart needs
separate cold-recovery work, not a guessed path or silently empty registry.

Ordinary privacy-lock integration has subsequent
[host qualification](../attachment-privacy-lock-2026-11-14/README.md).
Independent Camera2/AAudio shutdown, projection retirement integration,
Wi-Fi locks, cold application recovery and packaged
migration/maintenance remain separate requirements. No runtime Android, iOS or
group-camera qualification is claimed. The new storage modes remain disabled by
`XVEIL_MANAGED_STORAGE`; no push or release is part of this cycle.
