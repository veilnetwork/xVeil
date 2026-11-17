# Media-session teardown must retain its own resources

Base: `fcb2b88b`. This fixes a local controller teardown/start family. The
original Windows 10 camera/notification/handshake reports remain unattributed.

## Evidence

VeilCallMediaController detached a native camera/renderer, awaited its stop and
then read the shared fallback, engine and channel fields. A second start could
find and free the old engine before that native fence completed. Once a new
session existed, the first teardown resumed against the new fields: it disposed
the new engine, closed the new channel and could stop its plugin camera. Its
final release also removed the new session's network hold. Audio-stop itself
was delayed behind the original native stop reply.

A same-call rebuild exposed another boundary: start claimed mediaEpoch only
AFTER awaiting the old teardown. An older start could resume after a successful
same-call replacement and allocate a third engine over it. Call-id equality did
not distinguish these operations.

Eight committed controlled cases fail by assertion on the base: five teardown
cases (no successor; native/plugin successor with same/new call id) and three
pending-rebuild cases (same/new call or stop). They observe commands, native-stop
reply timing, engine disposal counts, exact closed channels, source stops and
network ownership. A preliminary fixture failed to compile because Call.copyWith
does not change callId; this is excluded from evidence. The corrected fixture
constructs a new call snapshot explicitly.

## Change

Teardown captures and detaches its engine, channel and source references before
its first await. Remaining disposal uses only those captured owners. Audio stop
and channel close happen promptly; video/engine disposal still awaits the
captured native Camera2/Surface detach replies. Plugin/screen retirement is
joined, and consented screen capture remains available for an internal repair.
State reset precedes notifier publication, whose listeners may be reentrant.

The old teardown releases shared routing/network/microphone resources only while
its media epoch remains current, including checks between awaited releases.
A replacement can proceed with its resources while the retiring engine remains
owned by its fence-bound continuation.

Start also claims a request epoch before its first await. A subsequent start or
stop invalidates the older request even when callId is unchanged. A start's own
initial teardown preserves its request; both the pre-engine continuation and the
existing preflight checks validate it.

Two deliberate mutants qualify the boundaries. Ignoring the start request
produces one late-rebuild assertion failure. Removing the shared-release scope
produces four network-ownership failures, with the no-successor control passing.
Both mutants are restored byte-for-byte before final diagnostic qualification.

## Qualification and limits

**800 related tests passed, zero skipped**, across twenty-four suites covering
media startup, direct/group call controllers/FSMs, native camera/video lifecycle,
plugin retirement, widget rendering, network/microphone grants, audio routing
and route operations/qualification. **206 tests passed, zero skipped** with
XVEIL_DIAGNOSTICS=true across six overlapping suites; counts are not added as
unique cases. The analyzer reports no issues after a new test-style finding was
corrected.

The selected core/storage libraries match their producer hashes and 1,144
recorded Rust/Cargo inputs. No native build or native/wire/permission-policy
change is made. Platform boundaries are controlled: the tests prove controller
commands and lifetime ordering, not physical sound/video, a Windows 10 device,
or the entire lifecycle matrix. Source retirement already detached by another
pending command and reentrant global audio-route releases need separate review.

All tests are headless with TMPDIR=/private/tmp/. No app windows, focus changes,
OS input, installed-app/phone changes or seed operations are performed. No push
or release is performed.
