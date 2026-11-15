# Profile-local source binding for mixed-profile compaction

Managed-storage defaults remain **OFF**. This extends the explicit coordinated
compaction route to a configured profile-local container name; the old route
intentionally refused names other than `xveil.store`. It is not evidence that
the old refusal caused data loss, and does not activate new storage modes.

## Binding and recovery

Normal bootstrap now passes its exact legacy path to the router. The router
retains a validated source leaf and its owner rejects replacements with a
different binding, including after asynchronous publication. The compaction
worker and selected-root reference recovery receive that same leaf.

A version-two recovery intent stores the leaf inside each authenticated private
master volume, never the public identity catalog. Recovery rejects a configured
source mismatch before changing the journal or proving source keys. Version-one
intents remain readable only with their historical `xveil.store` meaning:
accepted recovery obligations must not disappear during this update.

The binding admits only an absolute path beside the managed profile root and a
single bounded, well-formed UTF-8 leaf. Traversal, separators, control bytes and
alternate-stream syntax are rejected. URI-reserved characters and Unicode are
literal filename characters. Ordinary unjournaled managed opens do not inspect
or create a hidden source. Existing private-file/path witnesses, exclusive
ownership, native key/generation proofs and directory durability checks remain
necessary; a matching leaf alone is not authorization or rollback protection.
An injected legacy factory is still a caller-owned capability, not something
the router can inspect; normal main pairs it with the same captured path.

## Qualification

- Sequential default-path/recovery/router/bootstrap/collection regression run:
  **99 passed, zero skipped**, including 19 pure source-name checks.
- Final custom-source native run: **13 passed, zero skipped**. It covers actual
  source publication, a same-key byte-copy shadow at the default name that must
  remain unchanged, wrong configured binding, malformed private intents,
  version-one recovery, replacement-router binding and an absent hidden source.
- Three independent-process death checkpoints cover prepared-but-unpublished,
  source published before external reference repair, and publication before its
  reply. Ordinary bootstrap and authenticated encrypted/plain master opens
  recover the selected custom source. Native identity/roster and payload oracles
  remain exact, not just successful-open checks.
- Full application and changed-test static analysis reports no issues. The
  previously qualified native hidden-volume library is selected explicitly;
  Rust sources and native libraries are unchanged in this cycle.

An isolated normal-main macOS debug package was rebuilt from 3042 verified
product inputs with only QA bundle metadata overrides. Its signature, Dart
kernel and selected hidden-volume/SDK/SQLite libraries were checked. A copy of
an owned synthetic profile used a literal Unicode/percent/hash filename beside
a same-key default-name shadow. Before compaction, both actual native identities
and known note digests matched, with cross-identity note absence. Ordinary UI
compaction changed the selected custom source, preserved the default shadow
byte-for-byte and returned to ready state with a real native node.

Packaged post-compaction identity selection and cold readback are **incomplete**
and are not credited; native process-death qualification above is separate.
The owned QA app was stopped and launcher completion/process/listener absence
checked. The source QA profile was retained unchanged; no user app or container
was replaced. Private identities, paths, credentials and raw logs stay outside
the repository. No push or release.

Windows source-directory durability admission stays guarded. This host run does
not qualify native Windows, physical Android/OEM, power loss, the complete
credential/model/destructive matrix, all-target native pins or release AOT.
Those gates still precede default activation.
