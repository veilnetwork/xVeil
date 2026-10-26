# Linking an already configured device

Local changes after 0.13.93. No release, push or relay deployment.

## Confirmed defects and corrections

| Finding | Evidence before correction | Correction |
| --- | --- | --- |
| Pasted current QR offer was treated as a legacy setup token | Paste-only native/UI regression displayed the invalid-token error | Dispatch `veil:pair?` to the same LAN ceremony as the scanner; show the input outside the legacy section and add the existing timed secret-copy control beside the source QR |
| An independently configured target sent its previous identity document to the source | Physical Android-source/macOS-target ceremony received the request, then source document adoption failed because the foreign document did not name the source key; standalone-target UI/native regression failed before target restart | Initial new-QR request carries the physical device invite without its previous identity document; source approval certifies that key into the source identity |
| Target tried an in-place native reload while switching identities | After the preceding correction, the physical target stored the approved document but displayed the operation failure before completion; standalone-target regression still failed before restart | Capture whether a restart is required before document adoption; reload only for an update within the current identity; persist the admission and use the existing node restart for a different identity |

Document signature, source/token binding, membership, expiry and safety-code
checks remain. Refusal to merge an unrelated identity document is correct and
was not relaxed. Legacy document merging is unchanged. The new request still
uses the encrypted direct LAN ceremony; no mailbox fallback or production debug
API was added. The approved token carries the source's document naming the
joining key.

## Automated evidence

The final gated three-node native/widget run passed all three input variants:
scanner return, pasted offer and pasted offer on an independently provisioned
target with its own real identity document. In the last variant the pre-existing
Y master is the target and the spare standalone device is the external peer;
role labels below describe the resulting topology, not the fixture filenames.

A is the source, B the target, C the external peer. Each variant checks:

- An unapproved request leaves B's identity unchanged; safety codes match.
- Source certificate/code approval produces a signed admission. B restarts its
  real native node before readiness is released and the source sends history.
- A/B share the group and address exactly the two physical device keys.
- Old A/C history arrives on B; incoming and outgoing texts arrive once, with
  matching logical IDs on A and B.
- B stops, A sends to C, C stops, B returns and recovers from online A.
- Both rendered device lists remain correct; the copied encrypted recovery
  credential is preserved and rejects an incorrect recovery code.

The first paste run also exposed a fixture clock stall while waiting for group
adoption. That UI-owned wait now pumps frames, as its restart and teardown
already do. The corrected scan/paste run passed before the standalone-target
regression was added. Both independently configured target failures were
observed before their respective corrections; the final three-path run passed.

The 44 focused pairing/invite/link/device-screen tests passed. Direct Dart
analysis and whitespace checks passed. Native SDK code did not change in this
cycle. The current SDK Android library was built with production features,
without low-difficulty or native test hooks, using the guarded external target
filesystem. The final debug QA APK's selected native library and installed APK
were compared exactly; the main Android package and its data were untouched.

## Physical evidence and remaining limits

Before linking, retained macOS/Blackview QA identities on the current SDK passed
text delivery in both directions (about 1.3 and 1.6 seconds, no duplicates).
Both call directions rang and were accepted; receive packet counters advanced
on both endpoints during the ten-second observation. These are packet-flow
checks, not a live speech, loudness or video-quality assessment.

The physical new-QR request was decoded from rendered app pixels and pasted on
Mac; it reached the Android source, matching safety codes were checked and the
recovery code was entered only on the source. This reproduced both configured-
target blockers. Successful end-to-end physical completion after the final
restart correction was not qualified: the retained QA target was already in a
partially adopted state, and the hot-reloaded stand also lost its semantics
surface. No encrypted profile or ratchet state was rolled back to manufacture
a clean result. The partial QA profiles were retained privately for follow-up.

The final automated target restart is owned by the fixture through the real
native stack, not the complete production AppController. Camera capture,
Windows 10, a fresh physical pairing with the final correction and the complete
63-scenario multi-device campaign remain unqualified. The user's entire
Windows/Android report is therefore not declared resolved.

Owned stand apps, native test runners and relay processes were checked exited;
QA permissions and own ADB forwarding were restored. The temporary build-source
overlay was restored after shutdown. Capabilities, recovery codes, identifiers,
profiles, native clocks and raw logs stay in private evidence storage. Only
aggregate results and role labels are committed.

## Follow-up

[Cold physical A/B/C verification](../qr-physical-three-devices-2026-10-26/README.md)
subsequently qualified the configured-target ceremony on Blackview/macOS,
including the production AppController restart. Its separate remaining limits
and content-reoffer retry correction are recorded there.
