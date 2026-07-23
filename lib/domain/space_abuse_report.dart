import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import 'space_moderation.dart';

const int kSpaceAbuseReportDetailsMaxBytes = 4096;
const int kSpaceAbuseReportDecisionReasonMaxBytes = 4096;
const int kSpaceAbuseReportWireMaxBytes = 16 * 1024;

final RegExp _spaceAbuseReportIdPattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _spaceAbuseModerationActionIdPattern = RegExp(
  r'^[0-9a-f]{64}:[0-9]+$',
);

enum SpaceAbuseCategory {
  spam,
  harassment,
  violence,
  sexualContent,
  illegalContent,
  misinformation,
  other;

  static SpaceAbuseCategory? fromName(String? value) {
    for (final category in values) {
      if (category.name == value) return category;
    }
    return null;
  }
}

/// One reporter-signed, reviewer-addressed complaint about an exact immutable
/// Space publication or comment.
///
/// The report is transported outside the shared Space log: its details are
/// visible only to the reporter and the current owner acting as the bounded
/// moderation-inbox reviewer. Content identity remains canonical even after a
/// later edit or deletion.
class SpaceAbuseReport {
  SpaceAbuseReport({
    required this.reportId,
    required this.spaceId,
    required this.post,
    required this.target,
    required this.reporter,
    required this.reviewer,
    required this.category,
    required this.details,
    required this.createdAtMs,
    required this.signature,
    required this.authorPubKey,
  });

  static const int version = 1;
  static const String kind = 'xveil.space.abuse-report';

  final String reportId;
  final NodeId spaceId;
  final SpaceModerationReference post;
  final SpaceModerationReference target;
  final NodeId reporter;
  final NodeId reviewer;
  final SpaceAbuseCategory category;
  final String details;
  final int createdAtMs;
  final Uint8List signature;
  final Uint8List authorPubKey;

  String get postId => post.contentId;
  String? get commentRef =>
      target.kind == SpaceModerationReferenceKind.spacePostComment
      ? target.contentId
      : null;
  String get contentKey =>
      '${spaceId.hex}|${post.contentId}|${target.kind.name}|${target.contentId}';

  bool get isStructurallyValid {
    if (!_spaceAbuseReportIdPattern.hasMatch(reportId) ||
        post.kind != SpaceModerationReferenceKind.spacePost ||
        post.channelId != null ||
        target.channelId != null ||
        (target.kind != SpaceModerationReferenceKind.spacePost &&
            target.kind != SpaceModerationReferenceKind.spacePostComment) ||
        !post.isStructurallyValid ||
        !target.isStructurallyValid ||
        reporter == reviewer ||
        reporter == target.author ||
        createdAtMs < 0 ||
        details != details.trim() ||
        utf8.encode(details).length > kSpaceAbuseReportDetailsMaxBytes ||
        (category == SpaceAbuseCategory.other && details.isEmpty) ||
        (signature.isNotEmpty && signature.length != 64) ||
        (authorPubKey.isNotEmpty && authorPubKey.length != 32)) {
      return false;
    }
    return target.kind != SpaceModerationReferenceKind.spacePost ||
        (target.author == post.author && target.seq == post.seq);
  }

  Map<String, dynamic> _unsignedJson() => {
    'v': version,
    'kind': kind,
    'id': reportId,
    'space': spaceId.hex,
    'post': post.toJson(),
    'target': target.toJson(),
    'reporter': reporter.hex,
    'reviewer': reviewer.hex,
    'category': category.name,
    'details': details,
    'createdAt': createdAtMs,
  };

  Uint8List canonicalBytes() => Uint8List.fromList([
    ...utf8.encode('xveil.space.abuse-report.v1\u0000'),
    ...utf8.encode(jsonEncode(_unsignedJson())),
  ]);

  SpaceAbuseReport withSignature(
    Uint8List nextSignature,
    Uint8List publicKey,
  ) => SpaceAbuseReport(
    reportId: reportId,
    spaceId: spaceId,
    post: post,
    target: target,
    reporter: reporter,
    reviewer: reviewer,
    category: category,
    details: details,
    createdAtMs: createdAtMs,
    signature: Uint8List.fromList(nextSignature),
    authorPubKey: Uint8List.fromList(publicKey),
  );

  Map<String, dynamic> toJson() => {
    ..._unsignedJson(),
    'signature': base64Encode(signature),
    'authorPublicKey': base64Encode(authorPubKey),
  };

  static SpaceAbuseReport? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {
          'v',
          'kind',
          'id',
          'space',
          'post',
          'target',
          'reporter',
          'reviewer',
          'category',
          'details',
          'createdAt',
          'signature',
          'authorPublicKey',
        }) ||
        value['v'] != version ||
        value['kind'] != kind ||
        value['id'] is! String ||
        value['space'] is! String ||
        value['post'] is! Map ||
        value['target'] is! Map ||
        value['reporter'] is! String ||
        value['reviewer'] is! String ||
        value['category'] is! String ||
        value['details'] is! String ||
        value['createdAt'] is! int ||
        value['signature'] is! String ||
        value['authorPublicKey'] is! String) {
      return null;
    }
    try {
      final post = SpaceModerationReference.fromJson(value['post']);
      final target = SpaceModerationReference.fromJson(value['target']);
      final category = SpaceAbuseCategory.fromName(
        value['category'] as String?,
      );
      if (post == null || target == null || category == null) return null;
      final report = SpaceAbuseReport(
        reportId: value['id'] as String,
        spaceId: NodeId.fromHex(value['space'] as String),
        post: post,
        target: target,
        reporter: NodeId.fromHex(value['reporter'] as String),
        reviewer: NodeId.fromHex(value['reviewer'] as String),
        category: category,
        details: value['details'] as String,
        createdAtMs: value['createdAt'] as int,
        signature: Uint8List.fromList(
          base64Decode(value['signature'] as String),
        ),
        authorPubKey: Uint8List.fromList(
          base64Decode(value['authorPublicKey'] as String),
        ),
      );
      return report.isStructurallyValid &&
              report.signature.length == 64 &&
              report.authorPubKey.length == 32
          ? report
          : null;
    } catch (_) {
      return null;
    }
  }
}

enum SpaceAbuseReportOutcome {
  dismissed,
  resolved,
  contentRemoved;

  static SpaceAbuseReportOutcome? fromName(String? value) {
    for (final outcome in values) {
      if (outcome.name == value) return outcome;
    }
    return null;
  }
}

/// Immutable reviewer-signed status row for one exact report.
///
/// A `contentRemoved` decision is accepted only when it points to the
/// independently signed moderation action that performed the deletion.
class SpaceAbuseReportDecision {
  SpaceAbuseReportDecision({
    required this.reportId,
    required this.spaceId,
    required this.reporter,
    required this.reviewer,
    required this.outcome,
    required this.reason,
    required this.decidedAtMs,
    required this.signature,
    required this.authorPubKey,
    this.moderationActionId,
  });

  static const int version = 1;
  static const String kind = 'xveil.space.abuse-report-decision';

  final String reportId;
  final NodeId spaceId;
  final NodeId reporter;
  final NodeId reviewer;
  final SpaceAbuseReportOutcome outcome;
  final String reason;
  final int decidedAtMs;
  final String? moderationActionId;
  final Uint8List signature;
  final Uint8List authorPubKey;

  bool get isStructurallyValid =>
      _spaceAbuseReportIdPattern.hasMatch(reportId) &&
      reporter != reviewer &&
      reason.isNotEmpty &&
      reason == reason.trim() &&
      utf8.encode(reason).length <= kSpaceAbuseReportDecisionReasonMaxBytes &&
      decidedAtMs >= 0 &&
      (outcome == SpaceAbuseReportOutcome.contentRemoved
          ? moderationActionId != null &&
                _spaceAbuseModerationActionIdPattern.hasMatch(
                  moderationActionId!,
                )
          : moderationActionId == null) &&
      (signature.isEmpty || signature.length == 64) &&
      (authorPubKey.isEmpty || authorPubKey.length == 32);

  Map<String, dynamic> _unsignedJson() => {
    'v': version,
    'kind': kind,
    'id': reportId,
    'space': spaceId.hex,
    'reporter': reporter.hex,
    'reviewer': reviewer.hex,
    'outcome': outcome.name,
    'reason': reason,
    'decidedAt': decidedAtMs,
    if (moderationActionId != null) 'moderationAction': moderationActionId,
  };

  Uint8List canonicalBytes() => Uint8List.fromList([
    ...utf8.encode('xveil.space.abuse-report-decision.v1\u0000'),
    ...utf8.encode(jsonEncode(_unsignedJson())),
  ]);

  SpaceAbuseReportDecision withSignature(
    Uint8List nextSignature,
    Uint8List publicKey,
  ) => SpaceAbuseReportDecision(
    reportId: reportId,
    spaceId: spaceId,
    reporter: reporter,
    reviewer: reviewer,
    outcome: outcome,
    reason: reason,
    decidedAtMs: decidedAtMs,
    moderationActionId: moderationActionId,
    signature: Uint8List.fromList(nextSignature),
    authorPubKey: Uint8List.fromList(publicKey),
  );

  Map<String, dynamic> toJson() => {
    ..._unsignedJson(),
    'signature': base64Encode(signature),
    'authorPublicKey': base64Encode(authorPubKey),
  };

  static SpaceAbuseReportDecision? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {
          'v',
          'kind',
          'id',
          'space',
          'reporter',
          'reviewer',
          'outcome',
          'reason',
          'decidedAt',
          'moderationAction',
          'signature',
          'authorPublicKey',
        }) ||
        value['v'] != version ||
        value['kind'] != kind ||
        value['id'] is! String ||
        value['space'] is! String ||
        value['reporter'] is! String ||
        value['reviewer'] is! String ||
        value['outcome'] is! String ||
        value['reason'] is! String ||
        value['decidedAt'] is! int ||
        (value.containsKey('moderationAction') &&
            value['moderationAction'] is! String) ||
        value['signature'] is! String ||
        value['authorPublicKey'] is! String) {
      return null;
    }
    try {
      final outcome = SpaceAbuseReportOutcome.fromName(
        value['outcome'] as String?,
      );
      if (outcome == null) return null;
      final decision = SpaceAbuseReportDecision(
        reportId: value['id'] as String,
        spaceId: NodeId.fromHex(value['space'] as String),
        reporter: NodeId.fromHex(value['reporter'] as String),
        reviewer: NodeId.fromHex(value['reviewer'] as String),
        outcome: outcome,
        reason: value['reason'] as String,
        decidedAtMs: value['decidedAt'] as int,
        moderationActionId: value['moderationAction'] as String?,
        signature: Uint8List.fromList(
          base64Decode(value['signature'] as String),
        ),
        authorPubKey: Uint8List.fromList(
          base64Decode(value['authorPublicKey'] as String),
        ),
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

class SpaceAbuseReportInboxEntry {
  const SpaceAbuseReportInboxEntry({
    required this.report,
    required this.receivedAtMs,
    this.decision,
  });

  final SpaceAbuseReport report;
  final int receivedAtMs;
  final SpaceAbuseReportDecision? decision;

  bool get pending => decision == null;

  bool get isStructurallyValid =>
      report.isStructurallyValid &&
      report.signature.length == 64 &&
      report.authorPubKey.length == 32 &&
      receivedAtMs >= report.createdAtMs &&
      (decision == null ||
          (decision!.isStructurallyValid &&
              decision!.reportId == report.reportId &&
              decision!.spaceId == report.spaceId &&
              decision!.reporter == report.reporter &&
              decision!.reviewer == report.reviewer &&
              decision!.decidedAtMs >= receivedAtMs));

  Map<String, dynamic> toJson() => {
    'report': report.toJson(),
    'receivedAt': receivedAtMs,
    if (decision != null) 'decision': decision!.toJson(),
  };

  static SpaceAbuseReportInboxEntry? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {'report', 'receivedAt', 'decision'}) ||
        value['receivedAt'] is! int) {
      return null;
    }
    final report = SpaceAbuseReport.fromJson(value['report']);
    final decision = value['decision'] == null
        ? null
        : SpaceAbuseReportDecision.fromJson(value['decision']);
    if (report == null || (value['decision'] != null && decision == null)) {
      return null;
    }
    final entry = SpaceAbuseReportInboxEntry(
      report: report,
      receivedAtMs: value['receivedAt'] as int,
      decision: decision,
    );
    return entry.isStructurallyValid ? entry : null;
  }
}

class SpaceAbuseReportOutboxEntry {
  const SpaceAbuseReportOutboxEntry({required this.report, this.decision});

  final SpaceAbuseReport report;
  final SpaceAbuseReportDecision? decision;

  bool get pending => decision == null;

  bool get isStructurallyValid =>
      report.isStructurallyValid &&
      report.signature.length == 64 &&
      report.authorPubKey.length == 32 &&
      (decision == null ||
          (decision!.isStructurallyValid &&
              decision!.reportId == report.reportId &&
              decision!.spaceId == report.spaceId &&
              decision!.reporter == report.reporter &&
              decision!.reviewer == report.reviewer &&
              decision!.decidedAtMs >= report.createdAtMs));

  Map<String, dynamic> toJson() => {
    'report': report.toJson(),
    if (decision != null) 'decision': decision!.toJson(),
  };

  static SpaceAbuseReportOutboxEntry? fromJson(Object? value) {
    if (value is! Map || !_hasOnlyKeys(value, const {'report', 'decision'})) {
      return null;
    }
    final report = SpaceAbuseReport.fromJson(value['report']);
    final decision = value['decision'] == null
        ? null
        : SpaceAbuseReportDecision.fromJson(value['decision']);
    if (report == null || (value['decision'] != null && decision == null)) {
      return null;
    }
    final entry = SpaceAbuseReportOutboxEntry(
      report: report,
      decision: decision,
    );
    return entry.isStructurallyValid ? entry : null;
  }
}

bool _hasOnlyKeys(Map value, Set<String> allowed) {
  for (final key in value.keys) {
    if (key is! String || !allowed.contains(key)) return false;
  }
  return true;
}
