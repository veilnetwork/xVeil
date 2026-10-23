# Bidirectional relay files on the returned Poco — 24 October 2026

**PASS for this physical 4 MiB run in both directions.** This adds the reverse
Mac → Android direction on native SDK `50fa7a2f`. It does not supersede the
earlier failing cellular runs or qualify the outstanding 32 MiB transfer gate.

The subsequent [32 MiB and source-restart investigation](../file-source-restart-2026-10-24/README.md)
adds successful ordinary transfers in both directions and a requester-proof
recovery correction. Interrupted 32 MiB completion and variable throughput
remain unqualified; those results are separate from this 4 MiB run.

The returned Poco used mobile data with Wi-Fi off; the Mac used its existing
connection. Both owned QA contacts had P2P explicitly denied for the transfer,
so the files used anonymous relay streams. Installed APK, loaded Mac library
and frozen-build source hashes were checked before testing. No call, media
device or physical audio output was opened.

| Action | Result |
| --- | --- |
| Contact request and acceptance | Accepted in 11.117 s from request initiation. |
| Mac → Poco text | One copy in 0.584 s. |
| Poco → Mac text | One copy in 0.580 s. |
| Mac → Poco, 4 MiB | Download in 28.654 s; SHA-256 matches. |
| Poco → Mac, 4 MiB | Download in 16.903 s; SHA-256 matches. |

Both files meet the existing 180-second completion gate. Transfer times exclude
offer preparation and delivery. These are single successful samples, not a
throughput distribution or evidence that intermittent stalls disappeared.

## Cleanup

Contact policies, the native diagnostic property and profile selection were
restored. The original phone APK was restored and its hash checked. An
independent check after the launcher exited found the owned Mac process, phone
process, log capture and ADB forwarding absent. The cleanup subprocess initially
reported the terminated Mac child as still present; the parent had not yet
reaped it. The independent check confirms it exited.

Only numeric and boolean evidence is committed in [summary.json](summary.json).
Raw logs, identifiers, addresses, content IDs, keys, APKs and test payloads remain
private. Audio/video, Windows, large files and crash/reconnect transfers require
separate qualification. The [previous report](../bbr-degraded-path-2026-10-23/README.md)
still records failing cellular file gates.
