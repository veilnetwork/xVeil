# Native contact exchange across storage modes

Base: `62bc2aee`. This extends the existing native avatar/contact pair fixture;
it changes no production code and does not attribute the reported Windows 10
one-way handshake failure.

## Qualification

Four scenarios pass, with zero skips:

| Storage on A / B | Request flow |
| --- | --- |
| hidden / hidden | Ordinary request and acceptance |
| hidden / hidden | Crossed requests, one acceptance |
| encrypted / unencrypted | Ordinary request and acceptance |
| encrypted / hidden | Crossed requests, one acceptance |

Each uses two fresh, unrelated sovereign identities, the real embedded native
stack, transport, messaging service, ratchet and authorization persistence.
There are no injected incoming messages or fabricated accepted contact rows.
Each exchanges four distinct messages: both directions before and after B's
node restart. The checks require the expected body, author, direction, delivery
receipt and exactly one incoming service event during each exchange window.
Signed avatar exchange, update, clear and authenticated refresh remain covered.

Every boot constructs a new storage facade. After both nodes stop, independent
readers reopen both stores by password and verify the sovereign material,
accepted contacts, persisted ratchet keys and all four message witnesses per
peer, including IDs, status and absence of duplicate rows. Across the four
scenarios this is **16 distinct messages and 32 stored message copies**, inspected
through eight independent readers. These counts describe one four-scenario run,
not repeated trials or a latency benchmark.

The inspector also checks the actual backend layout: legacy hidden container,
encrypted keybox/content, or plaintext data store. The three managed stores
reject an attempt to open them as the opposite managed mode. A controlled
fixture-only legacy fallback completes the contact workflow but fails the
cold layout assertion, without emitting final success. That negative control
exits with one assertion failure; the source is restored byte-for-byte and its
owned failed fixture is removed after its process group exits.

## Reproduction and provenance

Run `test/native/profile_avatar_native_pair_test.dart` with
`TMPDIR=/private/tmp/`, `XVEIL_AVATAR_PAIR_NATIVE=1`,
`XVEIL_AVATAR_PAIR_STORAGE_MATRIX=1` and verified `VEIL_FFI_DYLIB` /
`XVEIL_HV_DYLIB` libraries. Without the second opt-in, the two new managed cases
are explicitly skipped. Unix uses private loopback; the existing Windows fixture
requires an explicitly selected owned IPv4 interface instead.

The final frozen-source run passes all four cases and the analyzer is clean.
All **1,956 Dart and package-manifest inputs** retain their pre-run hashes.
The native libraries match their producer hashes and **1,144 Rust/Cargo source
inputs**; all **50 hidden-volume ABI checks** pass. No native library is rebuilt,
and no dependency or engine pin changes.

## Limits and cleanup

This is a single-process macOS JIT test with local native nodes, explicit storage
bindings and graceful node stop/restart. It does not qualify onboarding/catalog
selection, a killed process, power loss, relays, NAT, provider restrictions,
Windows 10, GUI history rendering, or linked devices of the same identity. It
does not complete the multi-device matrix or change own-device mailbox policy.

All nodes, storage workers and test processes exit. Runtime directories are
empty and recorded UDP/metrics listener ports can be rebound before successful
fixture removal. No desktop windows, OS input, microphone/camera, phone install,
user container or seed changes are used. The existing user app remains running.
No push or release.
