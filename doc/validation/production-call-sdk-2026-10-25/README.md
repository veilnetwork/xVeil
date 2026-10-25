# Production SDK qualification after call-route repairs

SDK commit: `325e36e0`, including the preceding per-call fallback ownership
repair. This cycle changes no production source code.

## Production builds and QA packages

Built macOS arm64 and Android arm64 release libraries with
`--no-default-features --features node-embedded,production-seeds,packet-tunnel`.
The external Rust target stayed mounted throughout both monitored builds.
SDK and crypto release fingerprints independently confirm that
`test-low-difficulty` is absent. Rust/Cargo input hashes match before and after
the builds and the committed checkout.

The coherent earlier QA frontend was reused after verifying every production
Dart library hash against the current checkout and checking that the SDK's
Dart/native plugin source had not changed. Its diagnostic frontend label
predates this SDK patch; these packages are QA artifacts, not a published
application release.

- Mac: replace only the FFI library, update its loader ID, ad-hoc sign and
  verify the complete bundle.
- Android: replace only `libveilclient_ffi.so`, retain all other native-library
  hashes, align the APK to 16 KiB, sign and verify it. The FFI ELF LOAD segments
  also have 16-KiB alignment. Android compilation used NDK 28.2/API 21.
- No installation on the phone was attempted: ADB had no connected devices
  during this cycle. The APK is prepared for the next physical check.

## Mac application: anonymous-mode restart and stream warmup

Created a separate QA profile by cloning the closed, encrypted QA store, then
launched the packaged application with `TMPDIR=/private/tmp/`. Through the
existing authenticated debug API, unlocked that clone, changed its routing to
onion, waited for a real ready stack and warmed the stream service.

| Measurement | Result |
|---|---:|
| Anonymous-mode restart to ready | 883 ms |
| Toggle invocation to confirmed stream receive opening | 5,933 ms |
| Additional observation window | 15 s |
| Receive openings / refreshes / expansion cycles | 1 / 0 / 0 |
| Anonymous setting still active at the end | Yes |
| Identity preserved | Yes |

The first private-helper attempt looked for the API key in the runtime root,
while the application correctly placed it in its owned child directory. That
attempt timed out before unlock; its process exited and its clone was archived
before correcting the helper. No application regression was established.

The original QA profile's two files still hash identically to the pre-unlock
copy. The successful anonymous clone is archived separately for later tests.
No call, audio or camera was exercised by this application warmup.

## Real anonymous calls using the production SDK

The same macOS production FFI library was then loaded by three separate app
worker processes. A/B share an identity and C has another. The fixture supplies
canonical pre-mined identities; app workers use the production SDK's normal
PoW checks. The relay CLI is the existing development island binary, configured
to forbid public seeds and other discovery. That CLI is not bundled into the
QA app. The media and hidden-volume libraries match the preceding native-call
qualification.

| Scenario | Ringing observed | Caller observed answer after accept invocation | Five audio RTP packets on both |
|---|---:|---:|---:|
| C calls A/B; both online; B answers | 38 ms | 3,730 ms | **4,143 ms** |
| Repeated call after A stops; B answers | 23 ms | 40 ms | **450 ms** |

In both calls, actual `audio_rx_pkts` continued growing on both endpoints for
another five seconds and hangup reached the peer. In the first call the
unselected A ceased ringing; A was offline in the second. There was no
explicit C-to-B session join. No impossible inbound
expansion or circuit-install refusal occurred during the fixture.

Answer timing includes waiting for the accept API before polling the caller;
it does not isolate signalling network latency. These are local native
processes with real codecs and encrypted transport, not a physical Android
call. Positive packet counters do not establish speech audibility, loudness
or uninterrupted playback. Physical phone and live-speech checks remain open.

## Cleanup and evidence

Both Mac application attempts were independently verified exited. Their owned
runtime directories were removed and their QA clones archived. The native
three-device run also passed cleanup: five groups/nine PIDs checked, zero
remaining processes, private stand directory removed. Five old generated
compilation directories from the deliberately killed crash-writer fixture were
attributed by their exact test import, checked for open handles, and removed,
reclaiming 1,034 MiB. Main applications, user profiles and relay configurations
were not modified.

[summary.json](summary.json) and [native-call-results.json](native-call-results.json)
contain only software hashes, fixed role labels, relative durations and
verification status. Identities, addresses, keys, absolute native timestamps,
capture labels, raw logs and media remain private.
