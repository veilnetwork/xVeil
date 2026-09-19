import 'package:flutter/foundation.dart';

/// Why the call UI is offering to drop video.
///
/// Two causes, one action. They are kept apart because they carry different
/// evidence and a user reading "connection is weak" deserves to know which:
/// one is measured HERE, the other is a peer's claim about a link we cannot
/// see.
enum CallVideoPromptCause {
  /// Measured locally: the sender-side ladder ran out of rungs and the link is
  /// still failing (see `CallVideoAdvice.suggestDisable`). Our outbound video
  /// is not arriving.
  linkFailing,

  /// The peer sent `CallSignalType.askVideoOff`: THEIR downlink cannot carry
  /// our video. Nothing local can detect this — RTCP tells a sender what its
  /// receiver got, never what this receiver is failing to get — so the only
  /// source for it is the peer saying so.
  peerAsked,
}

/// The live "offer to drop video" prompt, or null when there is nothing to
/// offer.
///
/// A notifier rather than a field on [Call]: this is raised by the 1 s media
/// stats poll and by an inbound signal, neither of which is an FSM transition,
/// so a plain getter would be read once and never repainted.
///
/// Set at most once per cause per call; cleared when the call's media stops,
/// when the user acts on it, and when the link climbs back off the floor.
final ValueNotifier<CallVideoPromptCause?> callVideoPrompt =
    ValueNotifier<CallVideoPromptCause?>(null);
