# An old Android camera stop must not touch its successor

Base: `1b69f298`. This is a confirmed local capture-lifetime defect, separate
from the unattributed Windows 10 camera report.

## Evidence

Android device selection and camera OFF detached the native source, awaited
its stop, then read the shared plugin fallback field. During that wait a newer
OFF/ON sequence could publish a working fallback. The old continuation then
detached and stopped the new source while the real CallService still advertised
camera ON. The same selection defect crossed an internal engine rebuild.
With a new native source instead, a superseded selection incorrectly reported
success for that source rather than its own operation.

The tests use real CallService and VeilCallMediaController, controlled native/
plugin sources and an explicit stop fence, without a duration threshold. Six
same-engine cases cover selection/OFF, no successor and native/plugin successor.
Two more cases recreate the media engine while selection waits. On unchanged
base: five assertion failures and three passing controls. An initial fixture
ran out of synthetic factory entries when the bad code tried to restart again;
that exception is excluded. The corrected fixture allows that attempt and proves
the unwanted stop by assertion.

## Change

Device choices and camera intent have a local operation epoch. Selection checks
its original operation, call/media epoch, engine and preference owner after
discovery and at each asynchronous source-retirement/start boundary. The check
precedes reading or detaching shared source fields. OFF similarly checks its
operation/engine/media epoch before touching the fallback or replacing the frame
pump. A late selection returns false instead of adopting a successor's result.

Ordinary selection and OFF still work. New native and plugin capture survive
old completions; the call remains active. No native ABI, format negotiation,
transport, permission policy or media wire change is made. This does not claim
the entire capture-lifetime matrix is complete.

## Qualification and limits

**725 related tests passed, zero skipped**, across sixteen suites covering
direct/group call FSMs and media, Android native startup/stats, plugin selection,
retirement, pending attachment work and diagnostics. With XVEIL_DIAGNOSTICS=true,
**169 tests passed, zero skipped** across the direct Android outcomes, media
startup and diagnostic journal suites. These are overlapping suites, not 894
unique cases. The analyzer reports no issues after three new test-style findings
were corrected.

The selected core/storage binary hashes and 1,144 recorded Rust/Cargo inputs
match their qualified provenance. All fifty hidden-volume binding checksums
match; binaries remain unchanged after testing. No native build is performed.

This is headless service/controller qualification using controlled platform
boundaries, not a physical Android or Windows 10 camera call. It does not prove
the cause of the user's waiting-camera preview or mirrored-image report. No
app windows, focus changes, OS input, installed packages or seeds are touched.
No push or release is performed.
