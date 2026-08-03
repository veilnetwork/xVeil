part of 'group_service.dart';

/// Rotation of a protected channel's key: on demand, and by age or volume.
///
/// Split out of [GroupService] as a collaborator rather than an extension: an
/// extension cannot be overridden and is dispatched statically, which broke a
/// test subclass and a dynamic call site when tried. The lock and the public
/// methods stay on the owner — this file holds only the work.
class _ChannelKeyRotation {
  _ChannelKeyRotation(this._owner);

  final GroupService _owner;

  Future<bool> rotateLocked(NodeId spaceId, NodeId channelId) async {
    final bundle = await _owner.load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace || _owner._epochService == null) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    if (!SpaceAcl(state).allows(
      _owner._signer.selfId,
      SpacePermission.manageChannels,
      channelId: channelId,
    )) {
      return false;
    }
    final current = (await _owner._protectedChannelsOf(
      bundle,
      state,
    ))[channelId.hex];
    if (current == null) return false;
    // The recipients we pass are the ones we just decrypted, so this is a new
    // epoch and a new key over an unchanged ACL — the write path makes no
    // distinction between that and a membership edit.
    return _owner._channels.write(
      bundle,
      state,
      current.channel,
      requestedRecipients: current.recipients,
      create: false,
    );
  }

  Future<int> rotateStaleLocked(NodeId spaceId) async {
        final bundle = await _owner.load(spaceId);
        if (bundle == null ||
            !bundle.manifest.isSpace ||
            _owner._epochService == null) {
          return 0;
        }
        final state = foldControlLog(
          owner: bundle.manifest.owner,
          entries: bundle.control,
          verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
          initialName: bundle.manifest.name,
        ).state;
        final nowMs = _owner._now();
        // Note the epochs BEFORE the permission check, so that gaining or
        // losing `manageChannels` — which someone else decides — cannot
        // restart a key's clock.
        final seen = <String, int>{...bundle.channelEpochReceipts};
        for (final opaque in state.protectedChannels.values) {
          seen.putIfAbsent(
            _channelKeyId(opaque.channelId, opaque.channelEpoch),
            () => nowMs,
          );
        }
        if (seen.length != bundle.channelEpochReceipts.length) {
          // Persisted before anything is rotated, and never revised
          // afterwards: the whole point is a number that does not move.
          await _owner._save(
            bundle.copyWith(channelEpochReceipts: seen),
            notify: false,
          );
        }
        final acl = SpaceAcl(state);
        final stale = <NodeId>[];
        for (final opaque in state.protectedChannels.values) {
          if (!acl.allows(
            _owner._signer.selfId,
            SpacePermission.manageChannels,
            channelId: opaque.channelId,
          )) {
            continue;
          }
          if (await isStale(
            bundle,
            opaque,
            firstSeenAtMs:
                seen[_channelKeyId(opaque.channelId, opaque.channelEpoch)]!,
            nowMs: nowMs,
          )) {
            stale.add(opaque.channelId);
          }
        }
        var rotated = 0;
        for (final channelId in stale) {
          // Each rotation appends control entries, so the next one must see
          // them: re-read rather than reuse the fold above.
          if (await rotateLocked(spaceId, channelId)) rotated++;
        }
        return rotated;
  }

  /// Whether this channel's current key has served long enough, or carried
  /// enough, to be replaced.
  ///
  /// [firstSeenAtMs] is when THIS device first observed the epoch in service
  /// (see [GroupBundle.channelEpochReceipts]), and the age bound is measured
  /// from it rather than from the `createdAtMs` of the control entry that
  /// introduced the epoch. That stamp is chosen by whoever holds
  /// `manageChannels` — and, since the entry is only looked up by
  /// (channelId, epoch) and never re-authorized, by anyone who can get a
  /// signature-valid entry into the log at all. Dated forward it made
  /// `now - started` negative, so the key never aged and never rotated: the
  /// one defect in this series where the lie makes a protection stop quietly
  /// rather than make something visibly fail. Dated backward it made every key
  /// born stale, so one cheap entry bought a Space-wide ML-KEM rekey, again on
  /// every sweep. A local arrival moment closes both without needing a
  /// tolerance, because there is no honest claim here to tolerate.
  ///
  /// The cost is that a key already in service when this device first sweeps
  /// starts its thirty days over. That is the existing contract of this pass —
  /// "rotating late is a weaker guarantee, not a broken one" — and it is the
  /// only honest answer available: a device with no arrival moment of its own
  /// knows nothing about this key's age that its author could not have made up.
  Future<bool> isStale(
    GroupBundle bundle,
    SpaceChannelControlEnvelope opaque, {
    required int firstSeenAtMs,
    required int nowMs,
  }) async {
    if (nowMs - firstSeenAtMs >= GroupService.protectedChannelKeyMaxAgeMs) {
      return true;
    }
    var carried = 0;
    for (final message in await _owner._messagesOfBundle(
      bundle,
      channelId: opaque.channelId,
      applyLocalRetention: false,
    )) {
      if (message.channelEpoch != opaque.channelEpoch) continue;
      if (++carried >= GroupService.protectedChannelKeyMaxMessages) return true;
    }
    return false;
  }
}
