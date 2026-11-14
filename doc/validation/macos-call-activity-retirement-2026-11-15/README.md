# macOS call activity retirement

## Scope

The macOS runner supported ordinary call power activity but lacked the native
retirement/verification/release methods required by managed profile erasure.
The Dart side therefore refused strong erasure there. This closes that missing
port; it is not a reproduced user data-loss incident.

## Native ownership

Each window's CallActivity wrapper now owns a separate native resource record.
An accepted begin is registered before entering Foundation. An end retains its
exact token until the API returns successfully. Failed release, reentrant begin
or an end still in progress cannot become an empty native inventory.

Records outlive a disappearing wrapper when cleanup remains uncertain; they
retain port/token ownership without retaining the window or wrapper. A later
retirement sweep attempts every record. Wrapper destruction permanently retires
its own record, which cannot acquire again.

The process-local native coordinator seals new acquisition before sweeping
records. It returns an opaque retirement token only after all known native work
has settled and records are absent. Verification and readmission require that
same token and empty inventory. A foreign/older token cannot open another
retirement; an exact lost-success retry does not change new admission. Live
window records can serve the fresh profile after successful readmission.

The Flutter bridge exposes the same retirement protocol as Android and reports
an unavailable window/invalid request as an error, rather than an inactive
resource result. Dart's existing accepted-command drain and permanently sealed
old facades remain required; this native receipt does not authorize file erasure.

## Validation

- The actual production Swift owner passed host checks for repeated acquisition,
  multiple holders, release refusal/retry, foreign and old tokens, lost-success
  readmission, orphaned wrapper cleanup, accepted reentrant begin, reentrant
  acquire during end and a real Foundation activity acquisition/release.
- Five private-copy mutants compiled and failed behaviorally: unsealed admission,
  forgetting a failed release, unregistered accepted begin, foreign-token release
  and reuse of an ending token. Negative probes exit normally with failure;
  compiler failures and process crashes are not counted as rejection.
- All three actual runner Swift sources typechecked in Swift 5 mode for macOS
  12 against the installed FlutterMacOS framework. Only plugin registration was
  supplied by a no-op declaration; no CallActivity or window binding was stubbed.
- 481 checks passed across 32 serial Flutter suites, including network ownership
  and retirement, background/microphone composition, native profile-wipe/guards,
  call/capture lifetimes and secure-screen runner guards.
- Swift source hashes and the Flutter framework binary hash matched around host
  qualification. The broad suite also froze runner sources and verified the
  four existing pinned native-library hashes. No native media engine was rebuilt.

## Limits

The runner was typechecked against the actual FlutterMacOS framework with a
no-op plugin-registration declaration. Plugin initialization, the packaged
application and a native Flutter method-channel round trip were not run.

Most failure scenarios use modeled Foundation ports. One host scenario acquires
and ends a real ProcessInfo activity. This establishes API execution and native
ownership, not an independent measurement of App Nap or hardware power state.
The inventory is process-local and cannot authorize cold recovery by itself.
Independent camera/audio/projection observations, cold application recovery,
packaged migration/maintenance and platform qualification remain open. Managed
storage stays disabled. There is no push, installation or release in this cycle.
