import 'dart:convert';

import '../core/ids.dart';
import 'space_post.dart';

const int kSpaceLifecycleContentHeadsMax = 4096;

enum SpaceLifecycleState {
  active,
  archived;

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
    return state == SpaceLifecycleState.archived ||
        previousTransitionHash.isNotEmpty;
  }

  Map<String, dynamic> toJson() => {
    'v': 1,
    'space': spaceId.hex,
    'state': state.name,
    'previous': previousTransitionHash,
    'control': controlCheckpoint.toJson(),
    'contentPolicyVersion': contentPolicyVersion,
    'messages': [for (final head in messageHeads) head.toJson()],
    'posts': [for (final head in postHeads) head.toJson()],
    'reactions': [for (final head in reactionHeads) head.toJson()],
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
        value['v'] != 1 ||
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
      );
      return transition.isStructurallyValid ? transition : null;
    } catch (_) {
      return null;
    }
  }
}
