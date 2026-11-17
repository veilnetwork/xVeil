# Private macOS release-candidate qualification

Application **0.13.102+121**, Veil **0.11.53** and hidden-volume **2.8.0**.
This is a production-flavor ARM64 AOT build of the ordinary application, with
debug hooks and release logging disabled. It is a private host qualification;
no additional public macOS release asset is introduced by this check.

## Inputs and actual artifact

- Fresh SDK and storage builds use separate external Cargo targets and locked
  dependency resolution. The mount is checked before and throughout each
  build. All **1429** tracked native source/config inputs retain their hashes;
  both optimized builds finish successfully.
- SDK, storage and the source-current media component load together in a fresh
  process. The generated storage ABI/checksums match the current Dart bindings.
  The media component matches its producer SHA and current native source digest;
  all **107** required exports are available. The previous generated staging
  pair is retained privately, and the current qualified pair is staged.
- The neutral AOT builder copies only qualified native outputs into a private
  source workspace, maps package roots and builds the ordinary release. The
  packet-tunnel build uses its separate workspace target. The existing ad-hoc
  no-VPN packaging path is retained; notarization and VPN support are not added.
- The exported Info.plist reports version **0.13.102**, build **121**, production
  bundle identity and minimum macOS **12.0**. Runner and AOT snapshot are ARM64.
  The actual App.framework contains both Dart VM and isolate snapshot instruction
  symbols; no debug kernel blob is present. Deep strict signature verification
  succeeds.
- All **five** bundled native libraries load in a separate process, and storage
  ABI verification succeeds. Core, storage and media retain their producer
  Mach-O UUIDs after packaging; their final binary digests are recorded privately.
  UUID comparison supplements source/byte staging evidence, rather than replacing
  it with an ABI-only or symbol-presence claim.

## Privacy and boundaries

The neutral artifact scan checks **130 members / 134505115 bytes**, with zero
source-home URI or current-home path occurrences. The primary publication
scanner passes the configured literal checks. A separate printable-text scan
applies both configured regular expressions, including UTF-16 text, to the same
130 entries and finds no matches. Pattern contents, operator paths, raw logs,
source inventories and external debug symbols remain outside the repository.

The temporary AOT workspace is removed by the builder. The exported application
is not launched or installed over the user's running application. No microphone,
camera, system input or focus operation is performed. These checks establish
compilation, packaging, ABI/loadability and privacy; they do not establish a
physical call, visible Windows toast, the Windows 10 camera cause, or complete
multi-device qualification. Final dependency/application publication and seed
deployment remain separate steps.
