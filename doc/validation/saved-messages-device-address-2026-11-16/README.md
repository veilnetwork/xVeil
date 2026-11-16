# Saved Messages: local device address

Status: confirmed visibility defect fixed and host-qualified. Android packaged
requalification follows separately. Managed storage remains disabled by default.

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

## Boundaries

This defect predates managed storage and affects the UI-to-service address
boundary. Host regressions do not by themselves prove packaged Android behavior,
all three storage modes, OS-vault support or default activation. No real user
profile was rewritten and no host application window was opened. The retained
Android synthetic data is reserved for the next packaged check. No push,
production signing or release is part of this fix.
