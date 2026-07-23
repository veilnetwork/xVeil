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

/// Reserved domain shape for a future appeal transport/UI. A banned peer is no
/// longer a control-log member, so pretending it can append this to the Space
/// log would be a security bug; the eventual delivery protocol must be an
/// explicitly rate-limited external proposal, like consent-first invites.
class SpaceModerationAppeal {
  const SpaceModerationAppeal({
    required this.actionAuthor,
    required this.actionSeq,
    required this.appellant,
    required this.text,
    required this.createdAtMs,
  });

  final NodeId actionAuthor;
  final int actionSeq;
  final NodeId appellant;
  final String text;
  final int createdAtMs;

  bool get isStructurallyValid =>
      actionSeq >= 0 &&
      createdAtMs >= 0 &&
      text.isNotEmpty &&
      text == text.trim() &&
      text.length <= kSpaceModerationAppealMax;
}
