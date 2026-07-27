part of 'group_service.dart';

/// Reporting content to a Space's moderators, and deciding on those reports.
///
/// A collaborator rather than an extension, for the same reason as
/// [_Reactions] and [_SpaceFeed]. Unlike the earlier slices this one owns its
/// state outright — the storage key, the per-reporter caps, the transit-age
/// bound and the mutation gate are used nowhere else, so they move with the
/// code instead of staying behind on the owner.
///
/// The six public entry points stay on [GroupService]: the UI, the API adapter
/// and the messaging dispatcher all reach them there, and this decomposition
/// does not change the API.
class _AbuseReports {
  _AbuseReports(this._owner);

  final GroupService _owner;

  static const String _spaceAbuseReportsSetting = 'spaces.abuse_reports.v1';
  static const int _maxSpaceAbuseReportRecords = 256;
  static const int _maxPendingSpaceAbuseReportsPerReporter = 16;
  static const int _maxSpaceAbuseReportsPerReporterPerDay = 32;
  static const Duration _spaceAbuseReportMaxTransitAge = Duration(days: 30);
  Future<void> _spaceAbuseReportMutationTail = Future<void>.value();

  Future<T> _serializeSpaceAbuseReports<T>(Future<T> Function() action) async {
    final previous = _spaceAbuseReportMutationTail;
    final gate = Completer<void>();
    _spaceAbuseReportMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<
    ({
      List<SpaceAbuseReportInboxEntry> incoming,
      List<SpaceAbuseReportOutboxEntry> outgoing,
    })
  >
  _loadSpaceAbuseReports() async {
    final blob = await _owner._storage.loadFile(_spaceAbuseReportsSetting);
    if (blob == null || blob.isEmpty) {
      return (
        incoming: <SpaceAbuseReportInboxEntry>[],
        outgoing: <SpaceAbuseReportOutboxEntry>[],
      );
    }
    try {
      final value = jsonDecode(utf8.decode(blob, allowMalformed: false));
      if (value is! Map || value['v'] != 1) throw const FormatException();
      return (
        incoming: (value['incoming'] as List? ?? const [])
            .map(SpaceAbuseReportInboxEntry.fromJson)
            .whereType<SpaceAbuseReportInboxEntry>()
            .take(_maxSpaceAbuseReportRecords)
            .toList(),
        outgoing: (value['outgoing'] as List? ?? const [])
            .map(SpaceAbuseReportOutboxEntry.fromJson)
            .whereType<SpaceAbuseReportOutboxEntry>()
            .take(_maxSpaceAbuseReportRecords)
            .toList(),
      );
    } catch (_) {
      return (
        incoming: <SpaceAbuseReportInboxEntry>[],
        outgoing: <SpaceAbuseReportOutboxEntry>[],
      );
    }
  }

  Future<void> _saveSpaceAbuseReports({
    required List<SpaceAbuseReportInboxEntry> incoming,
    required List<SpaceAbuseReportOutboxEntry> outgoing,
  }) {
    final raw = jsonEncode({
      'v': 1,
      'incoming': [
        for (final entry in incoming.take(_maxSpaceAbuseReportRecords))
          entry.toJson(),
      ],
      'outgoing': [
        for (final entry in outgoing.take(_maxSpaceAbuseReportRecords))
          entry.toJson(),
      ],
    });
    return _owner._storage.storeFile(
      _spaceAbuseReportsSetting,
      Uint8List.fromList(utf8.encode(raw)),
      name: 'space-abuse-reports',
    );
  }

  SpaceAbuseReport? _signSpaceAbuseReport(SpaceAbuseReport unsigned) {
    try {
      final signed = _owner._signer.signDetached(unsigned.canonicalBytes());
      final report = unsigned.withSignature(signed.signature, signed.publicKey);
      return _verifySpaceAbuseReport(report) ? report : null;
    } catch (_) {
      return null;
    }
  }

  bool _verifySpaceAbuseReport(SpaceAbuseReport report) =>
      report.isStructurallyValid &&
      report.signature.length == 64 &&
      report.authorPubKey.length == 32 &&
      _owner._signer.verifyDetached(
        signer: report.reporter,
        publicKey: report.authorPubKey,
        message: report.canonicalBytes(),
        signature: report.signature,
      );

  SpaceAbuseReportDecision? _signSpaceAbuseReportDecision(
    SpaceAbuseReportDecision unsigned,
  ) {
    try {
      final signed = _owner._signer.signDetached(unsigned.canonicalBytes());
      final decision = unsigned.withSignature(
        signed.signature,
        signed.publicKey,
      );
      return _verifySpaceAbuseReportDecision(decision) ? decision : null;
    } catch (_) {
      return null;
    }
  }

  bool _verifySpaceAbuseReportDecision(SpaceAbuseReportDecision decision) =>
      decision.isStructurallyValid &&
      decision.signature.length == 64 &&
      decision.authorPubKey.length == 32 &&
      _owner._signer.verifyDetached(
        signer: decision.reviewer,
        publicKey: decision.authorPubKey,
        message: decision.canonicalBytes(),
        signature: decision.signature,
      );

  Future<
    ({
      NodeId reviewer,
      SpaceModerationReference post,
      SpaceModerationReference target,
    })?
  >
  _resolveReportableSpaceContent(
    NodeId spaceId,
    String postId,
    String? commentRef,
  ) async {
    final bundle = await _owner.load(spaceId);
    if (bundle != null && bundle.manifest.isSpace) {
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
        initialDescription: bundle.manifest.description ?? '',
      ).state;
      final reviewer = _owner._effectiveSpaceOwner(state);
      final posts = await _owner._postsOfBundle(
        bundle,
        applyLocalRetention: true,
      );
      final post = posts.where((value) => value.postId == postId).firstOrNull;
      if (reviewer != null && post != null) {
        final postReference = SpaceModerationReference(
          kind: SpaceModerationReferenceKind.spacePost,
          author: post.author,
          seq: post.seq,
        );
        if (commentRef == null) {
          return (
            reviewer: reviewer,
            post: postReference,
            target: postReference,
          );
        }
        final comments = await _owner.spacePostCommentsOf(spaceId, postId);
        final comment = comments
            .where((value) => value.ref == commentRef)
            .firstOrNull;
        if (comment != null) {
          return (
            reviewer: reviewer,
            post: postReference,
            target: SpaceModerationReference(
              kind: SpaceModerationReferenceKind.spacePostComment,
              author: comment.author,
              seq: comment.root.seq,
            ),
          );
        }
      }
    }

    final public = await _owner.publicSpaceSubscription(spaceId);
    if (public == null) return null;
    final post = public.feed.posts
        .where((value) => value.postId == postId)
        .firstOrNull;
    if (post == null) return null;
    final postReference = SpaceModerationReference(
      kind: SpaceModerationReferenceKind.spacePost,
      author: post.author,
      seq: post.seq,
    );
    if (commentRef == null) {
      return (
        reviewer: public.descriptor.publisher,
        post: postReference,
        target: postReference,
      );
    }
    final comments = await _owner.publicSpacePostComments(spaceId, postId);
    final comment = comments
        .where((value) => value.ref == commentRef)
        .firstOrNull;
    if (comment == null) return null;
    return (
      reviewer: public.descriptor.publisher,
      post: postReference,
      target: SpaceModerationReference(
        kind: SpaceModerationReferenceKind.spacePostComment,
        author: comment.author,
        seq: comment.root.seq,
      ),
    );
  }

  Future<bool> _spaceAbuseReportContentExists(
    GroupBundle bundle,
    SpaceAbuseReport report,
  ) async {
    final post = (await _owner._postsOfBundle(
      bundle,
      applyLocalRetention: false,
    )).where((value) => value.postId == report.postId).firstOrNull;
    if (post == null ||
        post.author != report.post.author ||
        post.seq != report.post.seq) {
      return false;
    }
    if (report.target.kind == SpaceModerationReferenceKind.spacePost) {
      return report.target.author == post.author &&
          report.target.seq == post.seq;
    }
    final memberComments = await _owner._messagesOfBundle(
      bundle,
      spacePostId: report.postId,
      includeSpacePostComments: true,
      applyLocalRetention: false,
    );
    if (memberComments.any(
      (message) =>
          message.editOf == null &&
          message.deleteOf == null &&
          message.ref == report.target.contentId,
    )) {
      return true;
    }
    return foldSpacePublicComments(
      comments: bundle.publicComments,
      spaceId: report.spaceId,
      postId: report.postId,
      verifySignature: _owner._signer.verifyDetached,
    ).any((comment) => comment.ref == report.target.contentId);
  }

  List<T>? _prependBoundedSpaceAbuseEntry<T>(
    T value,
    List<T> current,
    bool Function(T value) pending,
  ) {
    final result = <T>[value, ...current];
    while (result.length > _maxSpaceAbuseReportRecords) {
      final decided = result.lastIndexWhere((entry) => !pending(entry));
      if (decided < 0) return null;
      result.removeAt(decided);
    }
    return result;
  }

  Future<List<SpaceAbuseReportInboxEntry>> incomingSpaceAbuseReports({
    NodeId? spaceId,
    bool pendingOnly = false,
  }) async {
    final result =
        (await _loadSpaceAbuseReports()).incoming
            .where(
              (entry) =>
                  (spaceId == null || entry.report.spaceId == spaceId) &&
                  (!pendingOnly || entry.pending),
            )
            .toList()
          ..sort(
            (left, right) => right.receivedAtMs.compareTo(left.receivedAtMs),
          );
    return result;
  }

  Future<List<SpaceAbuseReportOutboxEntry>> outgoingSpaceAbuseReports() async {
    final result = (await _loadSpaceAbuseReports()).outgoing.toList()
      ..sort(
        (left, right) =>
            right.report.createdAtMs.compareTo(left.report.createdAtMs),
      );
    return result;
  }

  /// Persist before enqueueing a private external report. Repeating the same
  /// visible content/reviewer tuple retransmits the exact signed row instead
  /// of producing a second complaint. Ownership transfer permits one
  /// replacement addressed to the new current owner.
  Future<bool> reportSpaceContent(
    NodeId spaceId,
    String postId, {
    String? commentRef,
    required SpaceAbuseCategory category,
    String details = '',
  }) async {
    final sender = _owner.sendSpaceAbuseReport;
    if (sender == null) return false;
    final resolved = await _resolveReportableSpaceContent(
      spaceId,
      postId,
      commentRef,
    );
    if (resolved == null ||
        resolved.reviewer == _owner.selfId ||
        resolved.target.author == _owner.selfId) {
      return false;
    }
    final normalized = details.trim();
    final report = await _serializeSpaceAbuseReports(() async {
      final store = await _loadSpaceAbuseReports();
      final contentKey =
          '${spaceId.hex}|${resolved.post.contentId}|'
          '${resolved.target.kind.name}|${resolved.target.contentId}';
      for (final entry in store.outgoing) {
        if (entry.report.contentKey == contentKey &&
            (entry.decision != null ||
                entry.report.reviewer == resolved.reviewer)) {
          return entry.decision == null ? entry.report : null;
        }
      }
      final now = _owner._now();
      final unsigned = SpaceAbuseReport(
        reportId: _owner._newSpaceInviteId(),
        spaceId: spaceId,
        post: resolved.post,
        target: resolved.target,
        reporter: _owner.selfId,
        reviewer: resolved.reviewer,
        category: category,
        details: normalized,
        createdAtMs: now,
        signature: Uint8List(0),
        authorPubKey: Uint8List(0),
      );
      if (!unsigned.isStructurallyValid) return null;
      final signed = _signSpaceAbuseReport(unsigned);
      if (signed == null) return null;
      final outgoing = _prependBoundedSpaceAbuseEntry(
        SpaceAbuseReportOutboxEntry(report: signed),
        store.outgoing,
        (entry) => entry.pending,
      );
      if (outgoing == null) return null;
      await _saveSpaceAbuseReports(
        incoming: store.incoming,
        outgoing: outgoing,
      );
      _owner.changes.value++;
      return signed;
    });
    if (report == null) return false;
    try {
      await sender(
        report.reviewer,
        report.reportId,
        jsonEncode(report.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The durable transport ACK is withheld until source binding, signature,
  /// current-owner routing, exact content and bounded per-reporter quotas all
  /// pass and the immutable inbox row is persisted.
  Future<bool> receiveSpaceAbuseReport(NodeId peer, String reportJson) async {
    if (utf8.encode(reportJson).length > kSpaceAbuseReportWireMaxBytes) {
      return false;
    }
    final SpaceAbuseReport? report;
    try {
      report = SpaceAbuseReport.fromJson(jsonDecode(reportJson));
    } catch (_) {
      return false;
    }
    final now = _owner._now();
    if (report == null ||
        report.reporter != peer ||
        report.reviewer != _owner.selfId ||
        report.createdAtMs > now + const Duration(minutes: 5).inMilliseconds ||
        report.createdAtMs <
            now - _spaceAbuseReportMaxTransitAge.inMilliseconds ||
        !_verifySpaceAbuseReport(report) ||
        (await _owner._storage.getContact(peer))?.status ==
            ContactStatus.blocked) {
      return false;
    }
    final accepted = report;
    final bundle = await _owner.load(accepted.spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (_owner._effectiveSpaceOwner(state) != _owner.selfId) return false;

    return _serializeSpaceAbuseReports(() async {
      final store = await _loadSpaceAbuseReports();
      for (final old in store.incoming) {
        if (old.report.reportId == accepted.reportId) {
          return jsonEncode(old.report.toJson()) ==
              jsonEncode(accepted.toJson());
        }
        if (old.report.reporter == peer &&
            old.report.contentKey == accepted.contentKey) {
          return false;
        }
      }
      final pendingFromReporter = store.incoming
          .where((entry) => entry.pending && entry.report.reporter == peer)
          .length;
      final recentCutoff = now - const Duration(days: 1).inMilliseconds;
      final recentFromReporter = store.incoming
          .where(
            (entry) =>
                entry.report.reporter == peer &&
                entry.receivedAtMs >= recentCutoff,
          )
          .length;
      if (pendingFromReporter >= _maxPendingSpaceAbuseReportsPerReporter ||
          recentFromReporter >= _maxSpaceAbuseReportsPerReporterPerDay ||
          !await _spaceAbuseReportContentExists(bundle, accepted)) {
        return false;
      }
      final entry = SpaceAbuseReportInboxEntry(
        report: accepted,
        receivedAtMs: now < accepted.createdAtMs ? accepted.createdAtMs : now,
      );
      final incoming = _prependBoundedSpaceAbuseEntry(
        entry,
        store.incoming,
        (value) => value.pending,
      );
      if (incoming == null) return false;
      await _saveSpaceAbuseReports(
        incoming: incoming,
        outgoing: store.outgoing,
      );
      _owner.changes.value++;
      return true;
    });
  }

  Future<bool> decideSpaceAbuseReport(
    String reportId, {
    required SpaceAbuseReportOutcome outcome,
    required String reason,
  }) async {
    final sender = _owner.sendSpaceAbuseReportDecision;
    if (sender == null) return false;
    final normalized = reason.trim();
    final prepared =
        await _serializeSpaceAbuseReports<
          ({SpaceAbuseReport report, SpaceAbuseReportDecision decision})?
        >(() async {
          final store = await _loadSpaceAbuseReports();
          final pending = store.incoming
              .where(
                (entry) => entry.report.reportId == reportId && entry.pending,
              )
              .firstOrNull;
          if (pending == null) return null;
          final bundle = await _owner.load(pending.report.spaceId);
          if (bundle == null || !bundle.manifest.isSpace) return null;
          final state = foldControlLog(
            owner: bundle.manifest.owner,
            entries: bundle.control,
            verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
            initialName: bundle.manifest.name,
            initialDescription: bundle.manifest.description ?? '',
          ).state;
          if (_owner._effectiveSpaceOwner(state) != _owner.selfId) return null;

          String? moderationActionId;
          if (outcome == SpaceAbuseReportOutcome.contentRemoved) {
            final target = pending.report.target;
            moderationActionId = await _owner.moderateSpace(
              pending.report.spaceId,
              kind: target.kind == SpaceModerationReferenceKind.spacePostComment
                  ? SpaceModerationKind.deleteMessage
                  : SpaceModerationKind.deletePost,
              target: target.author,
              scope: SpaceModerationScope.posts,
              reason: normalized,
              reference: target,
            );
            if (moderationActionId == null) return null;
          }
          final now = _owner._now();
          final unsigned = SpaceAbuseReportDecision(
            reportId: pending.report.reportId,
            spaceId: pending.report.spaceId,
            reporter: pending.report.reporter,
            reviewer: _owner.selfId,
            outcome: outcome,
            reason: normalized,
            decidedAtMs: now < pending.receivedAtMs
                ? pending.receivedAtMs
                : now,
            moderationActionId: moderationActionId,
            signature: Uint8List(0),
            authorPubKey: Uint8List(0),
          );
          if (!unsigned.isStructurallyValid) return null;
          final decision = _signSpaceAbuseReportDecision(unsigned);
          if (decision == null) return null;
          await _saveSpaceAbuseReports(
            incoming: [
              for (final entry in store.incoming)
                if (entry.report.reportId == reportId)
                  SpaceAbuseReportInboxEntry(
                    report: entry.report,
                    receivedAtMs: entry.receivedAtMs,
                    decision: decision,
                  )
                else
                  entry,
            ],
            outgoing: store.outgoing,
          );
          _owner.changes.value++;
          return (report: pending.report, decision: decision);
        });
    if (prepared == null) return false;
    try {
      await sender(
        prepared.report.reporter,
        prepared.report.reportId,
        jsonEncode(prepared.decision.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> receiveSpaceAbuseReportDecision(
    NodeId peer,
    String decisionJson,
  ) async {
    if (utf8.encode(decisionJson).length > kSpaceAbuseReportWireMaxBytes) {
      return false;
    }
    final SpaceAbuseReportDecision? decision;
    try {
      decision = SpaceAbuseReportDecision.fromJson(jsonDecode(decisionJson));
    } catch (_) {
      return false;
    }
    final now = _owner._now();
    if (decision == null ||
        decision.reviewer != peer ||
        decision.reporter != _owner.selfId ||
        decision.decidedAtMs >
            now + const Duration(minutes: 5).inMilliseconds ||
        !_verifySpaceAbuseReportDecision(decision) ||
        (await _owner._storage.getContact(peer))?.status ==
            ContactStatus.blocked) {
      return false;
    }
    final accepted = decision;
    return _serializeSpaceAbuseReports(() async {
      final store = await _loadSpaceAbuseReports();
      final matched = store.outgoing
          .where(
            (entry) =>
                entry.report.reportId == accepted.reportId &&
                entry.report.spaceId == accepted.spaceId &&
                entry.report.reviewer == peer,
          )
          .firstOrNull;
      if (matched == null ||
          accepted.decidedAtMs < matched.report.createdAtMs) {
        return false;
      }
      if (matched.decision != null) {
        return jsonEncode(matched.decision!.toJson()) ==
            jsonEncode(accepted.toJson());
      }
      await _saveSpaceAbuseReports(
        incoming: store.incoming,
        outgoing: [
          for (final entry in store.outgoing)
            if (entry.report.reportId == accepted.reportId)
              SpaceAbuseReportOutboxEntry(
                report: entry.report,
                decision: accepted,
              )
            else
              entry,
        ],
      );
      _owner.changes.value++;
      return true;
    });
  }
}
