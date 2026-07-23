import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';

const int kSpaceModerationReasonMax = 4096;
const int kSpaceModerationAppealMax = 16 * 1024;

/// A deliberately small, protocol-stable moderation vocabulary. These are
/// effects, not UI labels: every receiver can therefore enforce the same
/// signed action without trusting a moderator's client.
enum SpaceModerationKind {
  warning,
  deleteMessage,
  deletePost,
  restrictPublishing,
  restrictMessages,
  restrictVoice,
  mute,
  timeout,
  temporaryBan,
  permanentBan;

  static SpaceModerationKind? fromName(String? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }

  bool get removesMembership => this == temporaryBan || this == permanentBan;

  bool get blocksPosts =>
      this == restrictPublishing || this == timeout || removesMembership;

  bool get blocksMessages =>
      this == restrictMessages ||
      this == mute ||
      this == timeout ||
      removesMembership;

  bool get blocksVoice =>
      this == restrictVoice ||
      this == mute ||
      this == timeout ||
      removesMembership;
}

enum SpaceModerationScope {
  space,
  channel,
  posts,
  voice;

  static SpaceModerationScope? fromName(String? value) {
    for (final scope in values) {
      if (scope.name == value) return scope;
    }
    return null;
  }
}

enum SpaceModerationReferenceKind {
  message,
  spacePost;

  static SpaceModerationReferenceKind? fromName(String? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// Stable reference to content affected by a moderation action. The pair
/// `(author, seq)` is already the immutable identity used by both logs.
class SpaceModerationReference {
  const SpaceModerationReference({
    required this.kind,
    required this.author,
    required this.seq,
    this.channelId,
  });

  final SpaceModerationReferenceKind kind;
  final NodeId author;
  final int seq;
  final NodeId? channelId;

  String get contentId => '${author.hex}:$seq';

  bool get isStructurallyValid =>
      seq >= 0 &&
      (kind == SpaceModerationReferenceKind.message || channelId == null);

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'author': author.hex,
    'seq': seq,
    if (channelId != null) 'channel': channelId!.hex,
  };

  static SpaceModerationReference? fromJson(Object? value) {
    if (value is! Map ||
        value['kind'] is! String ||
        value['author'] is! String ||
        value['seq'] is! int) {
      return null;
    }
    try {
      final reference = SpaceModerationReference(
        kind: SpaceModerationReferenceKind.fromName(value['kind'] as String)!,
        author: NodeId.fromHex(value['author'] as String),
        seq: value['seq'] as int,
        channelId: value['channel'] is String
            ? NodeId.fromHex(value['channel'] as String)
            : null,
      );
      return reference.isStructurallyValid ? reference : null;
    } catch (_) {
      return null;
    }
  }
}

/// Signed payload of one immutable moderation action. Its durable id is the
/// surrounding control row's `<authorHex>:<seq>`; it is never generated from
/// wall clock time or mutable local state.
class SpaceModerationAction {
  const SpaceModerationAction({
    required this.kind,
    required this.target,
    required this.scope,
    required this.reason,
    required this.createdAtMs,
    this.channelId,
    this.expiresAtMs,
    this.reference,
  });

  final SpaceModerationKind kind;
  final NodeId target;
  final SpaceModerationScope scope;
  final String reason;
  final int createdAtMs;
  final NodeId? channelId;
  final int? expiresAtMs;
  final SpaceModerationReference? reference;

  bool get isStructurallyValid {
    if (createdAtMs < 0 ||
        reason.isEmpty ||
        reason != reason.trim() ||
        reason.length > kSpaceModerationReasonMax ||
        (expiresAtMs != null && expiresAtMs! <= createdAtMs) ||
        (scope == SpaceModerationScope.channel) != (channelId != null) ||
        (reference?.isStructurallyValid == false)) {
      return false;
    }
    switch (kind) {
      case SpaceModerationKind.warning:
        return scope == SpaceModerationScope.space &&
            expiresAtMs == null &&
            reference == null;
      case SpaceModerationKind.deleteMessage:
        return expiresAtMs == null &&
            reference?.kind == SpaceModerationReferenceKind.message &&
            reference?.author == target &&
            (scope == SpaceModerationScope.space ||
                scope == SpaceModerationScope.channel);
      case SpaceModerationKind.deletePost:
        return scope == SpaceModerationScope.posts &&
            expiresAtMs == null &&
            reference?.kind == SpaceModerationReferenceKind.spacePost &&
            reference?.author == target;
      case SpaceModerationKind.restrictPublishing:
        return scope == SpaceModerationScope.posts &&
            expiresAtMs != null &&
            reference == null;
      case SpaceModerationKind.restrictMessages:
        return (scope == SpaceModerationScope.space ||
                scope == SpaceModerationScope.channel) &&
            reference == null;
      case SpaceModerationKind.restrictVoice:
        return (scope == SpaceModerationScope.voice ||
                scope == SpaceModerationScope.channel) &&
            reference == null;
      case SpaceModerationKind.mute:
        return (scope == SpaceModerationScope.space ||
                scope == SpaceModerationScope.channel) &&
            reference == null;
      case SpaceModerationKind.timeout:
        return scope == SpaceModerationScope.space &&
            expiresAtMs != null &&
            reference == null;
      case SpaceModerationKind.temporaryBan:
        return scope == SpaceModerationScope.space &&
            expiresAtMs != null &&
            reference == null;
      case SpaceModerationKind.permanentBan:
        return scope == SpaceModerationScope.space &&
            expiresAtMs == null &&
            reference == null;
    }
  }

  Map<String, dynamic> toJson() => {
    'v': 1,
    'kind': kind.name,
    'target': target.hex,
    'scope': scope.name,
    'reason': reason,
    'createdAt': createdAtMs,
    if (channelId != null) 'channel': channelId!.hex,
    if (expiresAtMs != null) 'expiresAt': expiresAtMs,
    if (reference != null) 'reference': reference!.toJson(),
  };

  static SpaceModerationAction? fromJson(Object? value) {
    if (value is! Map ||
        value['v'] != 1 ||
        value['kind'] is! String ||
        value['target'] is! String ||
        value['scope'] is! String ||
        value['reason'] is! String ||
        value['createdAt'] is! int) {
      return null;
    }
    try {
      final kind = SpaceModerationKind.fromName(value['kind'] as String);
      final scope = SpaceModerationScope.fromName(value['scope'] as String);
      if (kind == null || scope == null) return null;
      final reference = value.containsKey('reference')
          ? SpaceModerationReference.fromJson(value['reference'])
          : null;
      if (value.containsKey('reference') && reference == null) return null;
      final action = SpaceModerationAction(
        kind: kind,
        target: NodeId.fromHex(value['target'] as String),
        scope: scope,
        reason: value['reason'] as String,
        createdAtMs: value['createdAt'] as int,
        channelId: value['channel'] is String
            ? NodeId.fromHex(value['channel'] as String)
            : null,
        expiresAtMs: value['expiresAt'] is int
            ? value['expiresAt'] as int
            : null,
        reference: reference,
      );
      return action.isStructurallyValid ? action : null;
    } catch (_) {
      return null;
    }
  }
}

class SpaceModerationRevocation {
  const SpaceModerationRevocation({
    required this.actionAuthor,
    required this.actionSeq,
    required this.reason,
    required this.revokedAtMs,
  });

  final NodeId actionAuthor;
  final int actionSeq;
  final String reason;
  final int revokedAtMs;

  String get actionId => '${actionAuthor.hex}:$actionSeq';

  bool get isStructurallyValid =>
      actionSeq >= 0 &&
      revokedAtMs >= 0 &&
      reason.isNotEmpty &&
      reason == reason.trim() &&
      reason.length <= kSpaceModerationReasonMax;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'author': actionAuthor.hex,
    'seq': actionSeq,
    'reason': reason,
    'revokedAt': revokedAtMs,
  };

  static SpaceModerationRevocation? fromJson(Object? value) {
    if (value is! Map ||
        value['v'] != 1 ||
        value['author'] is! String ||
        value['seq'] is! int ||
        value['reason'] is! String ||
        value['revokedAt'] is! int) {
      return null;
    }
    try {
      final revocation = SpaceModerationRevocation(
        actionAuthor: NodeId.fromHex(value['author'] as String),
        actionSeq: value['seq'] as int,
        reason: value['reason'] as String,
        revokedAtMs: value['revokedAt'] as int,
      );
      return revocation.isStructurallyValid ? revocation : null;
    } catch (_) {
      return null;
    }
  }
}

/// Materialized audit row. Revocation annotates the row; it never overwrites
/// or removes the original signed action.
class SpaceModerationRecord {
  const SpaceModerationRecord({
    required this.actionId,
    required this.actor,
    required this.actionSeq,
    required this.action,
    this.revokedBy,
    this.revokedAtMs,
    this.revocationReason,
  });

  final String actionId;
  final NodeId actor;
  final int actionSeq;
  final SpaceModerationAction action;
  final NodeId? revokedBy;
  final int? revokedAtMs;
  final String? revocationReason;

  bool isActiveAt(int atMs) =>
      atMs >= action.createdAtMs &&
      (revokedAtMs == null || atMs < revokedAtMs!) &&
      (action.expiresAtMs == null || atMs < action.expiresAtMs!);

  SpaceModerationRecord revoke({
    required NodeId actor,
    required SpaceModerationRevocation revocation,
  }) => SpaceModerationRecord(
    actionId: actionId,
    actor: this.actor,
    actionSeq: actionSeq,
    action: action,
    revokedBy: actor,
    revokedAtMs: revocation.revokedAtMs,
    revocationReason: revocation.reason,
  );
}

bool spaceModerationRemovesContent(
  Iterable<SpaceModerationRecord> records, {
  required SpaceModerationReferenceKind kind,
  required NodeId author,
  required int seq,
  required int atMs,
  NodeId? channelId,
}) => records.any((record) {
  if (!record.isActiveAt(atMs)) return false;
  final reference = record.action.reference;
  return reference != null &&
      reference.kind == kind &&
      reference.author == author &&
      reference.seq == seq &&
      (reference.channelId == null || reference.channelId == channelId);
});

final RegExp _spaceModerationAppealIdPattern = RegExp(r'^[0-9a-f]{64}$');

/// External, node-id-bound proposal addressed to the immutable Space owner.
///
/// A banned peer is no longer a control-log member, so this is deliberately
/// transported outside the Space log. The receiver admits at most one appeal
/// for the immutable `(space, action, appellant)` tuple; durable retries reuse
/// [appealId] and are idempotent.
class SpaceModerationAppeal {
  SpaceModerationAppeal({
    required this.appealId,
    required this.spaceId,
    required this.actionAuthor,
    required this.actionSeq,
    required this.appellant,
    required this.reviewer,
    required this.text,
    required this.createdAtMs,
    required this.signature,
    required this.authorPubKey,
  });

  final String appealId;
  final NodeId spaceId;
  final NodeId actionAuthor;
  final int actionSeq;
  final NodeId appellant;
  final NodeId reviewer;
  final String text;
  final int createdAtMs;
  final Uint8List signature;
  final Uint8List authorPubKey;

  String get actionId => '${actionAuthor.hex}:$actionSeq';

  bool get isStructurallyValid =>
      _spaceModerationAppealIdPattern.hasMatch(appealId) &&
      actionSeq >= 0 &&
      createdAtMs >= 0 &&
      appellant != reviewer &&
      text.isNotEmpty &&
      text == text.trim() &&
      utf8.encode(text).length <= kSpaceModerationAppealMax &&
      (signature.isEmpty || signature.length == 64) &&
      (authorPubKey.isEmpty || authorPubKey.length == 32);

  Map<String, dynamic> _unsignedJson() => {
    'v': 1,
    'id': appealId,
    'space': spaceId.hex,
    'author': actionAuthor.hex,
    'seq': actionSeq,
    'appellant': appellant.hex,
    'reviewer': reviewer.hex,
    'text': text,
    'createdAt': createdAtMs,
  };

  Uint8List canonicalBytes() => Uint8List.fromList([
    ...utf8.encode('xveil.space.moderation-appeal.v1\u0000'),
    ...utf8.encode(jsonEncode(_unsignedJson())),
  ]);

  SpaceModerationAppeal withSignature(
    Uint8List nextSignature,
    Uint8List publicKey,
  ) => SpaceModerationAppeal(
    appealId: appealId,
    spaceId: spaceId,
    actionAuthor: actionAuthor,
    actionSeq: actionSeq,
    appellant: appellant,
    reviewer: reviewer,
    text: text,
    createdAtMs: createdAtMs,
    signature: Uint8List.fromList(nextSignature),
    authorPubKey: Uint8List.fromList(publicKey),
  );

  Map<String, dynamic> toJson() => {
    ..._unsignedJson(),
    'sig': base64Encode(signature),
    'pk': base64Encode(authorPubKey),
  };

  static SpaceModerationAppeal? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    try {
      final appeal = SpaceModerationAppeal(
        appealId: value['id'] as String,
        spaceId: NodeId.fromHex(value['space'] as String),
        actionAuthor: NodeId.fromHex(value['author'] as String),
        actionSeq: value['seq'] as int,
        appellant: NodeId.fromHex(value['appellant'] as String),
        reviewer: NodeId.fromHex(value['reviewer'] as String),
        text: value['text'] as String,
        createdAtMs: value['createdAt'] as int,
        signature: Uint8List.fromList(base64Decode(value['sig'] as String)),
        authorPubKey: Uint8List.fromList(base64Decode(value['pk'] as String)),
      );
      return appeal.isStructurallyValid &&
              appeal.signature.length == 64 &&
              appeal.authorPubKey.length == 32
          ? appeal
          : null;
    } catch (_) {
      return null;
    }
  }
}

enum SpaceModerationAppealOutcome {
  rejected,
  actionRevoked,
  acknowledgedIrreversible;

  static SpaceModerationAppealOutcome? fromName(String? value) {
    for (final outcome in values) {
      if (outcome.name == value) return outcome;
    }
    return null;
  }
}

/// Signed owner response. This row reports review status only: the actual
/// authority for [SpaceModerationAppealOutcome.actionRevoked] remains the
/// independently signed revocation in the Space control log.
class SpaceModerationAppealDecision {
  SpaceModerationAppealDecision({
    required this.appealId,
    required this.spaceId,
    required this.appellant,
    required this.reviewer,
    required this.outcome,
    required this.reason,
    required this.decidedAtMs,
    required this.signature,
    required this.authorPubKey,
  });

  final String appealId;
  final NodeId spaceId;
  final NodeId appellant;
  final NodeId reviewer;
  final SpaceModerationAppealOutcome outcome;
  final String reason;
  final int decidedAtMs;
  final Uint8List signature;
  final Uint8List authorPubKey;

  bool get isStructurallyValid =>
      _spaceModerationAppealIdPattern.hasMatch(appealId) &&
      appellant != reviewer &&
      decidedAtMs >= 0 &&
      reason.isNotEmpty &&
      reason == reason.trim() &&
      utf8.encode(reason).length <= kSpaceModerationReasonMax &&
      (signature.isEmpty || signature.length == 64) &&
      (authorPubKey.isEmpty || authorPubKey.length == 32);

  Map<String, dynamic> _unsignedJson() => {
    'v': 1,
    'id': appealId,
    'space': spaceId.hex,
    'appellant': appellant.hex,
    'reviewer': reviewer.hex,
    'outcome': outcome.name,
    'reason': reason,
    'decidedAt': decidedAtMs,
  };

  Uint8List canonicalBytes() => Uint8List.fromList([
    ...utf8.encode('xveil.space.moderation-appeal-decision.v1\u0000'),
    ...utf8.encode(jsonEncode(_unsignedJson())),
  ]);

  SpaceModerationAppealDecision withSignature(
    Uint8List nextSignature,
    Uint8List publicKey,
  ) => SpaceModerationAppealDecision(
    appealId: appealId,
    spaceId: spaceId,
    appellant: appellant,
    reviewer: reviewer,
    outcome: outcome,
    reason: reason,
    decidedAtMs: decidedAtMs,
    signature: Uint8List.fromList(nextSignature),
    authorPubKey: Uint8List.fromList(publicKey),
  );

  Map<String, dynamic> toJson() => {
    ..._unsignedJson(),
    'sig': base64Encode(signature),
    'pk': base64Encode(authorPubKey),
  };

  static SpaceModerationAppealDecision? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    try {
      final outcome = SpaceModerationAppealOutcome.fromName(
        value['outcome'] as String?,
      );
      if (outcome == null) return null;
      final decision = SpaceModerationAppealDecision(
        appealId: value['id'] as String,
        spaceId: NodeId.fromHex(value['space'] as String),
        appellant: NodeId.fromHex(value['appellant'] as String),
        reviewer: NodeId.fromHex(value['reviewer'] as String),
        outcome: outcome,
        reason: value['reason'] as String,
        decidedAtMs: value['decidedAt'] as int,
        signature: Uint8List.fromList(base64Decode(value['sig'] as String)),
        authorPubKey: Uint8List.fromList(base64Decode(value['pk'] as String)),
      );
      return decision.isStructurallyValid &&
              decision.signature.length == 64 &&
              decision.authorPubKey.length == 32
          ? decision
          : null;
    } catch (_) {
      return null;
    }
  }
}

class SpaceModerationAppealInboxEntry {
  const SpaceModerationAppealInboxEntry({
    required this.appeal,
    required this.receivedAtMs,
    this.decision,
  });

  final SpaceModerationAppeal appeal;
  final int receivedAtMs;
  final SpaceModerationAppealDecision? decision;

  bool get pending => decision == null;

  bool get isStructurallyValid =>
      appeal.isStructurallyValid &&
      appeal.signature.length == 64 &&
      appeal.authorPubKey.length == 32 &&
      receivedAtMs >= appeal.createdAtMs &&
      (decision == null ||
          (decision!.isStructurallyValid &&
              decision!.appealId == appeal.appealId &&
              decision!.spaceId == appeal.spaceId &&
              decision!.appellant == appeal.appellant &&
              decision!.reviewer == appeal.reviewer &&
              decision!.decidedAtMs >= receivedAtMs));

  Map<String, dynamic> toJson() => {
    'appeal': appeal.toJson(),
    'receivedAt': receivedAtMs,
    if (decision != null) 'decision': decision!.toJson(),
  };

  static SpaceModerationAppealInboxEntry? fromJson(Object? value) {
    if (value is! Map || value['receivedAt'] is! int) return null;
    final appeal = SpaceModerationAppeal.fromJson(value['appeal']);
    final decision = value['decision'] == null
        ? null
        : SpaceModerationAppealDecision.fromJson(value['decision']);
    if (appeal == null || (value['decision'] != null && decision == null)) {
      return null;
    }
    final entry = SpaceModerationAppealInboxEntry(
      appeal: appeal,
      receivedAtMs: value['receivedAt'] as int,
      decision: decision,
    );
    return entry.isStructurallyValid ? entry : null;
  }
}

class SpaceModerationAppealOutboxEntry {
  const SpaceModerationAppealOutboxEntry({required this.appeal, this.decision});

  final SpaceModerationAppeal appeal;
  final SpaceModerationAppealDecision? decision;

  bool get pending => decision == null;

  bool get isStructurallyValid =>
      appeal.isStructurallyValid &&
      appeal.signature.length == 64 &&
      appeal.authorPubKey.length == 32 &&
      (decision == null ||
          (decision!.isStructurallyValid &&
              decision!.appealId == appeal.appealId &&
              decision!.spaceId == appeal.spaceId &&
              decision!.appellant == appeal.appellant &&
              decision!.reviewer == appeal.reviewer &&
              decision!.decidedAtMs >= appeal.createdAtMs));

  Map<String, dynamic> toJson() => {
    'appeal': appeal.toJson(),
    if (decision != null) 'decision': decision!.toJson(),
  };

  static SpaceModerationAppealOutboxEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final appeal = SpaceModerationAppeal.fromJson(value['appeal']);
    final decision = value['decision'] == null
        ? null
        : SpaceModerationAppealDecision.fromJson(value['decision']);
    if (appeal == null || (value['decision'] != null && decision == null)) {
      return null;
    }
    final entry = SpaceModerationAppealOutboxEntry(
      appeal: appeal,
      decision: decision,
    );
    return entry.isStructurallyValid ? entry : null;
  }
}
