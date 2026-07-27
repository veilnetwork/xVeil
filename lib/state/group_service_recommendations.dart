part of 'group_service.dart';

/// Recommending a Space to a contact: minting the signed campaign card, the
/// rules for who may carry it, the per-sender rate limits, and the audit of
/// what was sent to whom.
///
/// A collaborator rather than an extension, for the same reason as
/// [_Reactions] and [_AbuseReports]. Like the abuse slice it owns its state —
/// the audit key, the hourly/daily limits, the duplicate window and the
/// mutation gate are used nowhere else, so they move with the code.
///
/// The public entry points stay on [GroupService]; this decomposition does not
/// change the API.
class _Recommendations {
  _Recommendations(this._owner);

  final GroupService _owner;

  /// Create a signed, public recommendation campaign. The capability is
  /// issued by an admin, while any current member with distribute permission
  /// may later carry the resulting card to explicitly selected contacts.
  Future<SpaceRecommendationCampaign?> createSpaceRecommendationCampaign(
    NodeId spaceId,
    String text,
  ) async {
    final normalized = text.trim();
    if (normalized.isEmpty || normalized.length > 1000) return null;
    return _owner._serialized(spaceId, () async {
      final bundle = await _owner.load(spaceId);
      if (bundle == null ||
          !bundle.manifest.isSpace ||
          bundle.manifest.visibility != SpaceVisibility.public) {
        return null;
      }
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
        initialDescription: bundle.manifest.description ?? '',
      ).state;
      if (!state.isActive ||
          !state.recommendationsEnabled ||
          !SpaceAcl(
            state,
          ).allows(_owner.selfId, SpacePermission.manageRecommendations)) {
        return null;
      }
      final joinCode = await _owner.createSpaceJoinCode(spaceId);
      if (joinCode == null) return null;
      try {
        final ticket = SpaceJoinCode.parse(joinCode);
        if (ticket.isExpiredAt(_owner._now())) return null;
      } catch (_) {
        return null;
      }
      final now = _owner._now();
      final campaign = SpaceRecommendationCampaign(
        campaignId: _owner._newSpaceInviteId(),
        spaceId: spaceId,
        createdBy: _owner.selfId,
        text: normalized,
        joinCode: joinCode,
        createdAtMs: now,
        changedAtMs: now,
        active: true,
      );
      final applied = await _owner._addControlOp(
        spaceId,
        ControlOp.setRecommendationCampaign,
        recommendationCampaign: campaign,
        createdAtMs: now,
      );
      return applied ? campaign : null;
    });
  }

  /// Publish one complete signed Space-wide recommendation posture.
  ///
  /// The optimistic revision prevents two administrative devices from
  /// silently overwriting each other. Fixed sender rate limits deliberately
  /// remain outside this policy and cannot be weakened by a Space admin.
  Future<SpaceRecommendationPolicy?> setSpaceRecommendationPolicy(
    NodeId spaceId, {
    required int expectedRevision,
    required bool enabled,
  }) => _owner._serialized(spaceId, () async {
    final bundle = await _owner.load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    final current = state.recommendationPolicy;
    if (!state.isActive ||
        (current?.revision ?? 0) != expectedRevision ||
        !SpaceAcl(
          state,
        ).allows(_owner.selfId, SpacePermission.manageRecommendations)) {
      return null;
    }
    final policy = SpaceRecommendationPolicy(
      spaceId: spaceId,
      revision: expectedRevision + 1,
      previousPolicyHash: current?.policyHash ?? '',
      changedBy: _owner.selfId,
      changedAtMs: _owner._now(),
      enabled: enabled,
    );
    final applied = await _owner._addControlOp(
      spaceId,
      ControlOp.setRecommendationPolicy,
      recommendationPolicy: policy,
      createdAtMs: policy.changedAtMs,
    );
    return applied ? policy : null;
  });

  Future<List<SpaceRecommendationCampaign>> spaceRecommendationCampaigns(
    NodeId spaceId, {
    bool includeRevoked = false,
  }) async {
    final bundle = await _owner.load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return const [];
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!SpaceAcl(state).allows(_owner.selfId, SpacePermission.view)) {
      return const [];
    }
    final now = _owner._now();
    final campaigns = state.recommendationCampaigns.values.where((campaign) {
      if (includeRevoked) return true;
      if (!campaign.active) return false;
      try {
        return !SpaceJoinCode.parse(campaign.joinCode).isExpiredAt(now);
      } catch (_) {
        return false;
      }
    }).toList();
    campaigns.sort((a, b) => b.changedAtMs.compareTo(a.changedAtMs));
    return List.unmodifiable(campaigns);
  }

  Future<bool> revokeSpaceRecommendationCampaign(
    NodeId spaceId,
    String campaignId,
  ) => _owner._serialized(spaceId, () async {
    final bundle = await _owner.load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!SpaceAcl(
          state,
        ).allows(_owner.selfId, SpacePermission.manageRecommendations) ||
        !state.isActive) {
      return false;
    }
    final current = state.recommendationCampaignFor(campaignId);
    if (current == null || !current.active) return false;
    final now = _owner._now();
    return _owner._addControlOp(
      spaceId,
      ControlOp.setRecommendationCampaign,
      recommendationCampaign: SpaceRecommendationCampaign(
        campaignId: current.campaignId,
        spaceId: current.spaceId,
        createdBy: current.createdBy,
        text: current.text,
        joinCode: '',
        createdAtMs: current.createdAtMs,
        changedAtMs: now,
        active: false,
      ),
      createdAtMs: now,
    );
  });

  static const String _spaceRecommendationAuditSetting =
      'spaces.recommendations.audit.v1';
  static const int _maxSpaceRecommendationAudit = 512;
  static const int _spaceRecommendationCampaignHourlyLimit = 5;
  static const int _spaceRecommendationDailyLimit = 20;
  static const Duration _spaceRecommendationDuplicateWindow = Duration(days: 7);
  Future<void> _spaceRecommendationMutationTail = Future<void>.value();

  Future<T> _serializeSpaceRecommendations<T>(
    Future<T> Function() action,
  ) async {
    final previous = _spaceRecommendationMutationTail;
    final gate = Completer<void>();
    _spaceRecommendationMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<List<SpaceRecommendationShareAudit>> spaceRecommendationShareAudit({
    NodeId? spaceId,
  }) async {
    final raw = await _owner._storage.getSetting(
      _spaceRecommendationAuditSetting,
    );
    if (raw == null || raw.isEmpty) return const [];
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          (value['v'] != 1 && value['v'] != 2) ||
          value['records'] is! List) {
        return const [];
      }
      return List.unmodifiable(
        (value['records'] as List)
            .map(SpaceRecommendationShareAudit.fromJson)
            .whereType<SpaceRecommendationShareAudit>()
            .where((record) => spaceId == null || record.spaceId == spaceId)
            .take(_maxSpaceRecommendationAudit),
      );
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveSpaceRecommendationShareAudit(
    List<SpaceRecommendationShareAudit> records,
  ) => _owner._storage.putSetting(
    _spaceRecommendationAuditSetting,
    jsonEncode({
      'v': 2,
      'records': [
        for (final record in records.take(_maxSpaceRecommendationAudit))
          record.toJson(),
      ],
    }),
  );

  /// Explicitly share one current public campaign with one accepted contact.
  /// Membership/role is never included in the card, so a member's hidden role
  /// cannot leak through recommendation metadata.
  Future<SpaceRecommendationShareResult> shareSpaceRecommendation(
    NodeId spaceId,
    String campaignId,
    NodeId recipient,
  ) async {
    final result = await _serializeSpaceRecommendations(() async {
      final sender = _owner.sendSpaceRecommendation;
      if (sender == null || recipient == _owner.selfId) {
        return SpaceRecommendationShareResult.invalidRecipient;
      }
      final contact = await _owner._storage.getContact(recipient);
      if (contact == null || contact.status != ContactStatus.accepted) {
        return SpaceRecommendationShareResult.invalidRecipient;
      }
      final bundle = await _owner.load(spaceId);
      if (bundle == null ||
          !bundle.manifest.isSpace ||
          bundle.manifest.visibility != SpaceVisibility.public) {
        return SpaceRecommendationShareResult.invalidCampaign;
      }
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
        initialDescription: bundle.manifest.description ?? '',
      ).state;
      if (!state.isActive ||
          !state.recommendationsEnabled ||
          !SpaceAcl(
            state,
          ).allows(_owner.selfId, SpacePermission.distributeContent)) {
        return SpaceRecommendationShareResult.notAllowed;
      }
      if (state.isMember(recipient)) {
        return SpaceRecommendationShareResult.alreadyMember;
      }
      final campaign = state.recommendationCampaignFor(campaignId);
      if (campaign == null || !campaign.active) {
        return SpaceRecommendationShareResult.invalidCampaign;
      }
      final now = _owner._now();
      try {
        final ticket = SpaceJoinCode.parse(campaign.joinCode);
        if (ticket.spaceId != spaceId || ticket.isExpiredAt(now)) {
          return SpaceRecommendationShareResult.invalidCampaign;
        }
      } catch (_) {
        return SpaceRecommendationShareResult.invalidCampaign;
      }
      final records = await spaceRecommendationShareAudit();
      final duplicateCutoff =
          now - _spaceRecommendationDuplicateWindow.inMilliseconds;
      if (records.any(
        (record) =>
            record.campaignId == campaignId &&
            record.recipient == recipient &&
            record.sentAtMs >= duplicateCutoff,
      )) {
        return SpaceRecommendationShareResult.duplicate;
      }
      final hourlyCutoff = now - const Duration(hours: 1).inMilliseconds;
      final dailyCutoff = now - const Duration(days: 1).inMilliseconds;
      if (records.where((record) => record.sentAtMs >= dailyCutoff).length >=
              _spaceRecommendationDailyLimit ||
          records
                  .where(
                    (record) =>
                        record.campaignId == campaignId &&
                        record.sentAtMs >= hourlyCutoff,
                  )
                  .length >=
              _spaceRecommendationCampaignHourlyLimit) {
        return SpaceRecommendationShareResult.rateLimited;
      }
      final card = SpaceRecommendationCard(
        campaignId: campaignId,
        spaceId: spaceId,
        name: state.name,
        description: state.description,
        text: campaign.text,
        joinCode: campaign.joinCode,
      );
      final String? messageId;
      try {
        messageId = await sender(recipient, card);
        if (messageId == null || messageId.isEmpty || messageId.length > 256) {
          return SpaceRecommendationShareResult.failed;
        }
      } catch (_) {
        return SpaceRecommendationShareResult.failed;
      }
      final updated = <SpaceRecommendationShareAudit>[
        SpaceRecommendationShareAudit(
          campaignId: campaignId,
          spaceId: spaceId,
          recipient: recipient,
          sentAtMs: now,
          messageId: messageId,
        ),
        for (final record in records)
          if (record.sentAtMs >= duplicateCutoff) record,
      ];
      await _saveSpaceRecommendationShareAudit(updated);
      _owner.changes.value++;
      return SpaceRecommendationShareResult.sent;
    });
    final reason = switch (result) {
      SpaceRecommendationShareResult.invalidRecipient =>
        SpaceObservationReason.invalidInput,
      SpaceRecommendationShareResult.invalidCampaign =>
        SpaceObservationReason.invalidState,
      SpaceRecommendationShareResult.notAllowed =>
        SpaceObservationReason.permissionDenied,
      SpaceRecommendationShareResult.alreadyMember =>
        SpaceObservationReason.alreadyMember,
      SpaceRecommendationShareResult.duplicate =>
        SpaceObservationReason.duplicate,
      SpaceRecommendationShareResult.rateLimited =>
        SpaceObservationReason.rateLimited,
      SpaceRecommendationShareResult.failed =>
        SpaceObservationReason.transportFailed,
      SpaceRecommendationShareResult.sent => null,
    };
    final outcome = switch (result) {
      SpaceRecommendationShareResult.sent => SpaceObservationOutcome.succeeded,
      SpaceRecommendationShareResult.failed => SpaceObservationOutcome.failed,
      _ => SpaceObservationOutcome.rejected,
    };
    _owner._observeSpace(
      SpaceObservationType.recommendationShared,
      outcome,
      reason: reason,
    );
    if (result == SpaceRecommendationShareResult.notAllowed) {
      _owner._observeSpace(
        SpaceObservationType.aclDenied,
        SpaceObservationOutcome.rejected,
        reason: SpaceObservationReason.permissionDenied,
      );
    }
    return result;
  }

  /// Revoke one already-sent recommendation by its durable message id.
  ///
  /// Revocation is intentionally independent of current Space membership or
  /// campaign state: the sender still owns the 1:1 message and must be able to
  /// retract it after leaving, archiving or deleting the Space. Legacy v1
  /// audit rows have no message id and therefore remain visible but unavailable
  /// for addressable revocation.
  Future<SpaceRecommendationRevokeResult> revokeSentSpaceRecommendation(
    String auditId,
  ) async {
    final result = await _serializeSpaceRecommendations(() async {
      final records = await spaceRecommendationShareAudit();
      final index = records.indexWhere((record) => record.stableId == auditId);
      if (index < 0) return SpaceRecommendationRevokeResult.notFound;
      final record = records[index];
      if (record.revokedAtMs != null) {
        return SpaceRecommendationRevokeResult.alreadyRevoked;
      }
      final revoker = _owner.revokeSpaceRecommendation;
      if (record.messageId == null || revoker == null) {
        return SpaceRecommendationRevokeResult.unavailable;
      }
      try {
        if (!await revoker(record.recipient, record.messageId!)) {
          return SpaceRecommendationRevokeResult.failed;
        }
      } catch (_) {
        return SpaceRecommendationRevokeResult.failed;
      }
      final updated = List<SpaceRecommendationShareAudit>.of(records);
      updated[index] = record.revokedAt(_owner._now());
      await _saveSpaceRecommendationShareAudit(updated);
      _owner.changes.value++;
      return SpaceRecommendationRevokeResult.revoked;
    });
    final reason = switch (result) {
      SpaceRecommendationRevokeResult.notFound =>
        SpaceObservationReason.notFound,
      SpaceRecommendationRevokeResult.alreadyRevoked =>
        SpaceObservationReason.conflict,
      SpaceRecommendationRevokeResult.unavailable =>
        SpaceObservationReason.unavailable,
      SpaceRecommendationRevokeResult.failed =>
        SpaceObservationReason.transportFailed,
      SpaceRecommendationRevokeResult.revoked => null,
    };
    _owner._observeSpace(
      SpaceObservationType.recommendationRevoked,
      result == SpaceRecommendationRevokeResult.revoked
          ? SpaceObservationOutcome.succeeded
          : result == SpaceRecommendationRevokeResult.failed
          ? SpaceObservationOutcome.failed
          : SpaceObservationOutcome.rejected,
      reason: reason,
    );
    return result;
  }

  /// Receiver-side card suppression. A current or restricted membership cannot
  /// start another proposal; a retained signed `left` state may deliberately
  /// rejoin. The recommendation card never becomes authority by itself.
  Future<bool> acceptsSpaceRecommendationCard(
    NodeId sender,
    SpaceRecommendationCard card,
  ) async {
    if (sender == _owner.selfId) return false;
    final contact = await _owner._storage.getContact(sender);
    if (contact == null || contact.status != ContactStatus.accepted) {
      return false;
    }
    try {
      final ticket = SpaceJoinCode.parse(card.joinCode);
      if (ticket.spaceId != card.spaceId || ticket.isExpiredAt(_owner._now())) {
        return false;
      }
    } catch (_) {
      return false;
    }
    return _owner._canStartSpaceMembershipProposal(card.spaceId, _owner._now());
  }
}
