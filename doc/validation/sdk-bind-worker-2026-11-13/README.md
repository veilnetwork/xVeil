# Keep endpoint binds off the calling Dart isolate

Status: **confirmed mechanism, released in Veil 0.11.52 and xVeil 0.13.101+120**.
[Release qualification](../release-0.13.101-2026-11-13/README.md).
Native bind implementation, ABI, wire format and timeouts are unchanged.

## Failure and scope

`VeilClient.bind`, `bindNamed` and `bindDeviceScoped` deferred their blocking FFI
call with `Future(() {...})`. That callback still ran on the originating Dart
isolate. Native bind takes the SDK client lock and waits for an IPC reply; the
reply timeout is 30 seconds after enqueue, and earlier lock/write waits can add
time. Timers, UI and Dart-side media handling cannot run during a synchronous
native wait on that isolate.

xVeil uses these paths while connecting identity transports and lazily creating
media feedback senders. This confirms a dispatch defect, not the cause of the
historical mobile NETCALL-01 interruption. No production 30-second bind stall or
hardware handover improvement is claimed.

## Change

A top-level worker performs the same bind on an isolate. Only the opaque handle
token, strings and scalar options cross the boundary. The awaited method retains
the `Finalizable` client; the worker frees its UTF-8/error allocations and returns
only the native app token. `AppHandle` and its finalizer are created back on the
originating isolate. Live callback owners are not transferred.

Native success and refusal remain authoritative. A bind admitted before parent
close can still return an owned app; the wrapper does not discard that successful
result or manufacture success after a refusal. Calls made after Dart client
close are rejected before entering native code. Bind itself still awaits IPC;
this is not a faster reply, timeout relaxation or routing change.

## Evidence

- All **12 controlled baseline cases** fail at the event-loop assertion using
  the immutable released wrapper in a separate package mapping. The working
  source is never replaced. Success requires release from a timer on the caller
  isolate; the two-second native deadline only prevents a hung test. No elapsed
  threshold is used to make a passing assertion.
- The candidate passes all 12: ephemeral/named/device-scoped binds, each with
  success, native refusal, parent-close refusal and admitted success after parent
  close. Checks cover live callback ownership, UTF-8 arguments, endpoint/app IDs,
  error code/message, exactly-once error free, app close and parent close.
- Full SDK suite: **81 passed, 6 skipped**. Application reconnect, call service,
  route operations/qualification, receive activity, network activity and endpoint
  service suites: **358 passed, zero skipped**. Scoped analysis and formatting pass.
- Host **macOS ARM64 AOT: 12/12** controlled cases pass with a live callback owner.
  This is a standalone optimized probe, not Android or full-application AOT
  qualification.
- **One real local IPC/media test passed**, exercising product transport binds,
  independent media senders and channel teardown. Its native library matches the
  saved qualified release SHA and Veil source `952e0c292eb8`; native sources and
  ABI are unchanged. The embedded node is disposed and the test process exits.
  No microphone, camera, user container or production relay is used.

Private logs, baseline/AOT source digests and native-library provenance are kept
outside the repository. This report contains no operator addresses, account
labels, live identifiers, local paths, raw logs or correlation tokens.

[Wrapper](../../../third_party/veil/flutter/veil_flutter/lib/src/client.dart),
[native bind](../../../third_party/veil/crates/veilclient-ffi/src/lib.rs),
[IPC wait](../../../third_party/veil/veilclient/src/client.rs),
[product callers](../../../lib/data/transport/veil_flutter_transport.dart),
[controlled tests](../../../third_party/veil/flutter/veil_flutter/test/bind_worker_test.dart),
[real IPC/media test](../../../test/native/media_secondary_sender_live_test.dart).
