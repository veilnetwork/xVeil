# Retired publication and mailbox experiments

The remaining publication-pause experiment could suppress rendezvous ads and
DHT republishing. With `VEIL_PUBLISH_PAUSE=1`, the existing signed-ad test failed
before the change: zero ads were published instead of one. A real embedded
stream-receiver fixture also failed when the legacy FFI setter was enabled.

## Changes

- Removed the session pause state, environment switch and both publication
  guards. The DHT scheduler and ad freshness rules retain their normal behavior.
- Retained `veil_debug_set_publish_pause(int)` as an inert C symbol. Removed
  its Dart binding/export and the `/publish_pause` HTTP hook.
- Removed `/mailbox_pause`, its static service reference and debug alias.
  Normal call coordination through `backgroundDrainPaused` remains, including
  prompt draining after a call releases the gate.
- Retained opt-in tracing. This cleanup changes no media codec or relay policy.

## Verification

| Check | Result |
|---|---|
| Rendezvous publication tests with `VEIL_PUBLISH_PAUSE=1` | 5 passed |
| Legacy FFI setter plus real signed stream-ad publication, same environment | 1 passed |
| Mailbox burst, orchestrator and messaging outbox tests | 81 passed |
| Dart ABI checks against the freshly built macOS production-feature library | 4 passed, none skipped |
| macOS production-feature Rust library | Release build passed |
| Header and Rust/Dart contract regeneration | Stable on repeat |
| Rust formatting, changed Dart analysis, whitespace checks | Passed |

The embedded fixture verifies the stored ad, signature, receiver and relay;
it stops its runtime before checking the final result. Both negative controls
failed assertions with the preceding production implementation, rather than
failing compilation. Test data is synthetic; this is not a physical call or
an acoustic-quality check.

The generated header includes documentation in its contract hash. Updating
the compatibility function's documentation therefore changes that hash even
though its C signature remains identical. Native libraries and Flutter
frontends must be rebuilt together; the preceding QA APK/app remains an older
snapshot and must not receive the new library in isolation.

No GUI app was launched, no installation attempted, and no device permissions
or system settings changed in this cycle. The phone was absent from both ADB
and the host USB device tree. Physical installation, video-ramp validation and
file-transfer checks remain pending. Rust builds ran on the external target
filesystem with mount monitoring; no mount loss occurred.

Public evidence contains no device IDs, network addresses, credentials,
message contents, audio or images. Detailed test and build logs remain private.
