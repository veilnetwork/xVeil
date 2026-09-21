// A request to empty a conversation, waiting for the person to answer it.
//
// Only a chat whose policy is [ClearRequestPolicy.ask] ever makes one of
// these. It exists so that "ask me" is a real answer rather than a quiet
// "no": the messages stay exactly where they are, and the request keeps
// everything needed to carry it out later, unchanged, if the person says yes.
//
// WHAT IT HOLDS AND WHY. A clear travels as a per-author sequence WATERMARK
// and as nothing else — no message id, no text (the no-oracle rule: a clear
// frame must not tell a relay or a seizure which messages existed). So the
// watermark is what must be kept, already re-spelled in this device's own
// names, or answering "yes" a day later would mean re-deriving a translation
// from names the request no longer carries.

import 'dart:convert';

/// One unanswered request to clear a conversation.
class PendingClearRequest {
  const PendingClearRequest({
    required this.chatHex,
    required this.requesterHex,
    required this.atMs,
    required this.seq,
    required this.watermark,
  });

  /// The conversation this asks to empty — a peer's hex for a 1:1 chat.
  final String chatHex;

  /// Who asked, as this device knows them.
  final String requesterHex;

  /// When it arrived HERE. Not when the sender says it was made: a stamp off
  /// the wire orders nothing we can trust, and this one only has to say how
  /// long a person has been sitting on an unanswered question.
  final int atMs;

  /// The clear's own sequence in the requester's stream. Carried so applying
  /// later occupies the same slot it would have occupied on arrival — the
  /// per-author stream stays gap-free either way.
  final int seq;

  /// The watermark, ALREADY in this device's names. See the header.
  final Map<String, int> watermark;

  /// One pending request per (chat, requester): asking twice is still one
  /// question, and the later ask is the one to answer.
  String get key => '$chatHex|$requesterHex';

  Map<String, dynamic> toJson() => {
    'c': chatHex,
    'r': requesterHex,
    't': atMs,
    'q': seq,
    'wm': watermark,
  };

  /// Null for anything this build cannot act on. A request that cannot be
  /// carried out exactly is not shown as a question — offering a person a
  /// "yes" that would do something other than what was asked is worse than
  /// dropping it.
  static PendingClearRequest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final chat = raw['c'];
    final requester = raw['r'];
    final at = raw['t'];
    final seq = raw['q'];
    final wm = raw['wm'];
    if (chat is! String || chat.isEmpty) return null;
    if (requester is! String || requester.isEmpty) return null;
    if (at is! int || seq is! int) return null;
    if (wm is! Map) return null;
    final watermark = <String, int>{};
    wm.forEach((k, v) {
      if (k is String && v is int) watermark[k] = v;
    });
    return PendingClearRequest(
      chatHex: chat,
      requesterHex: requester,
      atMs: at,
      seq: seq,
      watermark: watermark,
    );
  }
}

/// The settings key the list lives under, inside the deniable container.
///
/// Never in plaintext preferences: the list says who asked to erase what, and
/// on a seized device that is a map of the conversations worth reading.
const String kPendingClearRequestsKey = 'clear.requests.v1';

/// How many unanswered requests are kept.
///
/// Bounded because the list grows from the NETWORK: an accepted contact that
/// asks in a loop must not be able to fill the container. One request per
/// (chat, requester) already caps it at the number of contacts, so this is the
/// second fence rather than the first — and the OLDEST goes, because the
/// newest question is the one a person can still act on.
const int kMaxPendingClearRequests = 64;

/// Fold a new request into the list: newest per (chat, requester), newest
/// first, bounded.
///
/// Pure, because every way this can be wrong is a decision about ORDER and
/// REPLACEMENT, and neither is observable from outside once the list is stored.
List<PendingClearRequest> foldPendingClearRequest(
  List<PendingClearRequest> existing,
  PendingClearRequest arriving,
) {
  final out = [
    arriving,
    for (final request in existing)
      if (request.key != arriving.key) request,
  ];
  return out.length <= kMaxPendingClearRequests
      ? out
      : out.sublist(0, kMaxPendingClearRequests);
}

String encodePendingClearRequests(List<PendingClearRequest> requests) =>
    jsonEncode([for (final request in requests) request.toJson()]);

List<PendingClearRequest> decodePendingClearRequests(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [
      for (final entry in decoded) ?PendingClearRequest.fromJson(entry),
    ];
  } on FormatException {
    return const [];
  }
}
