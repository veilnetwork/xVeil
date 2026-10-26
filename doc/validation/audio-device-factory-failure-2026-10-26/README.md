# Audio-device factory failure

Local correction in Veil `db079340`. No release, push, deployment or installed
app update was performed.

## Confirmed defect

The platform audio-device factory is nullable. The pinned WebRTC implementation
can refuse construction after platform checks, backend creation or audio-buffer
attachment fails. Both the direct and group media constructors nevertheless
passed its null result to AudioState, whose contract requires an audio-device
module.

With that factory failure injected, the real release WebRTC engine crashed in
`AudioState::AddSendingStream` when direct audio started. The crash was
EXC_BAD_ACCESS; raw system crash data remains private. A separate controlled
regression verifies that both constructors must refuse the invalid state.
Before correction they returned engines on both attempts; that assertion failed.
The test compiled successfully and its failure was behavioral.

## Correction

Both constructors now return null immediately after the platform factory
refuses, before constructing AudioState, native calls, streams or receive
callback registrations. Partially created task queues are released by their
existing owners. Logs add only a constant backend-unavailable reason.

The existing Dart bindings handle a null engine as creation failure. The direct
call controller closes its caller-owned media channel and returns failure;
the group controller returns before opening peer channels. The C header now
documents the factory-failure result and channel ownership. Device routing,
permissions, transport policy, relay scheduling and media wire formats are
unchanged.

## Validation

- The same constructor-refusal regression passed after correction, including
  two failed creations for each engine type.
- After the factory recovered, both engine types started real WebRTC audio on
  the counting test device, recorded/played and emitted Opus RTP. Reusing the
  direct channel succeeded, and the test boundary retained no callbacks.
- The full core call-plane smoke in adaptive-audio mode passed, covering the
  existing direct/group media, mute, routing, budget and queue cases. The
  group playout-recovery smoke also passed.
- The normal production library built against the pinned WebRTC toolchain.
  All 105 exported media functions matched the preceding production library.
  No test exports or missing-device factory switch appeared in that binary.
- Source hashes remained unchanged during verification; the committed SDK tree
  was checked against the native build proof. All probe/check process groups
  were verified absent afterwards. Main apps and profiles were untouched.

The fault injection is confined to the existing test-only native fixture and
is compiled out of production. Public evidence contains only aggregate results;
raw logs, crash metadata and local paths remain outside the repository.

This proves safe handling of a refused audio backend. It does not establish
that this condition caused the reported Windows 10 failure. Actual Windows
execution, physical speech/loudness, one-way signaling and slow file transfer
remain outside this qualification.
