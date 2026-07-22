import 'dart:convert';

import '../core/ids.dart';
import 'space_post.dart';

const int kSpaceLifecycleContentHeadsMax = 4096;
const Duration kSpaceDeletionRecoveryPeriod = Duration(days: 7);
const Duration kSpaceDeletionRecoveryMax = Duration(days: 30);

enum SpaceLifecycleState {
  active,
  archived,
  deleted;

  static SpaceLifecycleState? fromName(String? value) {
    for (final state in values) {
      if (state.name == value) return state;
    }
    return null;
  }
}

/// One exact terminal of an author's message chain inside a visibility scope.
///
/// [scopeHash] commits to the internal channel+encryption-epoch scope without
/// exposing a restricted/secret channel id in the global control log. Channel
/// ids are random, but hashing the complete scope also prevents correlating a
/// clear and a protected epoch through this lifecycle record.
class SpaceMessageLifecycleHead {
  const SpaceMessageLifecycleHead({
    required this.scopeHash,
    required this.author,
    required this.seq,
    required this.hash,
  });

  final String scopeHash;
  final NodeId author;
  final int seq;
  final String hash;

  String get identity => '$scopeHash|${author.hex}';

  bool get isStructurallyValid =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(scopeHash) &&
      seq >= 0 &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(hash);

  Map<String, dynamic> toJson() => {
    'scope': scopeHash,
    'author': author.hex,
    'seq': seq,
    'hash': hash,
  };

  static SpaceMessageLifecycleHead? fromJson(Object? value) {
    if (value is! Map ||
        value['scope'] is! String ||
        value['author'] is! String ||
        value['seq'] is! int ||
        value['hash'] is! String) {
      return null;
    }
    try {
      final head = SpaceMessageLifecycleHead(
        scopeHash: value['scope'] as String,
        author: NodeId.fromHex(value['author'] as String),
        seq: value['seq'] as int,
        hash: value['hash'] as String,
      );
      return head.isStructurallyValid ? head : null;
    } catch (_) {
      return null;
    }
  }
}

/// One exact terminal of an author's Space publication chain.
class SpacePostLifecycleHead {
  const SpacePostLifecycleHead({
    required this.generationHash,
    required this.author,
    required this.seq,
    required this.hash,
  });

  final String generationHash;
  final NodeId author;
  final int seq;
  final String hash;

  String get identity => '$generationHash|${author.hex}';

  bool get isStructurallyValid =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(generationHash) &&
      seq >= 0 &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(hash);

  Map<String, dynamic> toJson() => {
    'generation': generationHash,
    'author': author.hex,
    'seq': seq,
    'hash': hash,
  };

  static SpacePostLifecycleHead? fromJson(Object? value) {
    if (value is! Map ||
        value['generation'] is! String ||
        value['author'] is! String ||
        value['seq'] is! int ||
        value['hash'] is! String) {
      return null;
    }
    try {
      final head = SpacePostLifecycleHead(
        generationHash: value['generation'] as String,
        author: NodeId.fromHex(value['author'] as String),
        seq: value['seq'] as int,
        hash: value['hash'] as String,
      );
      return head.isStructurallyValid ? head : null;
    } catch (_) {
      return null;
    }
  }
}

/// One exact terminal of an author's reaction log in one lifecycle generation.
class SpaceReactionLifecycleHead {
  const SpaceReactionLifecycleHead({
    required this.generationHash,
    required this.author,
    required this.seq,
    required this.hash,
  });

  final String generationHash;
  final NodeId author;
  final int seq;
  final String hash;

  String get identity => '$generationHash|${author.hex}';

  bool get isStructurallyValid =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(generationHash) &&
      seq >= 0 &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(hash);

  Map<String, dynamic> toJson() => {
    'generation': generationHash,
    'author': author.hex,
    'seq': seq,
    'hash': hash,
  };

  static SpaceReactionLifecycleHead? fromJson(Object? value) {
    if (value is! Map ||
        value['generation'] is! String ||
        value['author'] is! String ||
        value['seq'] is! int ||
        value['hash'] is! String) {
      return null;
    }
    try {
      final head = SpaceReactionLifecycleHead(
        generationHash: value['generation'] as String,
        author: NodeId.fromHex(value['author'] as String),
        seq: value['seq'] as int,
        hash: value['hash'] as String,
      );
      return head.isStructurallyValid ? head : null;
    } catch (_) {
      return null;
    }
  }
}

/// Owner-signed Space archive/restore transition.
///
/// The control checkpoint is the exact authorization cut preceding the
/// transition. Message, post and reaction heads are the immutable readable
/// boundary: delayed rows inside that prefix may still arrive, while any
/// suffix remains quarantined until restore starts a new active period.
class SpaceLifecycleTransition {
  SpaceLifecycleTransition({
    required this.spaceId,
    required this.state,
    required this.previousTransitionHash,
    required this.controlCheckpoint,
    required this.contentPolicyVersion,
    required Iterable<SpaceMessageLifecycleHead> messageHeads,
    required Iterable<SpacePostLifecycleHead> postHeads,
    required Iterable<SpaceReactionLifecycleHead> reactionHeads,
    required this.changedAtMs,
    this.recoveryDeadlineMs,
  }) : messageHeads = List.unmodifiable(messageHeads),
       postHeads = List.unmodifiable(postHeads),
       reactionHeads = List.unmodifiable(reactionHeads);

  final NodeId spaceId;
  final SpaceLifecycleState state;
  final String previousTransitionHash;
  final SpaceControlCheckpoint controlCheckpoint;
  final int contentPolicyVersion;
  final List<SpaceMessageLifecycleHead> messageHeads;
  final List<SpacePostLifecycleHead> postHeads;
  final List<SpaceReactionLifecycleHead> reactionHeads;
  final int changedAtMs;

  /// Present only for a recoverable deletion and the matching restoration.
  /// Repeating the deadline in the restore row makes the recovery-window
  /// decision deterministic on every peer without consulting local settings.
  final int? recoveryDeadlineMs;

  bool get isRecoverableDeletion =>
      state == SpaceLifecycleState.deleted && recoveryDeadlineMs != null;

  bool get isStructurallyValid {
    if (changedAtMs < 0 ||
        contentPolicyVersion < 0 ||
        (previousTransitionHash.isNotEmpty &&
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(previousTransitionHash)) ||
        !controlCheckpoint.isStructurallyValid ||
        messageHeads.length > kSpaceLifecycleContentHeadsMax ||
        postHeads.length > kSpaceLifecycleContentHeadsMax ||
        reactionHeads.length > kSpaceLifecycleContentHeadsMax) {
      return false;
    }
    final recovery = recoveryDeadlineMs;
    if (state == SpaceLifecycleState.archived && recovery != null) {
      return false;
    }
    if (state == SpaceLifecycleState.deleted &&
        (recovery == null ||
            recovery <= changedAtMs ||
            recovery - changedAtMs >
                kSpaceDeletionRecoveryMax.inMilliseconds)) {
      return false;
    }
    if (state == SpaceLifecycleState.active &&
        recovery != null &&
        changedAtMs > recovery) {
      return false;
    }
    String? previousMessage;
    for (final head in messageHeads) {
      if (!head.isStructurallyValid ||
          (previousMessage != null &&
              head.identity.compareTo(previousMessage) <= 0)) {
        return false;
      }
      previousMessage = head.identity;
    }
    String? previousPost;
    for (final head in postHeads) {
      if (!head.isStructurallyValid ||
          (previousPost != null &&
              head.identity.compareTo(previousPost) <= 0)) {
        return false;
      }
      previousPost = head.identity;
    }
    String? previousReaction;
    for (final head in reactionHeads) {
      if (!head.isStructurallyValid ||
          (previousReaction != null &&
              head.identity.compareTo(previousReaction) <= 0)) {
        return false;
      }
      previousReaction = head.identity;
    }
    return state != SpaceLifecycleState.active ||
        previousTransitionHash.isNotEmpty;
  }

  Map<String, dynamic> toJson() => {
    'v': recoveryDeadlineMs == null ? 1 : 2,
    'space': spaceId.hex,
    'state': state.name,
    'previous': previousTransitionHash,
    'control': controlCheckpoint.toJson(),
    'contentPolicyVersion': contentPolicyVersion,
    'messages': [for (final head in messageHeads) head.toJson()],
    'posts': [for (final head in postHeads) head.toJson()],
    'reactions': [for (final head in reactionHeads) head.toJson()],
    if (recoveryDeadlineMs != null) 'recoveryDeadline': recoveryDeadlineMs,
    'ts': changedAtMs,
  };

  /// Stable comparison for restore: no content mutation is legal while the
  /// Space is archived, so the restored transition must repeat the archive's
  /// exact content cut.
  String contentBoundaryJson() => jsonEncode({
    'messages': [for (final head in messageHeads) head.toJson()],
    'posts': [for (final head in postHeads) head.toJson()],
    'reactions': [for (final head in reactionHeads) head.toJson()],
  });

  static SpaceLifecycleTransition? fromJson(Object? value) {
    if (value is! Map ||
        (value['v'] != 1 && value['v'] != 2) ||
        value['space'] is! String ||
        value['state'] is! String ||
        value['previous'] is! String ||
        value['contentPolicyVersion'] is! int ||
        value['messages'] is! List ||
        value['posts'] is! List ||
        value['reactions'] is! List ||
        value['ts'] is! int) {
      return null;
    }
    final wireVersion = value['v'] as int;
    final recoveryDeadline = value['recoveryDeadline'];
    if ((wireVersion == 1 && recoveryDeadline != null) ||
        (wireVersion == 2 && recoveryDeadline is! int)) {
      return null;
    }
    final state = SpaceLifecycleState.fromName(value['state'] as String);
    final control = SpaceControlCheckpoint.fromJson(value['control']);
    if (state == null || control == null) return null;
    final rawMessages = value['messages'] as List;
    final rawPosts = value['posts'] as List;
    final rawReactions = value['reactions'] as List;
    final messages = rawMessages
        .map(SpaceMessageLifecycleHead.fromJson)
        .whereType<SpaceMessageLifecycleHead>()
        .toList();
    final posts = rawPosts
        .map(SpacePostLifecycleHead.fromJson)
        .whereType<SpacePostLifecycleHead>()
        .toList();
    final reactions = rawReactions
        .map(SpaceReactionLifecycleHead.fromJson)
        .whereType<SpaceReactionLifecycleHead>()
        .toList();
    if (messages.length != rawMessages.length ||
        posts.length != rawPosts.length ||
        reactions.length != rawReactions.length) {
      return null;
    }
    try {
      final transition = SpaceLifecycleTransition(
        spaceId: NodeId.fromHex(value['space'] as String),
        state: state,
        previousTransitionHash: value['previous'] as String,
        controlCheckpoint: control,
        contentPolicyVersion: value['contentPolicyVersion'] as int,
        messageHeads: messages,
        postHeads: posts,
        reactionHeads: reactions,
        changedAtMs: value['ts'] as int,
        recoveryDeadlineMs: recoveryDeadline as int?,
      );
      return transition.isStructurallyValid ? transition : null;
    } catch (_) {
      return null;
    }
  }
}

/// Compact local anti-resurrection marker retained after the heavy Space
/// bundle has been physically purged. The hash names the exact owner-signed
/// delete control row; only an incoming log containing that row followed by a
/// valid in-window restore may materialize the Space again.
class SpaceDeletionTombstone {
  const SpaceDeletionTombstone({
    required this.spaceId,
    required this.deleteTransitionHash,
    required this.recoveryDeadlineMs,
    required this.purgedAtMs,
  });

  final NodeId spaceId;
  final String deleteTransitionHash;
  final int recoveryDeadlineMs;
  final int purgedAtMs;

  bool get isStructurallyValid =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(deleteTransitionHash) &&
      recoveryDeadlineMs >= 0 &&
      purgedAtMs >= recoveryDeadlineMs;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'space': spaceId.hex,
    'delete': deleteTransitionHash,
    'recoveryDeadline': recoveryDeadlineMs,
    'purgedAt': purgedAtMs,
  };

  static SpaceDeletionTombstone? fromJson(Object? value) {
    if (value is! Map ||
        value['v'] != 1 ||
        value['space'] is! String ||
        value['delete'] is! String ||
        value['recoveryDeadline'] is! int ||
        value['purgedAt'] is! int) {
      return null;
    }
    try {
      final tombstone = SpaceDeletionTombstone(
        spaceId: NodeId.fromHex(value['space'] as String),
        deleteTransitionHash: value['delete'] as String,
        recoveryDeadlineMs: value['recoveryDeadline'] as int,
        purgedAtMs: value['purgedAt'] as int,
      );
      return tombstone.isStructurallyValid ? tombstone : null;
    } catch (_) {
      return null;
    }
  }
}
