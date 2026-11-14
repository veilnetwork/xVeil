# Android screen capture lifetime

## Confirmed defects

Six behavioural tests failed on the prior Dart implementation before the fix:

- A late consent success revived a source after its stop had returned.
- A replacement started while the previous native stop was pending; the old
  completion then removed the replacement's message handler.
- Stopping an expired source stopped or detached its replacement.
- A delayed `stopped` event from an old session closed the current source.
- A failed native stop was swallowed and ownership was incorrectly released.
- Concurrent starts requested consent twice and replaced the first frame sink.

These are local source-lifetime defects, not an attribution of any historical
network, Windows camera, or call-notification complaint.

## Change

Dart retains one owner per binary messenger and channel name. Starts coalesce;
explicit stop seals the source immediately, cancels native consent without
waiting for its reply, and joins that accepted start. A replacement waits for a
pending stop. An unacknowledged stop retains ownership for retry. A lost start
reply requires native cleanup before ownership can be released.

The private Dart/Android protocol carries a random per-attempt session in both
commands and events. Unscoped or obsolete events are rejected. The native bridge
captures a lease before posting a frame; it cannot resolve a different owner
when the main looper eventually handles that frame. Commands from an obsolete
Flutter channel and cleanup from an obsolete engine cannot acquire or stop the
current screen source.

Consent and queued service starts also retain the daemon admission generation.
Retiring that generation fences a delayed permission result or START intent.
The service retains failed cleanup ownership, releases projection resources,
and joins its worker off the main looper before completing a successful stop.
Already queued starts for a stopped source cannot acquire a projection later.

## Validation

- 213 Flutter checks passed across nine suites: capture lifetime/decoding,
  direct and group media startup, teardown, route operations, microphone state,
  background lifetime and Android call-screen host lifetime.
- The capture-specific suites include ten lifetime scenarios and five existing
  rebind/decoding/session checks. Added coverage includes lost start replies,
  failed cleanup, cancellation of a waiting replacement and unscoped events.
- The native lease smoke passed. Mutants accepting an obsolete queued lease or
  allowing a different engine to end a lease both failed the smoke.
- All 15 actual Android app Kotlin files, all current SDK Kotlin sources and
  their resources compiled and packaged into an isolated debug APK. No stub
  MainActivity or service was substituted. Source hashes were checked before
  and after; the harness has no Flutter application assets and was not run as
  a complete client.
- Dart analysis of the four changed Dart files reported no issues. Native
  library hashes and the frozen source inventory were checked around suites.

Two fixture issues exposed by the broader suite were corrected: preference
loading now permits the deliberate cache reload through the same explicit
read gate, and camera-call setup waits for the actual active transition instead
of a fixed number of event-loop turns. Neither changes production audio logic.

## Remaining boundary

No Android device was available in ADB for this qualification. Permission UI,
real MediaProjection acquisition/release, service destruction and repeated
screen-share toggles still require a device run. JVM lease tests and an APK
build do not prove those OS effects.

This cycle does not qualify profile erasure across all media sources. Existing
controller teardown paths can still suppress platform cleanup failures; the
independent microphone, camera, audio, Wi-Fi-lock and cold-start recovery gates
remain separate work. `XVEIL_MANAGED_STORAGE` remains off by default. No release
or push is part of this validation.
