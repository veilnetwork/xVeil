# In-flight audio-route replies must not overwrite newer setup

Base: `9222cbda`. This fixes local CallAudioRouter ordering and state admission.
It does not attribute the reported Windows/phone silence or prove physical
speaker switching on an affected device.

## Evidence

The router applied every late setRoute result and cleared its established state
only after release completed. This allowed a retired result to replace a newer
choice; a new default requested during release could be skipped as already
established; and the old release continuation could then clear the new choice.

Notifier publication also preceded marking the route established. A synchronous
listener requesting a default could reapply it over the user's explicit choice.
A listener releasing the route could have its cleared state resurrected by the
original setter. Superseded errors overwrote current diagnostic evidence.

Sixteen new gate-controlled cases fail by assertion on the unchanged base; the
four existing normal/permission-refusal/headphones/privacy controls pass. Cases
cover bool/category results after release/replacement, late release with manual
or audio/video default setup, native/non-native reentrancy, release errors and
retired PlatformException/MissingPluginException diagnostic replies.

The controlled port changes its synthetic route on command receipt and delays
only replies, preserving command FIFO. Native Android/iOS route handlers remain
unchanged. The tests do not establish that every delayed-reply order occurred
with those handlers on a physical phone.

## Change

Each apply/release owns a local operation epoch. Only the current apply can
publish its route, report success or record its diagnostic outcome. Categorical
native results, bool acceptance and existing refusal codes remain supported.

Release clears the established flag immediately so a new call can configure
its route while the old reply is pending. Native release is enqueued before
notifying listeners, preserving its order before any reentrant setup. The reply
performs no further local reset. Apply marks its route established before
notifier publication and revalidates ownership afterwards.

Two deliberate mutants verify the notification boundaries: notifying before
enqueueing native release causes two order failures; setting the established
flag after publication causes four reentrancy failures. Both are restored
byte-for-byte before final qualification.

## Qualification and limits

**825 related tests passed, zero skipped**, across twenty-four call/media,
camera/video lifecycle, routing, network/grant and widget suites. With
XVEIL_DIAGNOSTICS=true, **235 tests passed, zero skipped** across seven
overlapping suites; counts are not added as unique cases. The final analyzer
reports no issues after test-style findings were corrected.

Selected core/storage libraries match their producer hashes and 1,144 recorded
Rust/Cargo inputs. No native build or native/wire/permission-policy change is
made. Existing headphones precedence, explicit speaker selection, refusal
handling and camera-upgrade route preservation pass unchanged controls.
Diagnostic events reflect current operation outcomes, not a total native-attempt
counter; no raw error/device text or operation identifiers are added.

All checks use headless service/widget tests with TMPDIR=/private/tmp/. No app
window, focus change, OS input, actual device audio/volume operation, recording,
phone/installed-app change or seed operation is used. This qualifies the helper's
in-flight replies, not full caller ownership or physical speech. No push/release.
