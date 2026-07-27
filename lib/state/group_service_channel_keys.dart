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
    return _owner._writeProtectedChannel(
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
          if (await isStale(bundle, opaque)) {
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

  Future<bool> isStale(
    GroupBundle bundle,
    SpaceChannelControlEnvelope opaque,
  ) async {
    final startedAtMs = epochStartedAtMs(bundle, opaque);
    if (startedAtMs != null &&
        _owner._now() - startedAtMs >= GroupService.protectedChannelKeyMaxAgeMs) {
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

  /// When the channel's current epoch was introduced, per the signed control
  /// entry that carried it. Null when that entry is no longer in the log —
  /// after a checkpoint compaction, say — in which case age says nothing and
  /// only the volume bound applies.
  int? epochStartedAtMs(
    GroupBundle bundle,
    SpaceChannelControlEnvelope opaque,
  ) {
    for (final entry in bundle.control.reversed) {
      final control = entry.channelControl;
      if (control == null ||
          control.channelId != opaque.channelId ||
          control.channelEpoch != opaque.channelEpoch) {
        continue;
      }
      return entry.createdAtMs;
    }
    return null;
  }
}
