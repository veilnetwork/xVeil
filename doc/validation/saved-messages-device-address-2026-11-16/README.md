# Saved Messages: local device address

Status: confirmed visibility defect fixed; host checks and ordinary Android
release/AOT encrypted-profile qualification pass. Managed storage remains disabled
by default.

## Evidence and cause

The earlier hook-free Android release/AOT run submitted text through the normal
Saved Messages composer. The field cleared but no note appeared. A separately
opted-in profile/AOT build reopened that same synthetic Android store without
resetting it. The real native stack was present. Both submitted notes survived
cold opening in the transport/device conversation; the sovereign identity
conversation was empty. The visible symptom was not loss or corruption.

The drawer, chat self-classification, chat-list label and forwarding picker used
the sovereign address, while saveNote, file notes and reactions consistently use
the local transport address. Those addresses differ in a normal sovereign
session. The UI now resolves the exact messaging owner's existing local bucket.
It neither moves stored messages nor changes their event authors or wire format.

The address provider is keyed by the captured MessagingService. The existing
storage-owner switch guard stays ahead of it. Until this local, non-network
lookup completes, the chat offers no connection-request composer. Message and
contact reads start concurrently rather than behind the lookup. The first
visible history snapshot is accounted for even if it arrived before the message
listener was attached; its watermark prevents duplicate durable read updates.
Forward attribution still names the sovereign author, independently of the local
destination. A now-unreachable no-target string was removed from all locales.

## Verification

Five UI regressions use distinct sovereign and device IDs, real
MessagingService methods and real HiddenVolumeStorage over an in-memory KV
adapter. Message streams are not replaced with canned lists. They cover drawer
navigation to existing notes, local text submission, a gated unresolved device
address, text forwarding and held-file forwarding including blob readback.
Submitted/forwarded notes are delivered, the identity bucket stays empty and
neither transport sends nor durable Outbox entries are created. The drawer's
public header continues to display the sovereign identity.

All five fail against unchanged product sources. Early fixture compilation,
fake-clock cleanup and router-oracle mistakes were corrected before crediting
that replay. The fixed-code run passes 44 checks across ten chat/service suites,
including consent, file notes, identity switching, read windows, reactions,
composer input and message actions. Thirteen checks across four overlapping
localization/read-window/regression suites also pass; these are not added as
independent coverage. Focused analysis is clean. The first candidate missed the
initial read-window snapshot; the existing read-window suite caught it, and the
final run includes its correction.

## Android packaged qualification

The same synthetic Android 15 AOSP data was retained throughout. A profile/AOT
APK, with both existing diagnostic opt-ins explicitly enabled, replaced only the
separate QA package. All five native libraries matched the earlier independently
qualified release inputs. Through the ordinary navigation drawer the original
two notes became visible, preserving their exact IDs. The chat list now labels
the conversation Saved Messages rather than showing a pending-request hint.
A third note submitted through the real composer was visible and delivered;
the identity bucket stayed empty and durable Outbox depth stayed zero. Full
process termination, cold opening and drawer navigation preserved all three IDs,
bodies and delivered statuses, with no replacement identity/device.

A separate **hook-free release/AOT** APK then compiled the normal entrypoint
from the same fixed sources, with managed storage enabled and testnet selected.
It retained the separate QA application ID and explicit debug-signing permission.
All 3,045 tracked product inputs and the two isolated package/label substitutions
were checked. Signature, native asset routing, AOT symbols/no JIT kernel, five
independently stripped native reconstructions and both artifact privacy scanners
passed. The original release control APK was restored byte for byte after the
build; no old baseline was silently relabeled as a candidate.

That release APK updated the same QA package without clearing data. Its bytes
were checked again on the emulator, and the diagnostic listener was absent.
Ordinary Android password entry and navigation-drawer input showed all three
notes. A fourth note was typed with the Android keyboard, its exact value
verified in the actual field, and submitted using Send. After verified process
exit and another ordinary password unlock, both original bodies and each new
body appeared exactly once per stored note (two originals, one profile-submitted,
one release-submitted). The composer was empty. No HTTP hook was involved in
that release check.

The diagnostic router's base /home value was not credited as a pushed-route
oracle. Host tests inspect the actual ChatScreen argument; packaged checks use
actual visible notes. Stale semantics IDs, an exclusive-bind refusal after the
old ADB forward was removed, and confusing the bottom Menu tab with the
navigation drawer were stand errors, corrected before crediting the final runs.
They are not product-defect findings.

## Boundaries

This defect predates managed storage and affects the UI-to-service address
boundary. The packaged run qualifies an encrypted profile on AOSP ARM64, not
all three modes, OS-vault/OEM behavior, Windows/macOS or default activation.
The profile/API phase verifies exact IDs and durable state; the hook-free
release phase independently verifies real input, visible bodies and cold reopen.
No namespace migration, real user profile rewrite, host application window,
production signing, push or release was performed. The owned virtual application
and emulator were stopped, their process exit checked and owned ADB forwards
removed. Synthetic data and evidence remain private. Verified temporary strip
reconstructions and the redundant baseline copy were removed (93 MiB); the
original release control remains intact.
