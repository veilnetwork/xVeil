# Windows native contact, notification event and restart checks

A headless Windows test uses the actual Release core and hidden-volume DLLs from
[the qualified package](../windows-release-aot-storage-package-2026-11-16/README.md),
the current Dart services and two new synthetic sovereign identities. It uses
real embedded nodes, transport signatures, encrypted storage, persisted
ratchets and the ordinary request/accept path. No fake inbound injection or
manual accepted-contact rows establish the relationship. No application window,
tray, microphone/camera capture or input automation is started.

## Windows routing premise corrected

The first attempt reused the Unix loopback fixture. It reached the carrier
stage, then could not connect. A fixture cleanup error also masked its original
failure: Windows refused to delete the still-open diagnostic file. The fixture
now restores/closes that log before successful deletion and retains failed-run
evidence for its owning stand to collect. The next attempt exposed the actual
`carrier` timeout. Neither attempt is credited as a passing test or as a
reproduction of the user's asymmetric-message complaint.

The Windows core deliberately pins outbound control sockets to an interface to
avoid recursion through its own VPN. An existing native runtime test already
documents why its loopback reflector arrangement is Unix-only. A separate
Winsock control on this machine verifies the distinction:

| Owned UDP exchange | Result |
|---|---|
| Ordinary socket to loopback | Received exact random payload |
| Socket pinned as the core pins it, to loopback | Send refused with error 10049 |
| Same pin, to this host's selected interface address | Received exact random payload |

Only the owned sockets' options are set. No system route, global pin, VPN,
firewall rule or production protection is changed. The native socket option's
numeric value is checked against the cached Windows API bindings; an earlier
control compile failed because the host's older .NET enum lacks that name and
is excluded from the results.

Windows qualification now requires an explicit local IPv4 address owned by the
host. The fixture verifies ownership, opts its synthetic nodes into LAN
listening and substitutes only the direct transport endpoint in their native
bootstrap invites, preserving the original key, algorithm and nonce. Unix keeps
its prior loopback default. An unconfigured Windows run is explicitly skipped,
never reported as a pass. Addresses remain in private stand records, not here.

## Passing native checks

The corrected baseline passed request/accept, signed avatar exchange/update/
clear, encrypted-state close/reopen, authenticated avatar refresh and a text
control after restart. The extended final test also verifies concurrent text
in **both directions**, before and after restarting one node:

- Four outgoing messages have unique stored IDs and exactly one matching
  incoming row, with the expected body, direction and sovereign author.
- Each sender reaches `delivered`; each recipient's ordinary
  `MessagingService.incoming` stream emits exactly one matching notice. This
  checks the application event used by the UI, not only bytes on a socket.
- Both nodes have authenticated avatar frames and persisted ratchet keys.
  After reopen the original identity, accepted contact and cached profile
  data are retained. If the first cold push is observed without an authenticated
  ratchet session, the fixture checks that it cannot override the cache. The
  existing authenticated pull path supplies the current value.
- All node/service/storage owners stop; the runtime directories and synthetic
  fixture disappear. Each owned UDP listener and requested metrics port can
  be rebound after teardown. The stand verifies actual process exit afterward.

**One enabled end-to-end fixture passes, no skip.** It exercises these phases;
it is not several independent samples or a latency benchmark. It uses JIT Dart
services with the packaged Release native DLLs, not the Flutter application's
AOT UI. The 4,256 frozen application/test inputs and selected DLL hashes remain
unchanged. The adjusted stand-only fixture has a separate SHA verified before
and after the run. Analysis of the checked-in fixture is clean.

After the successful test, a separate cleanup verifies no owned source process
is alive and all synthetic fixtures are absent. It removes approximately
2.45 GiB of owned native build intermediates and test cache, preserving both
qualified packages and their component artifacts. All 45 packaged file hashes
and 4,256 frozen input hashes still match after cleanup.

## What remains open

The reported Windows 10 peer, network and actual chat widget are not tested.
The new asymmetric-message complaint remains open: a successful controlled
native pair does not prove that the reporter's acceptance reply arrived or
that their visible history refreshed. This test also does not qualify incoming
Windows toast display/COM activation, camera capture or outgoing video. There
is no push, release, production-default activation or change to real contacts.
