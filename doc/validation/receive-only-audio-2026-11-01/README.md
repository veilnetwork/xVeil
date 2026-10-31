# Receive-only audio and Windows investigation

## Confirmed code defect

The released media engine reports capture and playout startup separately, but
returns a combined failure if either device fails. xVeil previously rejected
that result even when playout had started and only capture was unavailable.
This made a missing microphone discard a usable receive path.

The application now accepts only the exact capture=failed / playout=started
case as receive-only, requires successful native mute, and publishes the actual
microphone-off posture to the local UI and remote peer. Unknown failures and
failed output remain failures. A failed retry cannot falsely turn the microphone
on; a successful retry restores normal capture. Native ABI and binaries are
unchanged.

## Verification

- FSM regression failed on the previous implementation (microphone stayed on)
  and passes with the change. Startup classification rejects unknown and
  ill-typed results as well as output failure.
- Call service, startup classification and microphone-state suites: 207 tests
  passed. Analysis of all five changed Dart files passed.
- Published Windows media DLL was tested under the real interactive user
  session, using real Windows audio devices and synthetic Opus RTP through an
  isolated mock transport. Both normal and explicitly muted capture runs
  accepted 200 packets and reached output level band 5.
- On this PC the normal probe reported **capture=started and playout=started**.
  Therefore the missing-microphone startup mechanism did **not** reproduce the
  owner's phone-to-Windows complaint. Packet acceptance/output level is not a
  measurement of audible volume or proof of a working network call.

## Open physical qualification

The active report of no sound in a phone-to-Windows call remains unexplained.
Windows QA uses a separate profile and the published native libraries. Its
Dart AOT and profile Flutter engine are rebuilt; runner/plugins are frozen from
release because this host lacks ATL headers for a complete native build. The
host is Windows 11, despite the earlier separate Windows 10 user reports.

Installing the separate Android QA package was refused by the OS
(`INSTALL_FAILED_USER_RESTRICTED`). The main application and identity are
unchanged. Full end-to-end audio and network-switch calls have not passed this
gate yet; no claim of fixing the owner's audio complaint is made.

Private logs, audio-device names, addresses, keys and identity material are not
included in this document. No push or release is part of this work cycle.
