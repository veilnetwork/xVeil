import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/space_abuse_report.dart';
import 'package:xveil/domain/space_moderation.dart';

NodeId _id(int value) => NodeId(Uint8List.fromList(List.filled(32, value)));

SpaceAbuseReport _report({
  SpaceModerationReference? target,
  SpaceAbuseCategory category = SpaceAbuseCategory.spam,
  String details = '',
}) {
  final post = SpaceModerationReference(
    kind: SpaceModerationReferenceKind.spacePost,
    author: _id(3),
    seq: 7,
  );
  return SpaceAbuseReport(
    reportId: 'ab' * 32,
    spaceId: _id(1),
    post: post,
    target: target ?? post,
    reporter: _id(2),
    reviewer: _id(4),
    category: category,
    details: details,
    createdAtMs: 100,
    signature: Uint8List(64),
    authorPubKey: _id(2).bytes,
  );
}

void main() {
  test(
    'signed post and comment reports round-trip with canonical references',
    () {
      final post = _report();
      final decodedPost = SpaceAbuseReport.fromJson(post.toJson());
      expect(decodedPost, isNotNull);
      expect(decodedPost!.postId, '${_id(3).hex}:7');
      expect(decodedPost.commentRef, isNull);

      final comment = _report(
        target: SpaceModerationReference(
          kind: SpaceModerationReferenceKind.spacePostComment,
          author: _id(5),
          seq: 9,
        ),
        category: SpaceAbuseCategory.harassment,
        details: 'Targeted abuse',
      );
      final decodedComment = SpaceAbuseReport.fromJson(comment.toJson());
      expect(decodedComment, isNotNull);
      expect(decodedComment!.commentRef, '${_id(5).hex}:9');
      expect(decodedComment.contentKey, comment.contentKey);
      expect(decodedComment.canonicalBytes(), comment.canonicalBytes());
    },
  );

  test(
    'report parser rejects smuggling, self reports and mismatched post refs',
    () {
      final valid = _report();
      final smuggled = {...valid.toJson(), 'displayName': 'local alias'};
      expect(SpaceAbuseReport.fromJson(smuggled), isNull);

      final self = SpaceAbuseReport(
        reportId: valid.reportId,
        spaceId: valid.spaceId,
        post: valid.post,
        target: valid.target,
        reporter: valid.target.author,
        reviewer: valid.reviewer,
        category: valid.category,
        details: valid.details,
        createdAtMs: valid.createdAtMs,
        signature: valid.signature,
        authorPubKey: valid.target.author.bytes,
      );
      expect(self.isStructurallyValid, isFalse);

      final mismatched = _report(
        target: SpaceModerationReference(
          kind: SpaceModerationReferenceKind.spacePost,
          author: _id(5),
          seq: 9,
        ),
      );
      expect(mismatched.isStructurallyValid, isFalse);
    },
  );

  test('other category needs details and byte limits are enforced', () {
    expect(
      _report(category: SpaceAbuseCategory.other).isStructurallyValid,
      isFalse,
    );
    expect(
      _report(
        category: SpaceAbuseCategory.other,
        details: 'Пояснение',
      ).isStructurallyValid,
      isTrue,
    );
    expect(
      _report(
        details: 'я' * (kSpaceAbuseReportDetailsMaxBytes ~/ 2 + 1),
      ).isStructurallyValid,
      isFalse,
    );
  });

  test('content-removed decision binds an independent moderation action', () {
    final decision = SpaceAbuseReportDecision(
      reportId: 'ab' * 32,
      spaceId: _id(1),
      reporter: _id(2),
      reviewer: _id(4),
      outcome: SpaceAbuseReportOutcome.contentRemoved,
      reason: 'Confirmed violation',
      decidedAtMs: 200,
      moderationActionId: '${_id(4).hex}:11',
      signature: Uint8List(64),
      authorPubKey: _id(4).bytes,
    );
    expect(SpaceAbuseReportDecision.fromJson(decision.toJson()), isNotNull);

    final missingAction = SpaceAbuseReportDecision(
      reportId: decision.reportId,
      spaceId: decision.spaceId,
      reporter: decision.reporter,
      reviewer: decision.reviewer,
      outcome: SpaceAbuseReportOutcome.contentRemoved,
      reason: decision.reason,
      decidedAtMs: decision.decidedAtMs,
      signature: decision.signature,
      authorPubKey: decision.authorPubKey,
    );
    expect(missingAction.isStructurallyValid, isFalse);

    final smuggled = {...decision.toJson(), 'contentSnapshot': 'forbidden'};
    expect(SpaceAbuseReportDecision.fromJson(smuggled), isNull);
  });

  test('inbox decision cannot be rebound to another reporter', () {
    final report = _report();
    final decision = SpaceAbuseReportDecision(
      reportId: report.reportId,
      spaceId: report.spaceId,
      reporter: _id(9),
      reviewer: report.reviewer,
      outcome: SpaceAbuseReportOutcome.dismissed,
      reason: 'No violation',
      decidedAtMs: 200,
      signature: Uint8List(64),
      authorPubKey: report.reviewer.bytes,
    );
    expect(
      SpaceAbuseReportInboxEntry(
        report: report,
        receivedAtMs: 150,
        decision: decision,
      ).isStructurallyValid,
      isFalse,
    );
  });
}
