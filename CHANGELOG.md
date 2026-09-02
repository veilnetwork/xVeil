# Changelog

All notable changes to xVeil are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
versioning follows [SemVer](https://semver.org/). The app is pre-1.0: minor
bumps may change behaviour a user notices.

Each release pins the two projects it is built on. Those pins are part of the
release: an app version means nothing without knowing which network and which
storage it was built against.

## [0.13.25] — 2026-09-02

### Changed

- hidden-volume 2.1.2: an index node whose entries are out of order is refused
  rather than written — the encoder used to check that with a debug assertion,
  so a release build produced a chunk it could not read back and a debug build
  aborted the process. And the key-or-pair a paginated walk is holding when it
  stops at a full page is now wiped: the tail scrub only reaches what is still
  inside the iterator, and that one had already been handed out.

## [0.13.24] — 2026-09-02

### Changed

- veil 0.11.8: the VPN tunnel's traffic report never goes backwards. The
  running totals and the timestamp of the last report were separate locks, so
  two threads updating at once could each decide to report and the one holding
  the smaller total could arrive second — a counter that only grows, seen going
  down, and a negative delta for anything computing one. One critical section
  decides it now.

## [0.13.23] — 2026-09-02

### Changed

- hidden-volume 2.1.1: a fast container open no longer answers with the
  superseded one of two superblocks sharing a sequence number. Three of the
  four scan loops walk slots low to high and the shared rule was written for
  them; the reverse scan walks the other way, so keeping the "last seen"
  payload kept the EARLIER slot — in the one loop whose answer a fast open
  returns. Only reachable in a container an older build wrote, and the full
  scan still corrects it.

## [0.13.22] — 2026-09-02

### Changed

- veil 0.11.7: a conversation's exported ratchet state no longer outgrows the
  buffer it is written into. The reservation was 38 bytes short of this
  format's own worst case, so on every established conversation the buffer grew
  mid-write — and a buffer that grows copies what it holds into a new
  allocation and abandons the old one, which by then holds the DH secret, the
  root key and both chain keys. Only the buffer that comes back is zeroized.

## [0.13.21] — 2026-09-02

### Fixed

- **A call service that belongs to a departed identity answers nothing.**
  Detaching a handler stops the NEXT signal and does nothing about one already
  in flight — and the relayed lane awaits `isOwnDevice`, which reaches storage
  and can reach the network. A stranger's ring was answered on the pipeline of
  an identity the user had left, `busy` reject included. Every lane comes
  through one door now, and that door asks (report21 XV20-L2).

- **A call that has ended is not still the current one.** Ending leaves the
  same call in `current` with `status: ended` — the banner and the record of
  who was in it survive on purpose — and the "is this still my call" check
  compared only the three ids. So a start parked on its announce broadcast came
  back to a room that was over, was told it was current, and went on to arm the
  heartbeat and re-announce timers and ask for media for a room nobody is in.
  The two admin end paths reach the teardown through the same check, which
  without this ran it a second time (report21 XV20-L1).

## [0.13.20] — 2026-09-02

### Fixed

- **An answer about this device's models is not sent after the identity moved
  on.** Detaching the handler on dispose stops the NEXT request and does
  nothing about the one already running — by the time it reaches the send it is
  a preference read and two directory scans deep. So an answer begun under one
  identity was still delivered afterwards, on that identity's pipeline,
  telling the contact what the identity the user had left keeps on disk: to
  that contact, the two answered from the same place.

  Worse than a leak, as the test written for it found: the roots are resolved
  through the provider `Ref` that built the service, and a `Ref` used after its
  provider is disposed THROWS — so the parked answer raised out of a messaging
  callback with nobody to catch it (report21 XV18-L3).

### Changed

- veil 0.11.6: every rendezvous publisher registration goes through the one
  bounded admission. The runtime entry point kept its own copy of "replace or
  push" and so kept neither the slot bound nor the rule that a KEM-less
  re-registration must not erase the key the app supplied — both fixes from
  0.11.3, both reachable around through that door. Setting a relay key now
  clears the expiry of the key it replaces.

## [0.13.19] — 2026-09-02

### Fixed

- **An export cannot hand out the plaintext of an identity the user has left.**
  The fail-closed boundary added in 0.13.16 covered the writes, and an export
  writes nothing: it READS. The native save dialog is the window — it belongs to
  the platform and stays open as long as the user wants — and a switch while it
  is up left the captured service fetching one identity's bytes and copying
  them, in clear, to a path chosen while looking at the other. Fetching content
  and reading a content range now refuse on a closed service, and the export
  asks again the moment the dialog returns (report21 X21-H2).

- **A departed identity does not hand out its recovery capability.** Exporting
  a recovery certificate produces the certificate AND the code that together
  reconstruct that identity's signer — a long-lived capability, not a session
  secret — and the sheet that displays them stays on screen across a switch. A
  user could type their secret under one identity and be shown the other one's
  pair. That export, and device linking beside it, now consult the same dispose
  flag the device-group writes already do.

## [0.13.18] — 2026-09-02

### Fixed

- **An operation cannot outlive the identity that started it.** Switching
  identity in all-online mode re-points the view and leaves every node running,
  so nothing that snapshotted the session's lifecycle noticed: a screen holding
  a service kept working against the identity the user had left. There is now
  an identity epoch, moved by the one setter every switch goes through, and an
  `IdentityLease` a screen takes before its first await and checks after it. A
  lease does not survive a switch in either direction — including a switch away
  and back, where the label is equal again but every service behind it has been
  rebuilt (report21 X21-H2).

- **A file picker that outlived its identity registers nothing.** Both Space
  media helpers awaited a file dialog — which hands control to the platform for
  as long as the user wants it — and only then read the messaging service. The
  blob was registered against whoever was active by the time the dialog closed,
  while the caller went on to sign a row in the Space it started in: a signed
  row naming content only the other identity can read. Both now take the
  service and the lease before the picker and check the lease after
  (report21 X21-M1).

- **The add-contact sheet closes rather than finishing under the wrong
  identity.** The invite on screen is one identity's, and every callback waits
  on something slow — a redeem, a name resolve, the user reading a QR code off
  another phone. A switch in any of those windows sent what followed to whoever
  was active by then: a nickname written into the other identity's store, and
  `/chat/<peer>` opening one identity's contact inside the other's view, which
  is the two of them linked on screen by us. The sheet holds one lease and
  abandons quietly when it goes stale (report21 X21-M2).

## [0.13.17] — 2026-09-02

### Changed

- veil 0.11.5 and hidden-volume 2.1.0. veil stops the disk cold tier from
  reading an I/O error as "the value is gone" — every repair it makes is a
  delete decided by a read, and one transient failure was enough to take the
  index away from a value that was perfectly alive. hidden-volume stops the
  finalizer killing a worker parked inside a native call (the container's lock
  then stayed held until the app restarted) and carries entry counts in a width
  32-bit Android cannot truncate.

## [0.13.16] — 2026-09-02

### Fixed

- **A daemon reads the meeting-point choice the app wrote.** Booting an
  identity resolved only the bundled-seeds answer from its own space; the
  meeting points and the policy arrived as nulls and veil was left at its own
  `all` / `fallback`. So an identity whose owner had turned meeting points off
  — or pinned a subset, or asked for `always` — went back to asking the public
  DHT and the relays the moment the same store was opened without a GUI. Both
  are resolved beside the seeds answer now, on the same rule and for the same
  reason (report21 X21-H1).

- **A service that belongs to a departed identity refuses changes.** Closing
  is what an identity switch does to the service it leaves, and a screen that
  captured the old one keeps working: a file picker still open, a note editor,
  a recovery sheet. Those callbacks went on writing into the store of the
  identity the user had already left, while the interface of the identity they
  were now looking at reported success. `CloudService` fails its mutations
  closed, and the two `GroupService` writes that install credentials or post
  to a device group consult the dispose flag whose stated purpose is exactly
  this (report21 X21-H2).

  The other half of that finding — closing the modals and pickers a switch
  leaves open — is not in this release. What lands now is the fail-closed
  boundary: the user sees the operation fail instead of succeeding into the
  wrong identity.

- **Closing a translation engine releases the model.** `close()` killed the
  isolate, which frees the Dart heap and nothing else: the CTranslate2 model is
  a C++ allocation owned by the process, and the one call that releases it sat
  in a port callback nothing ever triggered. Every model the app opened stayed
  in memory until the process ended, so importing and removing a large pair a
  few times walked memory up to pressure. The worker is now asked to release
  it, acknowledges, and is killed only if it does not answer within five
  seconds (report21 X21-M3).

### Changed

- veil 0.11.4 and hidden-volume 2.0.7. veil closes the meeting-point address
  filters (a v4 address written as `::ffff:…` stepped around every private and
  loopback refusal), reads local discovery on both IP families, publishes the
  port a listener actually bound, and claims a rendezvous slot on terms its
  caller can see. hidden-volume reserves the Argon2 working buffer fallibly, so
  a header naming the 512-MiB ceiling can no longer abort the process that
  read it.

## [0.13.15] — 2026-09-02

**The meeting-point controls now reach the node they claim to configure.** An
ordinary boot read the per-identity answer and then called `startDeniable`
without it, so a one-active identity ran on veil's defaults whatever was
ticked; the all-online path carried both fields to the stack and lost the
policy on the way to the composed TOML, so "keep looking once connected"
silently stayed "only while it has no peer". Found by report20, and the screen
had been offering a privacy control the ordinary path did not carry out.

Underneath, veil 0.10.4: a listener the operator marked hidden is no longer
published at a meeting point, `bootstrap = false` no longer announces on the
local network, and an address from a public index is not dialled unless it is
globally routable.

## [0.13.14] — 2026-09-01

Node side only, and both of them are things production found rather than the
test suite. A node no longer re-dials peers it is already talking to — an
inbound session reports our own listener as its address, so recognising such a
peer needs its identity, not its address — and a `veil-cli` run as the daemon
no longer dies of SIGPIPE when a relay closes a socket on it.

## [0.13.13] — 2026-09-01

**A third place to look for the network.** veil grew a Nostr meeting point, so
the network screen offers it alongside the DHT and the local network. It works
where the other two are blocked, because it is ordinary web traffic on 443, and
its line says what that costs: the relays you ask learn the address this device
connects from.

The guard that kept the app's list matching the node's already counted them; it
did not require a LABEL, and both switches fall back to the raw config key and
an empty subtitle. A point added and half-wired would have rendered as the word
`nostr` with nothing under it — a tick box labelled only with a name makes every
option look free. Now guarded.

Underneath, veil 0.10.0: a node can now join a network it finds, not only find
it.

## [0.13.12] — 2026-08-30

An audit release: nine confirmed high findings from report18, and the guards
that let them through.

Built on veil [v0.8.5](https://github.com/veilnetwork/veil/releases/tag/v0.8.5)
and hidden-volume
[v2.0.6](https://github.com/veilnetwork/hidden-volume/releases/tag/v2.0.6),
with the Windows and Linux engines at `engine-2026.08.29.9`.

**Nothing acts as an identity the app has already left.** One shape, found in
six places, all of them across the same boundary: a request or a screen or a
service starts under identity A, awaits something, and finishes after the app
has moved to B.

* The local API handler captures its token list once, so it keeps
  authenticating A after a switch — that is deliberate, and it is why every
  callback must ask whether the app has moved. Twelve did. `setWebhook` did
  not, and it pointed B's event feed — sender ids, message previews — at a URL
  A's bearer chose. Nor did the five group-call callbacks (A's bearer could
  start a call as B and read B's participants), nor five reads that answered
  with B's node id, B's invite, B's webhook URL and B's live call.
* Both chat screens capture their storage and messaging pipeline on open, with
  a comment saying why — and twenty places did not use them. Three run after a
  FILE PICKER, the longest await in the app: bytes chosen under A were sent
  through B.
* The managed-node registry published A's hosts, users and TOFU host-key
  fingerprints into B's live state, and from there into B's container.
* Folder sync published A's pairs into B's state and handed them to B's
  scheduler, which is one watcher event away from uploading A's local files
  into B's cloud.

**A call ends when the call ends.** Both call services already re-checked after
their awaits — and every one of those checks passed after teardown, because
teardown cancelled the timers, released the global call slot, and left the call
itself in place for the continuation to find. So an offer, an answer, a
heartbeat and a microphone could all start from a service whose identity was
gone and whose slot already belonged to its successor. Teardown now clears the
call and nothing publishes after it. On Android, enabling screen share stops
the camera first, and a hangup landing in that gap found nothing to stop —
capture then started on the far side of the boundary the hangup drew.

**Three guards were green while all of this was true**, and each for the same
kind of reason: they enumerated instead of deriving. The API guard listed eight
callbacks by hand, so a ninth was unbound by omission. The chat guard counted
the exact string `ref.read(...)` and never saw the twenty that `dart format`
wraps across two lines. All of them now read the source and ask a question of
every entry, and the two deliberate exceptions carry their reason rather than
just their name.

**CI runs by itself now.** Until today the first thing that looked at an xVeil
commit was the tag built from it: `analyze` and the test suite lived only in
the release workflow. The reason was an Actions-minutes budget that does not
apply to a public repository. All three projects now gate every push, and each
carries a check that its triggers name a branch that exists — veil's full CI
had been dispatch-only since May, and hidden-volume's per-push gate was aimed
at `master` on a repository whose default branch is `main`, so it had never
once run.

## [0.13.11] — 2026-08-30

Windows on ARM, natively.

Built on veil [v0.8.4](https://github.com/veilnetwork/veil/releases/tag/v0.8.4)
and hidden-volume
[v2.0.5](https://github.com/veilnetwork/hidden-volume/releases/tag/v2.0.5), with
the Windows and Linux engines at `engine-2026.08.29.9`.

**`xveil-windows-arm64.zip`.** An ARM64 Windows machine has until now run the
x64 bundle under emulation. This one is native: seventeen binaries, every one
of them ARM64, checked by reading the machine field of each rather than by
trusting the file name.

**The reason 0.13.10 gave for this being impossible was wrong.** It said
Flutter publishes no arm64 desktop SDK archive and `flutter build windows`
takes no `--target-platform`. Both are true; neither was the obstacle. A probe
on an arm64 Windows runner installed the SDK from git and built until it hit
something else entirely — the same native staging the x64 leg does for itself.
The wall was a host, exactly as it had been on Linux. Three things actually
stood in the way, and each is worth naming because none was where the reason
pointed:

* **The output directory.** `builder.py` spelled `build/windows/x64` outright.
  Flutter names that directory after the machine it built on, so on arm64 every
  check after the build looked in a directory that does not exist and reported
  "no engine in the bundle" about a bundle that was never there.

* **One dependency line.** Six crates in veil take `pqcrypto-falcon` with
  `default-features = false`; one took the defaults, and cargo unifies features
  across the graph, so that single line turned `avx2` and `neon` on for the
  whole workspace. pqclean's aarch64 sources are written for GCC/Clang and MSVC
  rejects them outright. Narrowed per target rather than switched off
  everywhere: nothing changes for x86_64 or for arm64 Linux.

* **BoringSSL has no assembly route here.** Its CMake sends Windows x64 down
  the NASM branch and Windows ARM64 down a generic one, where cl.exe is handed
  GNU-syntax `.S` files and assembles none of them. The crate that knows the
  answer — `OPENSSL_NO_ASM` — returns before reaching it on any *native* build,
  which on x64 costs nothing and here was the whole problem. Answered from
  outside with a target-scoped toolchain file. The cost, stated rather than
  hidden: AES and GCM use BoringSSL's portable C on this bundle alone. Slower
  than the x64 bundle's assembly, faster than the whole x64 bundle emulated.

**A bundle's binaries must be the machine it claims.** The first native arm64
build shipped an x64 `vcruntime140_1.dll`. That file carries exception-handling
helpers that exist only on x64, nothing in an ARM64 bundle imports it, and the
redistributable ships an x64 copy of it under the `arm64` directory anyway. The
copy step selected by directory and the check demanded all three runtime DLLs
unconditionally — "every binary here imports it", true on x64, false here — so
both agreed and an x64 binary rode along. Both halves now ask the artefact: the
copy filters by the machine field of the file itself, and the check walks the
finished bundle and fails on any PE of the wrong architecture, on a referenced
runtime DLL that is missing, and on a runtime DLL that nothing references.

**Still not native:** nothing. This completes the desktop set — x64 and ARM64
on both Windows and Linux, plus a musl bundle for Alpine.

## [0.13.10] — 2026-08-29

Sound on Windows, an output menu that is actually drawn, and two bundles
that did not exist: Alpine and Linux on ARM.

Built on veil [v0.8.4](https://github.com/veilnetwork/veil/releases/tag/v0.8.4)
and hidden-volume
[v2.0.5](https://github.com/veilnetwork/hidden-volume/releases/tag/v2.0.5), with
the Windows and Linux engines both at `engine-2026.08.29.9` — the first release
where they are built from one veil commit.

**Windows calls are heard.** The cause was not a broken device or a dead
stream. Windows keeps TWO defaults for audio output, and they are routinely
different devices:

| role | device on the machine that reported silence |
| --- | --- |
| `eConsole` / `eMultimedia` | headphones (RSQ-319) |
| `eCommunications` | speakers (2- ME6S) |

The engine asked for the communications default. On paper that is the right
answer — it is the role Windows names for calls — and in practice it is the
wrong one: almost nobody sets that role deliberately, so Windows fills it with
whatever it likes, and the call comes out of a device nobody is wearing.

Nothing looked broken from inside, which is why this took as long as it did:
the module reported playing, packets arrived and decoded with zero loss and
zero concealment, the levels were healthy. Every counter green, and silence,
because the sound was going somewhere else. The plain default is now what a
call plays into, with the communications default kept as a fallback.

**The output picker is drawn.** 0.13.9 announced this and shipped a menu that
did not contain it. The plumbing was all there — the engine listed outputs, the
overlay routed a chosen output to the engine, the row even had an icon — and
the sheet filtered cameras, microphones, screens and windows out of the list it
was handed and dropped everything else on the floor. So the audio tab offered
microphones and no way to choose an output at all, on exactly the machines that
have four of them plugged in. The section is now drawn, above the microphones,
and a test written over every device kind rather than a list of kinds fails
until each one is reachable.

**Two Windows audio fixes that were proven but never released.** Between the
engine 0.13.9 pinned and this one: the device list came back empty because it
was asked from a thread other than the one that created the audio module, and
the microphone was never selected at all. Both were measured on a live Windows
machine with a hand-installed engine. This is the release that carries them.

**xVeil runs on Alpine.** A `musl` bundle, `xveil-linux-x64-musl.tar.gz`. The
glibc bundle cannot run there — musl has no `libc.so.6` and no symbol
versioning — and the gap turned out to be small enough to close honestly rather
than argue about: two locale-aware parsers and a handful of `_FORTIFY_SOURCE`
entry points musl does not implement, answered by a small compatibility library
shipped inside the bundle. The bundle starts itself in CI on Alpine before it
is allowed out. A tray icon needs `libayatana-appindicator` and
`libdbusmenu-gtk3`; without them the app runs, just without an icon.

**Linux on ARM64.** `xveil-linux-arm64.tar.gz`, a native bundle. The previous
release said this was not possible because Flutter publishes no arm64 desktop
SDK archive. That was too wide a claim: there is no archive, but the SDK
installs from git and builds arm64 on an arm64 host, which is what this leg
does. Windows on ARM is still waiting — there `flutter build windows` has no
target-platform switch to offer, and the engine DLL sits published and unused.

## [0.13.9] — 2026-08-29

A call can finally be told where to come out of.

Built on veil [v0.8.4](https://github.com/veilnetwork/veil/releases/tag/v0.8.4)
and hidden-volume
[v2.0.5](https://github.com/veilnetwork/hidden-volume/releases/tag/v2.0.5), with
the Windows engine at `engine-2026.08.29.3` and the Linux engine at
`engine-2026.08.29.4`.

**An audio output picker.** The call sheet offered a microphone and a camera
and no way to choose where the call is heard. That was not only a missing menu:
nothing in the app ever selected an output, so on a desktop where nobody had
chosen one by hand, playout started against whatever the engine defaulted to —
and on Windows that is no device at all. The engine has been able to list and
select outputs all along; every layer between was missing. The choice is
remembered by label and restored next time, exactly as the microphone is.

On Android the output choice is earpiece/speaker and stays where it was, in the
call sheet's own routing.

**Known:** playout on Windows still needs proving. This build carries the
picker and the engine's report of what each playout call answered, which is how
the remaining cause will be named rather than guessed at.

**Not in this release, and not for want of trying:** native arm64 bundles for
Windows and Linux. Our half is ready — both engines are built and published,
and the workflow takes an architecture in three lines — but Flutter ships no
arm64 desktop SDK. Every release on every channel in Flutter's own index is
x64, for both platforms. Windows on ARM runs the x64 bundle under emulation
meanwhile.

## [0.13.8] — 2026-08-29

Calls on Windows: the app no longer dies when one is answered, a call nobody
is making no longer rings, and the microphone works. Playout is still being
chased — this release carries the instrumentation that will name it.

Built on veil [v0.8.4](https://github.com/veilnetwork/veil/releases/tag/v0.8.4)
and hidden-volume
[v2.0.5](https://github.com/veilnetwork/hidden-volume/releases/tag/v2.0.5), with
the Windows call engine at `engine-2026.08.29.3`.

**Answering a call killed the app.** WebRTC has two Windows audio device
modules and they want opposite COM apartments; the default one asks for STA and
turns a mismatch into a fatal check. The process has an MTA it cannot not have,
and a thread that touches COM without initialising joins it implicitly — so
asking the calling thread and hoping could not work. The engine now builds the
module on a thread of its own that no apartment has claimed, and drives it from
that same thread.

**A call nobody was making rang.** Offers carried no timestamp, so a callee had
no age to judge, and the freshness gate that did exist guarded the lane where
one of your own devices forwards a ring — while a durable re-drive arrives on
the direct one. A crashed or missed call left its offer in the mailbox and the
next drain delivered it intact, hours later. Offers are stamped now and one
gate serves both lanes. An offer from a peer too old to stamp is still
admitted, and said out loud, rather than refused.

**Android ships three ABIs again.** armeabi-v7a and x86_64 return alongside
arm64-v8a: both were held back because they could not carry the call engine,
and both now carry it, together with the speech-to-text wrapper that was also
arm64-only. Every library in every APK is checked against its own architecture
rather than the folder it sits in.

**Known, not fixed here:** audio playout on Windows does not start, so a call
carries your voice and not theirs. The engine in this release reports what it
was asked for and what each playout call answered, which the previous builds
discarded in silence. The call UI also has no audio-output picker — the engine
now chooses the communications default itself.

## [0.13.7] — 2026-08-28

Answering a call on Windows killed the app. This is the fix, and it is the
only thing in this release.

Built on veil [v0.8.4](https://github.com/veilnetwork/veil/releases/tag/v0.8.4)
and hidden-volume
[v2.0.5](https://github.com/veilnetwork/hidden-volume/releases/tag/v2.0.5),
with the Windows call engine rebuilt as `engine-2026.08.28.2`.

**The call engine took the apartment of whatever thread called it.** COM on
Windows is configured per thread, permanently, and the camera backend
initialised it on the first thread that ever touched a camera — an internal
call arriving on whatever thread the app happened to use. WebRTC's Windows
audio device module then asked for the opposite model on that same thread and
treated the mismatch as fatal rather than as an error to report, so the process
died before a single frame:

    Invalid COM thread model change (MTA->STA)

Whoever ran first won the apartment, which is why the caller survived and the
answering side did not — reported on Windows 11 with 0.13.4, phone to desktop.

Every apartment the engine sets up now belongs to a thread it started itself,
and the camera's reader is opened, read and released on that one thread instead
of being created on a borrowed one. If something else ever claims the caller's
apartment anyway, the engine now refuses to build the audio device and says so:
a call without a microphone beats an app that disappears.

## [0.13.6] — 2026-08-28

Mail deposited for an offline peer now arrives. The defect was in the network
library and is fixed in veil v0.8.4; the production relays were upgraded before
this was cut, and the fix was confirmed live on stand nodes against them.

Built on veil [v0.8.4](https://github.com/veilnetwork/veil/releases/tag/v0.8.4)
and hidden-volume
[v2.0.5](https://github.com/veilnetwork/hidden-volume/releases/tag/v2.0.5).

**Every mailbox answer that carried mail was dropped in transit.** A sealed
introduce crosses two cells — one on the way to the rendezvous, one down the
receiver's own circuit — and only the first was ever checked. When circuits
began choosing their own cell size on 2026-08-20, everything between about 2 KB
and 8 KB started being accepted by the sender, routed, and discarded by the
last relay. An empty answer is a couple of bytes and always arrived, so the
mailbox looked healthy from every angle except delivery.

Measured on the production network the same day: a contact request deposited
for an offline computer was answered by the relay 58 times over two hours and
not once reached it, so the blob was never acknowledged and the relay kept
re-serving it. After the upgrade that same envelope was delivered and
acknowledged within a minute.

Nothing in the app changed. If you are running 0.13.5 the mail reaches you as
soon as the relays are current — this release exists so the client carries the
same fix when it is the one answering.

## [0.13.5] — 2026-08-28

A friend request could not be sent. Two defects, both found by reproducing it
on stand nodes against the production seeds, and the fix confirmed there before
this was cut.

Built on veil [v0.8.3](https://github.com/veilnetwork/veil/releases/tag/v0.8.3)
and hidden-volume
[v2.0.5](https://github.com/veilnetwork/hidden-volume/releases/tag/v2.0.5).

**The request went nowhere and said it was sent.** Sending a contact request
starts two legs — a deposit at the recipient's relay and a live send — and both
outcomes were thrown away. So a request that reached neither still left the
contact marked as pending, which reads as "sent", while nothing was on the wire
and nothing anywhere said otherwise: in a release build the diagnostic trace is
compiled out. This is also the one send with no retry behind it, so the silence
was permanent until somebody asked again by hand. The deposit now reports
whether it landed, and the request is refused rather than quietly accepted when
it did not.

**Why it did not land** is fixed in veil v0.8.3: a recursive DHT query was
being sent to peers that had opted out of serving DHT — a phone opts out by
default, and behind one NAT it is the desktop's nearest session peer, so it and
its twin exhausted the query budget before a seed was asked. Sealing an
envelope needs the recipient's instance registry; the registry "did not
resolve" while the record sat on all three seeds the whole time.

Also in: the deniable-storage library gained a Windows ARM64 build, and its
public-API gate learned to see `unsafe fn`.

## [0.13.4] — 2026-08-28

An audit release. The report17 pass closed every numbered finding across the
three repositories, and then a second pass removed each fix and required its
own test to fail — which is how the three holes below were found, none of them
by reading the code.

Built on veil [v0.8.2](https://github.com/veilnetwork/veil/releases/tag/v0.8.2)
and hidden-volume
[v2.0.4](https://github.com/veilnetwork/hidden-volume/releases/tag/v2.0.4).

**Work started under one identity no longer finishes under another.** A
translation, a folder-sync pass, a node-registry mutation and a sticker edit
each captured the storage they were asked for and refuse to publish or write
into whoever is open now. The reading of a message under identity A could
otherwise land in B's storage, where it stayed after the lock.

**An alert is answerable only by whoever posted it**, and a lock that could
not finish no longer reports success: the legs that did not confirm are named
back to the caller rather than summarised into `ok`.

**Onboarding fails closed.** Where the native phrase generator is unavailable
the app refuses to create an identity instead of minting one from a weak
fallback that could never be recovered from.

**A rename refused for want of the permission says so.** It used to answer
"could not update the community, check the network and try again" — advice
that cannot be followed, because the network is not what refuses. The refusal
is read from the same ACL that decides whether to offer the button at all.

**Windows.** 0.13.0 did not start there: the node's config is amended line by
line and a Windows path in a TOML basic string made `C:\Users` an escape
sequence. Every amended value is now rendered rather than interpolated.

**The transport's reassembly table counts bytes, not just sets.** It bounded
how MANY payloads could be half-arrived and not how large they could be — 64
sets of 65535 fragments, held for the whole TTL, from frames anybody can
forge.

Under the release: the deniable-storage library gained a Windows ARM64 build,
its public-API gate learned to see `unsafe fn` (four entry points had left the
snapshot silently), and veil's lockfiles moved off a yanked chacha20.

## [0.13.3] — 2026-08-26

Failover, proven on the phone: the VPN left through one server, that server was
stopped, and the next request left through the other. Everything below is what
stood between those two facts.

Built on veil [v0.8.1](https://github.com/veilnetwork/veil/releases/tag/v0.8.1)
and hidden-volume `3f07ac8f`, which is v2.0.3 plus a test and a doc note: the
shipped library is v2.0.3.

veil v0.8.1 exists because of this release: the exit allowlist landed after
v0.8.0 was cut, so two servers both answering `veil-cli 0.8.0` could differ on
whether their exit checks who it carries. **Upgrading a server that runs an
exit is a compatibility step**: admission is now enforced, and an exit
configured before allowlists existed names nobody, which reads as "refuse
everyone". Give every enabled exit its `allowed_node_ids` first. Nodes that do
not enable the exit are unaffected — checked on the production seeds, which
carry no `[proxy.exit]` section at all.

### Composing the node config is idempotent again

`EmbeddedNode.withProxy` returned the config untouched whenever it already
carried a `[proxy.` table. Stale tables are now replaced instead: for the
embedded node this app is the AUTHOR of the config, so a `[proxy.…]` table it
finds is last boot's answer to a question the user has since answered
differently.

**Correction to an earlier claim.** This entry first said the guard fired on
every compose and left the routing screen inert. That was wrong, and measuring
settled it: a default config serializes to `[global] [transport]
[transport.rotation] [transport.tls_fingerprint] [Identity] [mobile]` and no
`[proxy.…]` at all, because `ProxyConfig` is skipped when default. The guard did
not fire, and routing did reach the node. The one exit candidate that prompted
the change came from the VPN's own pinned chain — the section below.

### The row that says which exit you leave through said nothing

It rendered `0 + запасных: exit-host`. The generated localization signature
sorts placeholders alphabetically — `(fallbacks, primary)` — while the sentence
reads `{primary} + запасных: {fallbacks}`, and both call sites passed them the
other way round. Two positional arguments of the same type swap without a word
from the analyzer. It is the only message in the app with more than one
placeholder, and both of its uses were wrong.

The same row was silent about a second thing: with **Автосмена oproxy** off the
plan cuts the chain to its first exit, so a two-exit chain ran on one while the
row promised a spare. It now says the spares are off.

### The VPN could not start again after being stopped

The packet engine keeps one tunnel slot. A start that finds it occupied answers
`VEIL_ERR_REENTRANT`, which the app showed as "the previous run's tunnel is
still closing, try again in a moment" — advice that assumes the slot is
draining. It was not: on a phone, every start for five minutes was refused with
that sentence, and only killing the app cleared it. `stop()` had asked the
engine to stop, kept the refusal in a local, and then returned the platform's
state bare — so a stuck engine was recorded nowhere. An occupied slot is now
cleared and the start tried once more.

### The app's own links were not links

A chat body turned only `https?://` into something tappable, so every `veil:`
URI the app itself mints — a contact invite, a share of working entry nodes, a
device link — arrived as flat text. Tapping was not offered; had it been, the
handler hands URLs to the system, and nothing installed answers `veil:`.

Now they are links, and a tap redeems them **in the app**: an invite adds the
contact and opens the chat, an entry-node share adds the nodes and says how
many actually landed. A device link is recognised and deliberately NOT applied
— it joins a device to an identity, one that arrives in a message is somebody
else's, and a tap is not consent; the dialog says so and offers the Devices
screen. `veil-cloud:` references and space-recommendation cards are untouched.

### Re-attaching a server whose records you lost

Restore an identity from a phrase with no second device to replicate from, and
the app has no record of your servers. The read-only inventory could read a
node id back but never asked whether the machine was an exit, so a re-attached
server never joined the routing catalog — the only way in was a full deployment
over a working machine, rewriting its listeners and config.

The inventory now also reports the exit and its allowlist, read from the config
file (`veil-cli config get proxy.exit.enabled` answers `unknown config key`),
and an inventoried exit joins the catalog through the deployment's own
decision. It also warns when the exit admits nobody — the shape of every server
deployed before allowlists existed, which carries traffic today and will refuse
every stream once its node is updated.

## [0.13.2] — 2026-08-26

Everything here came out of running the thing: a node installed on a second
server from the phone, a VPN pointed at it, and the failures met on the way.

Built on veil `0ce0acd2` — [v0.8.0](https://github.com/veilnetwork/veil/releases/tag/v0.8.0)
plus three commits, two of them below — and hidden-volume `3f07ac8f`, which is
v2.0.3 plus a test and a doc note: the shipped library is v2.0.3.

### An exit now knows whose traffic it carries

A node with the exit switch on served **every peer that could reach it**. There
was no allowlist and no way to add one, so anyone who turned it on was running
an open proxy under their own address without having agreed to it.

`[proxy.exit]` gains `allowed_node_ids` and `allow_all`, and **an empty list
means nobody**. An exit that is enabled and names neither stays closed and says
so at startup. **If you run an exit today, it will carry nobody after this
update until you say who** — the deployment screen now writes your device in
automatically, and the startup line tells an operator who upgrades by hand.

### Fixed

- **Deploying over SSH always failed, after installing the binaries.** The
  staging hardening left the scratch directory unreachable to the unprivileged
  account the config steps run as, and `veil-cli` cannot tell "not there" from
  "not allowed to look" — so it reported a file that was sitting right there as
  MISSING, and the run ended with the binaries installed and no node running.

- **An update could replace the node's identity, silently.** The step that
  chooses between keeping the identity and minting a new one looked for one
  spelling of the config's identity section; veil accepts and deliberately
  preserves the other. A node whose config used it read as "no identity here",
  and an update took the node's id and every relationship hanging off it.

- **Re-deploying added listeners instead of replacing them**, because the
  filter that selects them to remove was written for decimal ids and they are
  printed in hex, so the loop deleted nothing and each run appended.

- **The SSH private key was the one secret left in plain sight.** Every other
  secret on those screens is masked; a PEM cannot be, so all four SSH screens
  drew it in a monospace box on routes with no screenshot protection. It is now
  one field that carries the guard with it.

- **The VPN said "choose a valid exit node" when the local address was wrong**,
  which is a different thing to fix, and greyed the button out meanwhile.

- **A refusal from the packet engine said only that it refused.** The engine
  answers with distinct codes — including "a tunnel is still shutting down, try
  again" — and the app discarded them for one English sentence on every screen,
  in every language.

- **An exit registered in the routing catalogue followed the wrong signal**, so
  deploying one without the exit switch added an entry nothing could dial, and
  deploying an exit the ordinary way registered nothing at all.

- **The first-run wait no longer promises a minute.** Measured on a mid-range
  phone: about ten, with every core busy.

- A generated root-privileged script now refuses a configuration its own
  validator rejects, rather than trusting the screen in front of it to have
  asked.

## [0.13.1] — 2026-08-26

Found by installing a node on a real server from the phone and pointing the
phone's VPN at it. Everything here is a defect that run-through hit; each is
fixed and re-proven on the same server.

Built on veil `b6e49906` — [v0.8.0](https://github.com/veilnetwork/veil/releases/tag/v0.8.0)
plus one fix (an IPC config the daemon cannot read is reported as such instead
of as "no reflector") — and hidden-volume `3f07ac8f`, which is v2.0.3 plus a
test and a doc note: the shipped library is v2.0.3.

### Fixed

- **Deploying a node over SSH always failed, after installing the binaries.**
  The staging hardening left the scratch directory 0700 root:root, and the
  config steps below it run as the unprivileged `veil` account, which then
  could not enter the directory at all. `veil-cli` cannot tell "not there" from
  "not allowed to look", so it reported the staged config as MISSING — a
  message that sends you looking for a file that is sitting right there. The
  run aborted with the binaries installed and no node running. The directory
  is now opened to the `veil` group and to nothing else: the obfs4 PSK and the
  TLS key staged beside it stay unreadable to `veil` and to every other account
  on the machine.

- **Re-deploying a server added listeners instead of replacing them.** The step
  that exists to reconcile them selected listener ids with a decimal pattern,
  and `listen list` prints them in hex — so it matched nothing and deleted
  nothing. A second deployment left two obfs4 listeners on the same port, and a
  `tcp://0.0.0.0:9000` inherited from an older install survived every run since.

- **The node id the inventory reports is kept.** "Проверить установку и
  состояние" prints it and the app already had the parser; the screen showed it
  and dropped it, leaving the record at `—` and the operator to hand-copy 64 hex
  characters into the field that decides what their traffic routes through. It
  fills a blank only — a host that was rebuilt or re-pointed cannot take over an
  entry you chose.

- **"Работать в фоне" could lose the switch you just set.** The setting was
  written after the call that starts the foreground service and outside its
  error handling, so a platform refusal — from Android 12 the ordinary answer
  for an app the system does not consider eligible — skipped the write. The
  switch read ON from memory and reverted to OFF later, silently, with the node
  no longer surviving the screen going off.

## [0.13.0] — 2026-08-25

A report audit, and then the first runs of the test suites on Windows and on
aarch64 Linux. Those runs are why the last few entries exist at all.

### Fixed

- **The node's private key sat in a leaked buffer.** `restoreIdentityFromPhrase`
  copies the config into native memory and then neither wiped nor freed it. The
  cleanup block listed the phrase, the directory and the label; `tomlC` was
  added later and never joined them. That config carries
  `[identity] private_key`, and veil's contract for the entry point says in as
  many words that it does NOT zeroize those bytes because the caller owns them.
  The Dart string is collected; the native copy was not.

- **Inline images were read whole and decoded on top.** The guard for this
  asserted each watched file CONTAINS a call carrying `maxBytes`, which one good
  call satisfies — so it stayed green while the same content id was read a
  second time, in the tap-to-open path, with no ceiling. Four more of the same
  in the chat widgets: the gallery, the resolved image and the thumbnail. Every
  one already handled a null result, so the ceiling degrades into the behaviour
  that was there.

- **Every storage RPC retained its own answer.** `Future.any([reply, death])`
  attaches a listener to both futures and cancels neither, so each answered call
  left a listener on the never-completed death future holding the completer that
  carries the reply — a KV value, i.e. plaintext. This was found and fixed in
  the hidden_volume plugin; `WorkerDeath` is a second copy of the same design
  behind `async_kv_log_store` and `worker_multi_space`, and it was not swept
  with the first.

- **The mailbox drain could stall behind one blob.** A record the client has set
  aside occupied the head of an oldest-first queue and the reply budget with it.
  A FETCH may now name what it cannot use yet, and the relay skips those at
  selection rather than after it. Additive in both directions: an empty list is
  byte-for-byte the request that was sent before.

- **A received bundle is copied out a megabyte at a time**, against a receiving
  ceiling that describes this device rather than what the format allows.

- **A received filename is a label, never a path**, and a stalled API response
  loses its connection rather than only its slot.

## [0.12.0] — 2026-08-24

Built on [veil v0.7.0](https://github.com/veilnetwork/veil/releases/tag/v0.7.0),
cut for this release, and
[hidden-volume v2.0.2](https://github.com/veilnetwork/hidden-volume/releases/tag/v2.0.2),
unchanged since 0.11.0 — no public surface moved and `PARAMS_VERSION` stays at
3, so a container written by 0.11.0 opens here with no conversion.

**There IS a wire flag day this time**, and it is the reason for the minor
digit. veil v0.7.0 breaks the wire in three places: a circuit's cells carry a
size negotiated at setup (and that size dropped from 16384 to 2048 bytes), the
hole-punch token is derived from the deployment's PSK instead of being sent,
and the LAN beacon moved to a port of its own. A 0.12.0 client and a 0.11.0
node still speak OVL1, but they cannot share a circuit, cannot punch each
other, and cannot hear each other's beacons. Update the network and the clients
together; a client left behind degrades to relayed paths and loses LAN
discovery.

The release is otherwise about one thing: what an idle phone pays. Every item
below was found by measuring a real device rather than by reading code, and
each names what it was measured against.

### Changed

- **The 6–12 h transport rotation had never applied.** Its guard returned early
  whenever the config already contained `[transport.rotation]`, and the config
  renderer always emits that section — carrying veil's own 1800/3600 defaults,
  the very numbers the helper exists to replace. Measured on the phone:
  sessions to one seed reopened at 37, 27 and 32 minutes, squarely the default
  band. Its three tests had stayed green throughout because all three fed it a
  config WITHOUT the section, the one input production never produces. This
  costs more than bytes: a rotation gracefully closes the recipient's session
  to its rendezvous relay, and a sender's live introduce inside the
  re-registration gap black-holes into the slower mailbox path — which had been
  happening every 30–60 minutes.
- **A 200 ms outbound coalescing window was written, measured, and NOT taken.**
  Framing is the largest remaining per-frame cost now that a circuit cell is
  2048: on one seed link over 599 s, 521 frames carrying 190 B/s of bodies cost
  413 B/s on the wire, about 260 bytes each. A window looked like the answer and
  is not one. veil's window DEFERS a drain rather than accumulating toward one,
  so at an idle rate near 0.5 outbound frames per second the next frame arrives
  after the window has already lapsed and the deferral never fires. The 260
  bytes are the TLS bucket floor, and that is already amortised — 478 B of wire
  against 218 B of body averages about 2.7 frames per bucket, packed by the
  unconditional back-to-back path, which needs no window at all. The helper is
  kept, correct and tested, for traffic dense enough to collect something; it is
  deliberately not wired into the production config chain, and nothing in this
  release changes coalescing behaviour.
- **A device that is provably gone stops costing a burst every half hour.** The
  unresolved-peer backoff ceiling was thirty minutes and turned out to be the
  largest single line in an idle phone's bill: three sibling devices away 25 h,
  26 h and 4.8 days had 274 frames queued for them, and every expiry drove all
  of them — bursts of ~120 sends inside six seconds, about 93% of the phone's
  send events, each a DHT lookup for a device that cannot be sealed for at all.
  The ceiling moves to six hours, which is also how long the frames themselves
  live, so a frame now gets at most one blind re-check inside its own lifetime.
  The ramp is untouched and it is the ramp the ordinary case rides; a returning
  peer is served immediately, because the first authenticated delivery clears
  the backoff outright.
- **The resend ladder now bounds how many retry at once, not only how often.**
  Per-frame exponential backoff saturates, so frames queued together come due
  together: measured against three offline contacts over 38 minutes, 55 bursts
  of which four carried 1100–1600 sends inside 6–7 seconds — about 175 sends
  per second — while the ticks between them ran at three sends per minute. The
  bursts were ~95% of all attempts, and on the seed side the same thing reads
  as 47–52 recursive queries per second against a single key. Each frame's
  delay now carries a deterministic offset derived from its id. The offset
  subtracts rather than adds, so a frame can only retry earlier than the ladder
  promises, never later.
- **A conversation with nothing to reconcile asks less often.** The gap-fill
  beacon had one reason to slow down — nobody answered — and none for nothing
  happened. Since a peer answering an empty beacon sends one back, two idle
  conversations pinned each other at a beacon every 20 s in each direction for
  as long as both stayed online, to say that nothing had changed: 0.1 frames/s
  per idle contact against a whole-node floor of ~2.4 frames/s, so the 5–6
  contacts this is sized for would have been a quarter of everything the node
  sends. A second streak now counts beacons that would restate the last one
  verbatim, and the longer streak sets the cadence. A conversation awaiting a
  hole is never quiet, however unchanged its beacon looks.

### Added

- **The headless daemon can see its own diagnostics.** Its whole purpose is
  unattended bots and server integrations, and it had no way to answer "why did
  that not send" in any build: `devLog` writes where a captured stdout cannot
  see it, the ring buffer behind it is exposed only through a debug hook the
  daemon does not have, and the documented escape hatch could not be built for
  this target at all. `XVEIL_LOG_STDOUT=1` now echoes each line, read inside
  the existing compile-time gate — so in a release build the branch is
  eliminated, the variable is never consulted, and no node-id-bearing string is
  ever constructed. It is deliberately not a runtime switch on the gate itself,
  which is the obvious change and the wrong one.

### Fixed

- A dialog's controller must outlive the dialog rather than the caller; the
  last eight dialog controllers were given owners, and two that were sleeping
  were woken.
- The stdout echo carried no timestamp.
- Release notes must match the tag rather than the first attempt.

## [0.11.0] — 2026-08-19

Built on [veil v0.6.0](https://github.com/veilnetwork/veil/releases/tag/v0.6.0)
and [hidden-volume v2.0.2](https://github.com/veilnetwork/hidden-volume/releases/tag/v2.0.2),
both cut for this release.

veil's minor digit moves because its wire gained a capability bit and its FFI
gained entry points; hidden-volume's is a patch, and deliberately so — no
public surface moved and `PARAMS_VERSION` stays at 3, so a container written by
the version 0.10.0 shipped opens here with no conversion. Its patch digit is
at .2 rather than .1 because v2.0.1 shipped one accidental `pub` and a stale
API-surface snapshot; v2.0.2 narrows the item back and changes nothing a
container or this app can observe.

There is no wire flag day this time. A 0.11.0 node and a 0.10.0 node exchange
frames normally; the new capability bit is expressed as a REFUSAL
(`NO_DHT_SERVICE`), so a peer that predates it advertises nothing and is read
as willing, and a mixed network keeps behaving exactly as it did.

**This is the release in which an identity stops being one device.** One
recovery phrase now stands for a person, not for an installation: a second
device links to the first, gets a key of its own under the same master, and
from then on both are the same correspondent to everyone else. That took most
of the work here — and most of the defects, because the same mistake kept
reappearing in different clothes. Ten times, a question about a DEVICE was
asked of an IDENTITY: the group fanout resolved a member to one device, the
mailbox addressed the person and delivered to whoever answered first, the
content server checked a device's key against the identity's name, the sender
paired the wrong instance. Each looked like its own bug. They were one.

### Added

- **A second device, linked from a phrase.** Linking amends a signed identity
  document that names every device key; a device that holds nothing can be
  named into a family and adopt the document that names it. A linked device
  receives the FULL history that predates it — proven end to end on three
  devices, 25 of 25 messages identical — and both directions converge, not
  just the new one.
- **Revocation, with tombstones.** Removing a device retires its key from the
  document and leaves a marker that survives a merge, so an older copy of the
  document cannot quietly resurrect it. Verified against a live revoked
  device rather than against a fixture.
- **Calls ring every device.** The call signal is relayed to all of them and
  the caller follows the call to whichever one answers.
- **Disappearing messages, by two different clocks.** They are not the same
  promise and the interface does not pretend they are.

  The first is by POST TIME: a window (1, 5, 30, 60 minutes, or your own)
  after which the message is deleted on every device that has it. Every peer
  computes the same deadline from the same signed setting, so it is a
  guarantee. It works in one-to-one chats, in groups and in channels.

  The second is by READ TIME: a window that starts when a device first SHOWS
  the message. It HIDES rather than deletes — in a channel the log keeps the
  post, the interface stops offering it — and it is decided by the receiving
  device, which may simply not do it. It is a courtesy, and it is described as
  one. Groups and channels get both: a policy the owner signs, and a personal
  ceiling any member can set for themselves; the shorter of the two wins.
- **A choice about serving the DHT for other people.** An idle client was
  measured receiving 13.6 KB/s, of which 85% was work done for strangers —
  storing their records, answering their lookups, being a hop of their walks —
  while its own application traffic was three bytes per second. On a phone
  that is 5 GB a day.

  Phones now advertise that they are not candidates for that work; desktops
  still are; there is a switch in the network screen either way, and the
  answer is per identity. Declining does NOT hide the device or make it
  unreachable: it stays in everyone's routing table, still publishes its own
  records, still resolves others, still receives mail. What stops is unpaid
  work. Refusing the work locally had already been tried and measured to
  change the traffic by nothing at all — the bytes cross the network before
  any local decision happens — so the only lever is to stop being CHOSEN.
- **Android offers the battery exemption at start-up, once, and takes no for
  an answer.** Without that exemption the node loses every session as soon as
  the screen goes off — measured, and it is not Doze: it happens well before
  deep idle, so it is the background network restriction attached to the
  battery whitelist. Someone who declines gets a working app that receives
  nothing while it is in a pocket, which is a legitimate choice as long as it
  is an informed one.
- **A testnet, and one rule for which network a build talks to.** Debug builds
  reach the testnet, release builds reach production, and `XVEIL_NETWORK`
  overrides both. Development traffic used to land in production silently:
  veil hands `debug_assertions` the production seed list, and no build path
  passed a seed feature in debug.
- **Mailbox slices.** A blob too large for one FETCH is announced by the relay
  and collected in windows by the client, which is what a multi-device envelope
  needs — one envelope per device stopped fitting at three devices, and the
  answer was to cut the reply, not the payload.

### Security

- **h2 past RUSTSEC-2026-0258.** "Unbounded empty DATA frames", published two
  days before this release and fixed in 0.4.16. It reaches the app through the
  DNS resolver in the node's own bootstrap, so it is linked into the native
  library on every platform here, not only into the update check. Caught by
  `cargo audit`, which is a step of a gate that had been failing at its first
  step since 14 August and therefore had not run in five days.
- **The production obfs4 pre-shared key was in the source of a public
  repository.** It was generated on 2026-06-18 and pasted into
  `test/node_provisioner_test.dart` the next day as a fixture, where nothing
  needed it to be real — the tests assert that a valid base64 string survives
  validation and reaches the generated provisioning script, and any 44
  characters would have done. It is replaced by base64 of a sentence that says
  what it is, and a guard now refuses any source file that contains the bytes
  of the bundled key.

  **It is not being rotated, and that deserves stating plainly.** The same key
  ships INSIDE every release artifact — the release job asserts that it does,
  because without it the app reaches no bootstrap peer at all — so anyone who
  downloads xVeil already holds it. A network PSK distributed with the client
  is not a secret against anyone willing to install the app; it is a secret
  against someone who has not bothered. Rotating restores only that second
  property, and costs every installed client its network until it updates.
  What it really says is that this PSK is a poor place to put the
  unrecognisability of the transport, and that belongs to the secret-channel
  work rather than to a key change.

### Fixed

- **The Windows bundle now carries the Visual C++ runtime it needs.**
  `MSVCP140.dll`, `VCRUNTIME140.dll` and `VCRUNTIME140_1.dll` were absent from
  the zip and every binary in it imports them, `xveil.exe` included — Flutter's
  Windows template copies none of them, so a Windows without the Visual C++
  Redistributable could not start the app at all. This was prepared as 0.10.1,
  which was never published; the fix reaches a release here for the first time.
  The gate asserts the three files are IN THE BUNDLE rather than asking whether
  the machine can resolve them, because every machine that built or tested this
  app had the redistributable installed, the CI runner included.
- **One stuck deposit no longer freezes every other one.** The deposit slot was
  a single lock held across an `await` with no deadline, so one mailbox PUT
  that never returned wedged all outgoing mail indefinitely.
- **A cleared history no longer silences a correspondent forever.** Clearing
  set a per-author ceiling on the message number with no expiry, so once that
  peer's counter reset, everything they sent afterwards was dropped in silence.
- **Compaction no longer waits on a lock it holds itself.** The shutdown chain
  was protected against exceptions but not against hangs.
- **A device that has been offline too long can still be deposited to**, and an
  unresolvable sender is retried rather than destroyed.
- **A relayed call offer survives ordinary clock skew.**
- **The APK freshness gate asks only about the ABIs that actually ship**, so a
  correct build stops being blocked by a leftover it does not use.

### Changed

- The disappearing-window presets are expressed in minutes, and a custom value
  is accepted.
- The owner actions of a group moved into a menu.
- Content served to your own devices no longer requires a contact grant — a
  device of yours is not a stranger asking for a file.

## [0.10.1] — 2026-08-13 (prepared, never published)

This version was cut as a Windows-only fix and no artifacts were ever
released under it. The fix it describes ships in 0.11.0.


Built on the same [veil v0.5.2](https://github.com/veilnetwork/veil/releases/tag/v0.5.2)
and [hidden-volume v2.0.0](https://github.com/veilnetwork/hidden-volume/releases/tag/v2.0.0)
as 0.10.0. Windows only — the Android and Linux artifacts are unchanged in
behaviour, and there is no reason to reinstall those.

### Fixed

- **The Windows bundle now carries the Visual C++ runtime it needs.**
  `MSVCP140.dll`, `VCRUNTIME140.dll` and `VCRUNTIME140_1.dll` were absent from
  the zip, and all fourteen binaries in it import them, `xveil.exe` included —
  Flutter's Windows template copies none of them. A Windows without the Visual
  C++ Redistributable therefore could not start the app at all.

  It went unnoticed because every machine that had built or tested this app had
  the redistributable installed, the CI runner included. That is also why the
  new gate asserts the three files are **in the bundle** rather than asking
  whether the machine can resolve them: a check that consults the runner passes
  here and ships the same broken zip.

  Anyone holding the 0.10.0 zip can either take this one or install the
  Microsoft Visual C++ Redistributable (x64); both fix it.

  **This was found while investigating a startup report, and it is not what
  that report was.** The dialog there named `hidden_volume_plugin.dll`, and the
  import table of `xveil.exe` rules the runtime out as the cause: the loader
  walks that table in order, `connectivity_plus_plugin.dll` sits ahead of
  `hidden_volume_plugin.dll`, and both need the runtime equally — so a missing
  runtime, or a launch with no sibling DLLs present at all, would have named
  the earlier file. Three DLLs resolving and the fourth not means that one file
  specifically was not there, which points at extraction or at antivirus
  quarantine of an unsigned binary, not at the bundle's contents. That report
  is still open.

## [0.10.0] — 2026-08-13

Built on [veil v0.5.2](https://github.com/veilnetwork/veil/releases/tag/v0.5.2)
and [hidden-volume v2.0.0](https://github.com/veilnetwork/hidden-volume/releases/tag/v2.0.0).

hidden-volume's major bump is about ITS public API, not about the container
on disk: `PARAMS_VERSION` stays at 3 and a container written by the version
v0.9.1 shipped opens here with no conversion and no tool. What a 2.0 costs is
the other direction — a container this app writes can be refused by an older
build — so a downgrade to v0.9.1 is not a supported move. See that release's
own entry for the two changes that cause it.

**veil v0.5.1 is a flag day for the NETWORK, and that is the sharper one.** A
node built from it cannot exchange a single frame with one built from the
v0.4.2 the previous release named — the wire header's version byte moved and
the check is exact equality, so an older peer is refused before it can identify
itself. Every node has to be rolled together: clients, relays and the seed
fleet. Auto-update is deliberately not opened to the 0.4.x line, so nothing
upgrades itself into a partition while the roll is half done.

It is also the release in which **Windows stops being hollow**. The v0.9.1
bundle shipped a `veilclient_ffi.dll` that exported nothing at all, so the app
on Windows had no way to reach the network; it now exports 131 entry points,
measured on the built artifact rather than inferred from a green build.

All three call engines are now built and pinned to a GitHub Release
(`ENGINE_RELEASE: engine-2026.08.13`), whose assets never expire and download
with no credential — the run-artifact route they used before needed a token
and would have gone dead in October. What remains before publishing is in the
release checklist at the bottom of this entry.

### Security

- **Declining the shared seed nodes now holds from the first packet.** Someone
  who turns that off at onboarding was still contacting all four production
  seed hosts once per start, on every launch, on the app and on the headless
  daemon alike.

  The setting was correct everywhere it could be seen. It reaches the node
  config the app composes, which carries `builtin_seed_policy = "never"` — but
  that is the SECOND config the node reads. The deniable boot starts the node
  from a stub built inside the veil library, and `veil_node_start_deferred`
  takes no config at all, so nothing on this side could reach it. That stub
  carried veil's default policy, whose condition is "no peers configured" —
  exactly what a stub is — so the node spliced in its compiled-in seed list and
  opened connectors to it, seconds before the answer arrived.

  Fixed in veil: the stub now boots refusing the compiled-in seeds, so a
  deferred boot reaches nothing and the network arrives with the config that
  was asked about. Nothing changes for someone who KEEPS the seeds — applying
  the real config is a full reload, and veil re-runs its bootstrap against it.
  This app cannot observe the stub at runtime, so the guard against it coming
  back with a submodule bump reads the veil source directly
  (`test/bundled_seeds_match_builtin_test.dart`).

- **A shipped build no longer runs on the in-memory fake store.** When the
  hidden-volume library failed to load, the app carried on: every non-empty
  password opened the SAME unencrypted space and nothing survived the process.
  The FATAL banner announcing it goes through `devLog`, which is compiled out
  of a product build — so the degradation was silent exactly where it mattered,
  and a user would have written down a recovery phrase for a container that did
  not exist. Release and profile builds now refuse to start.
- **Folder sync can no longer write outside the folder you chose.** Mirror
  paths are built from cloud item names, any linked device can create an item,
  and the path was plain string concatenation — so a name like
  `../../.ssh/authorized_keys` landed atomically on whatever it hit.
- **The local API is exclusive and bounded.** `shared: true` is SO_REUSEPORT:
  another process of the same user could bind the port and receive a share of
  the requests, bearer token included. The token is also checked before the
  body is read, and the body is capped.
- **SSH host keys are confirmed before credentials are sent.** Trust-on-first-
  use was decided inside the connection that then authenticated and ran the
  provisioning script, so a man-in-the-middle on first contact collected the
  password, the script and the obfs4 PSK — and had its key saved as trusted.
- **Provisioning stages secrets privately.** The PSK, the systemd unit and a
  TLS private key were written to fixed `/tmp` names under the login umask and
  then handed to `sudo install`; cleanup ran only on success.
- **A corrupt roster is never silently rewritten.** `loadRoster` answered null
  both for "no roster" and "a roster I could not parse", so adding one identity
  to a damaged master dropped the SpaceKeys of every other identity — keys that
  exist nowhere else.
- **Content manifests are checked for geometry, not just self-consistency.** A
  manifest hashes to its own id, which its author computed; nothing verified
  that the numbers agreed. One declaring 2 MiB in 256 KiB pieces with a single
  hash was accepted and reported complete after 256 KiB.
- **BLAKE3 hashes past one chunk.** It was single-chunk behind a debug assert,
  so a release build returned a wrong digest for longer inputs — reachable,
  because a peer's node id is derived from their public key and the hybrid
  post-quantum key is 1825 bytes.
- **A store password can no longer reach the debug log.** The loopback stand
  hook writes each request line to a ring buffer it then serves back, and it
  wrote that line before any handler ran — so a password passed as a query
  parameter was recorded whatever the endpoint did about it afterwards. The
  test covering this had the defect written in as intent: it asserted the
  password stayed readable, as though only the hook's own key were secret.
  Secrets are now redacted by parameter name at the log, and the compaction
  endpoint refuses a password on the request line outright. Debug builds only —
  the hook is not present in a release build.
- **The error report stops naming people.** It carried IP addresses, hostnames,
  URLs, e-mail addresses, paths and short tokens — and the active profile's
  name, when the existence of a second profile is the fact worth hiding.

### Added

- **Messages translate on the device, by button.** No text leaves the machine
  and nothing is sent to a service: the engine is CTranslate2 running an
  OPUS-MT model, and the result is kept in the ENCRYPTED store so a second look
  costs nothing and the translation never lands in plaintext. Translation
  appears only when a model for that direction is actually installed — an
  affordance that cannot work is not shown.
- **Language models install from a file, and can be passed on.** A direction
  travels as one `.veiltranslate`; the speech model travels as one
  `.veilaudio`. Either can be picked from disk or received in a chat, where it
  becomes an install card rather than an anonymous download. Settings can write
  an installed direction back out as a file, so a person whose connection
  cannot fetch 79 MB — or who has none — can get one from someone who has it.
- **A model is installed whole or not at all, and is verified before it is.**
  A language pair is five files; four of them plus a missing tokeniser is not
  a partial model but one that would translate into nonsense the moment the
  fifth arrived from a different pair. Every file's size and SHA-256 are
  checked against the manifest before anything becomes visible, the container
  carries no paths, and nothing is compressed — so a file from a stranger
  cannot write outside where it belongs or expand into anything.

  For the SPEECH model the check is stronger, because the right hash is known:
  a bundle is compared against what this build expects, not merely against its
  own claim about itself. For a translation model there is no such pin, so
  every install card says plainly that a model decides what the app claims
  another person wrote, and that its hashes prove integrity and not
  provenance.

- **Link a new device without minting a phrase it will never own.** A second
  device joining an existing device group no longer walks the create-identity
  wizard first.
- **Attach a file to a note** by reference, with a dangling attachment shown as
  visibly unavailable rather than as raw text.
- **A community's action log**, rendered to what each member may see; anything
  they may not is an explicit unavailable row rather than a gap.

### Fixed

- **The released APK carries the call engine.** v0.9.1 shipped without
  `libveil_media.so`: voice messages, video notes, calls and speech-to-text all
  threw at first use. The build now refuses to start without it and reads the
  finished APK to confirm it arrived.
- Android ships **arm64-v8a only**. armeabi-v7a and x86_64 were published
  through v0.9.1 and can never carry the call engine.
- Onboarding no longer dead-ends on a failed container creation; folder sync no
  longer wedges a pair as busy forever; API-token ids no longer throw about one
  creation in 585.
- **Being removed from a group, or banned from a community, now reaches the
  person it happened to.** The owner's side was right throughout — nothing
  leaked, and every message from a removed member was refused. The removed
  member saw none of it: minutes later they still held the old epoch, still
  read as a member, and their posts still came back accepted while reaching
  nobody.

  The delivery list is built by folding the control log and taking the current
  members, and that fold runs AFTER the removal is recorded — so the one person
  the entry is about was the one person excluded from carrying it. They are now
  sent that entry, and only that entry: no keys, no messages, no posts, no
  receipt. A removed member must learn they were removed without learning
  anything that happened after.
- **A file or image you received is reachable over the local API.** The message
  showed a paperclip and a name with no way to obtain the bytes, and the
  download endpoint answered "not found" for every id the caller could see. A
  large file arrives as an OFFER first, and that is the state the API forgot to
  describe: it published a handle only once the blob was already local, which
  for a received file is never, because nothing rewrites the row after the
  download. There is now a handle for an offered file and a step that fetches
  it, mirroring what group files already had.
- **Community channels keep the order they were given.** Every channel created
  by anything other than the management screen landed on the same position as
  the default one, after which their order was decided by a hash of their ids —
  arbitrary, and shown to the person as an arrangement they had chosen. A
  channel created without an explicit position now goes after its siblings.
- **The headless daemon no longer publishes an API it cannot serve.** Its
  OpenAPI document described the cloud endpoints, the post comments, the
  account lock and the call operations; asked for any of them, the running
  daemon refused. Each host now describes itself, and the daemon will not start
  if its wiring and its document disagree. The post comments, which it turned
  out could work and simply had not been connected, now work.

### Release checklist

1. ~~Tag veil and hidden-volume, and repoint the pins at those tags.~~ Done:
   **veil v0.5.2** and **hidden-volume v2.0.0**, both published with their
   assets and both opened before publishing rather than after — the mac
   `veil-cli` runs and reports `0.5.2`, and its published checksum matches the
   binary downloaded back from the release.

   This item said v0.4.2 and v1.2.3 for a while after it stopped being true.
   Both pins had drifted off their tags — hidden-volume by one commit, veil by
   164 — so the line naming what this release was built on was wrong, which is
   the one thing the header of this file promises it is not.
2. ~~Run the `webrtc-linux` workflow (job `engine-android`), pin its run id in
   `release.yml`.~~ Done: run 31609030118, artifact
   `libveil_media-android-arm64`, 87/87 symbols. The same run repins linux,
   which was pointing at a run whose overall conclusion was `failure`.
3. ~~Run `webrtc-windows`, fix what the never-compiled port gets wrong, pin its
   run id.~~ Done: run 30665287484, artifact `libveil_media-win-x64`.
4. ~~Publish the first engine release and fill `ENGINE_RELEASE` in
   `release.yml`.~~ Done: **`engine-2026.08.13`**, carrying all three engines
   with a provenance record each. Every one was checked by downloading it back
   with no credential and comparing its sha256 against its own record — android
   4 462 721 B, linux 5 519 456 B, windows 5 755 392 B, and 87 of 87 symbols on
   each. Release assets do not expire; the run artifacts these replace would
   have died on 2026-10-29 (windows) and 2026-11-10 (android and linux — the
   date this item quoted for all of them, which was only ever the android one).

   Windows was filled last and separately, because its engine took an hour and
   five minutes to build from source. Moving both engine workflows onto a
   prebuilt WebRTC SDK cut that to one minute fifty-four, and linux and android
   from forty-five minutes to one — after which publishing the missing engine
   was a two-minute errand rather than something to schedule.

   Verifying it the way the release job does is what caught the last defect
   before this tag: the windows record was written with CRLF line endings, so
   the hash parsed out of it carried a carriage return and compared unequal to
   a byte-identical DLL. A tag pushed an hour earlier would have failed on
   Windows, accusing a correct engine of being the wrong binary.
5. Tag xVeil; then DOWNLOAD the published artifacts and open them before
   announcing anything — that is what v0.9.1 skipped.

   A dry run (`workflow_dispatch`, which cannot reach `publish`) already builds
   all three bundles green, so the build half is proven. What a tag exercises
   for the first time is the half after it: the draft release and the artifact
   scan. Note veil's own workflow drafts rather than publishes, and three
   releases sat finished-but-invisible until someone looked — expect the same
   shape here and check for a draft rather than assuming silence means failure.

## [0.9.1] — 2026-07-28

Built on [veil v0.4.1](https://github.com/veilnetwork/veil/releases/tag/v0.4.1)
and [hidden-volume v1.2.2](https://github.com/veilnetwork/hidden-volume/releases/tag/v1.2.2).

### Fixed

- **A deployed server is added to the peer list.** Deployment over SSH ended
  with a saved node id and a snackbar; the node was installed, running and
  reachable while staying invisible to the app. A node id cannot be dialled —
  reaching a peer needs transport, public key and nonce — so the script now
  asks the node for its own bootstrap entry and the app adds it.
- **A node deployed without an advertise host is reachable.** `listen add`
  binds `0.0.0.0` and only advertises when the operator filled in a public
  host, so such a node handed out an invite telling peers to dial `0.0.0.0`: a
  peer entry that saves and can never connect. The address the deployment
  reached the machine on is substituted; a host the node advertised for itself
  is left alone.
- **An oproxy exit deployed with the node joins the proxy catalog** instead of
  being installed and never offered.
- **The deploy button is reachable on a phone with gesture navigation.** The
  screen used a flat bottom padding and put its own primary control under the
  system bar.
- **The cloud folder name is visible again.** Seven icon-only actions plus a
  back button left the title about one character wide.
- Errors shown after a deployment or a manual peer add are redacted before they
  reach the screen. They previously carried the raw exception, which quotes
  hostnames, key paths and node ids — into a snackbar, which is the thing
  people photograph when asking for help.

### Added

- **Add a peer by hand**: Network → Peers → *Add peer*. Paste a
  `veil:bootstrap?…` link; the sheet prefills from the clipboard and shows what
  the link resolved to before acting on it. An identity-only link is refused
  with the reason, because it parses cleanly and would add nothing.
- **Plain `ws://` listeners** in the deploy screen. veil's websocket transport
  always served both `ws` and `wss`; only `wss` was offered.
- **INSTALL.md** — which artifact to take per platform, what each platform will
  complain about, and why nothing is published for macOS and iOS.
- **BUILDING.md now starts from a clean machine**: Xcode (the IDE, not just the
  command-line tools), Flutter, Rust, CocoaPods, the Android and Windows
  toolchains, the Debian package list, and the disk budget to expect.

### Changed

- **The cloud root has one named menu** instead of seven unlabelled icons.
  Every entry carries its name; sorting shares the menu and states its current
  value with a checkmark.
- **"Keep on this device" moved into cloud settings.** It is a choice made
  once and it was standing above the file list on every visit.
- **The space setting "P2P availability" is now "Copy redistribution".** It
  never controlled peer-to-peer connections: it sets how many members
  redistribute the space's content so it stays reachable while the owner is
  offline, and the recipients are members the ACL already allows to distribute
  content. The old name invited the conclusion that a channel could see your
  address.
- `libayatana-appindicator3-dev` is in the Linux package list. Without it the
  build stops with a message naming a pkg-config module and no package.

### Removed

- **Lua extensions** from the network screen. The row was a chevron leading to
  a "coming later" notice, which reads as a feature that exists and is switched
  off. The strings stay in the translation files.

## [0.9.0] — 2026-07-28

First release. Built on veil v0.4.1 and hidden-volume v1.2.2.

Android, Windows and Linux artifacts, all produced by CI from the tagged commit
on a clean checkout. macOS and iOS are absent: without an Apple Developer
account the result is something nobody can install — see
[INSTALL.md](INSTALL.md).

Android ships one APK, `arm64-v8a`, signed with the project release key. Speech
recognition downloads its model on first use, which keeps the download near
30 MB.
