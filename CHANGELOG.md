# Changelog

All notable changes to xVeil are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
versioning follows [SemVer](https://semver.org/). The app is pre-1.0: minor
bumps may change behaviour a user notices.

Each release pins the two projects it is built on. Those pins are part of the
release: an app version means nothing without knowing which network and which
storage it was built against.

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
