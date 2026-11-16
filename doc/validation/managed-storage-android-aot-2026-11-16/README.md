# Android managed-storage release/AOT qualification

Status: ARM64 release APK compilation, provenance/privacy checks, ordinary
first launch and encrypted-default creation pass on an isolated Android 15 AOSP
emulator. Saved Messages visibility is an **open observation**, not a successful
persistence check. Production managed storage remains disabled.

## Artifact and execution boundaries

The normal application entrypoint was compiled as release/AOT with managed
storage enabled and testnet selected. Neither the debug HTTP hook nor raw release
logging was enabled. The APK has a separate QA application ID and uses the
existing explicit permission for debug signing; it is not a distributable release.
All 3,045 tracked product inputs were compared with the source worktree, with
only application ID/label substitutions in the isolated copy.

The exact previously qualified overlay and storage native inputs were reused
only after comparing the recorded source closure with the current checkout.
Veil's tracked inputs were unchanged. The hidden-volume revision difference
contained Dart bindings/tests and documentation, not changed native producer
inputs. The current Dart bindings themselves were copied and compiled. The
unchanged qualified media input was also retained. Whisper's static libraries
and wrapper were built anew from its clean pinned upstream revision, with native
path maps and a separate external build directory guarded by actual mount and
free-space checks. No mandatory release library check was disabled.

Verification covered the APK signature, isolated namespace/activity, ARM64-only
packaging, Dart AOT snapshot symbols, absence of a JIT kernel and SQLite native
asset mapping. Five native payloads—overlay, storage, media, speech and pinned
SQLite—matched independently stripped reconstructions of their selected input
bytes. Both the complete home-path scan and the existing boundary-aware private
pattern scanner passed; the latter scanned 467 entries. A first scanner command
incorrectly supplied a file where its CLI expects a directory and failed closed;
only the corrected non-empty scan is credited.

The APK was installed only in a new, **headless** AOSP emulator. No emulator or
application window appeared on the host desktop, and no physical phone, existing
profile or installed Mac application was modified. System image/tool resources
were reused; writable AVD state was separately owned by this run.

## Ordinary creation and the open Saved Messages case

Normal virtual-screen input drove welcome, identity minting, the actual Android
document-save picker, storage choice, network policy and password entry. The
certificate's full identity ID matched the drawer's identity. The storage choice
was deliberately left untouched. After creation, the app reached Chats, and the
actual SQLite catalog contained exactly one encrypted identity. Network
discovery was deliberately declined, so this is not a network-traffic test.

In Saved Messages, a unique body was observed in the real text field before Send.
After Send the field cleared, but the body was absent from both repeated UI
hierarchies and the virtual display. The closed Android data and private evidence
were retained. This proves the **visibility symptom**, not data loss. Initial
input without a verified field precondition is excluded from the send oracle.

An attempted host read of the pulled Android-store snapshot refused worker
admission. That refusal is not evidence that the original Android store is
damaged, and it is not credited as a cold-readback check. An adjacent candidate
is the distinction between identity and device addresses: the drawer/chat uses
the application identity for Saved Messages, whereas the local-note service
uses its transport/device address. The actual stored bucket and cause still need
verification; changing a storage namespace or rewriting old notes on this
hypothesis would be premature.

## Selection accessibility fix

The Android hierarchy also exposed a separate confirmed UI defect: all three
protection choices reported `selected=false`, including the chosen encrypted
default. Color and a check icon did not provide a selected semantic state.
`StorageProtectionChoice` now supplies the real selected value to its `ListTile`.
No storage selection, encryption, catalog or network policy was changed.

A corrected regression fixture fails on unchanged product code, then verifies
exactly one selected semantic state for the default and after each mode change.
The **17-check, three-suite host run passes with zero skips**, and analysis is
clean. Fixture cleanup, an incorrect test filename and the transition from the
deprecated Boolean flag API to tri-state semantics were corrected separately;
those setup failures are not product failures. The Android APK above predates
this one-line fix, so its packaged requalification remains separate.

## Remaining scope

Investigate Saved Messages through the real Android owner before calling this
platform's data/persistence qualification complete. All-mode cold readback,
maintenance/recovery and real OS-vault/OEM checks remain separate; this run does
not replace the earlier debug-mode qualifications. Owned virtual app/emulator
processes are stopped and their synthetic data retained privately. No push,
official signing, production-default change or release was performed.
