part of 'group_service.dart';

/// Reading a Space's channels, and the two edits that are only a rewrite of a
/// channel row.
///
/// A collaborator rather than an extension, for the same reason as
/// [_ChannelKeyRotation] and [_Reactions]: extension members cannot be
/// overridden and dispatch statically, which breaks both a test subclass and
/// any dynamic call.
///
/// The boundary is the owner's LOCK. Everything here either reads, or edits
/// through [GroupService.updateChannel], which takes the lock itself.
/// `createChannel`, `updateChannel` and `setChannelMembers` hold `_serialized`
/// at their top level and stay with the owner: the lock is the owner's, and
/// splitting a method from the lock that guards it is how a refactor turns
/// into a race.
///
/// `currentVoiceChannelAdmission` also stays with the owner, and deliberately:
/// a test subclass overrides it and calls `super`. An earlier attempt at this
/// slice moved it here by mis-counting lines, and the analyzer caught it as
/// `undefined_super_member` — the same breakage that ruled out extensions.
class _ChannelQueries {
  _ChannelQueries(this._owner);

  final GroupService _owner;

  /// Current signed channels of one Space, ordered for presentation.
  Future<List<SpaceChannel>> channelsOf(
    NodeId spaceId, {
    bool includeArchived = false,
  }) async {
    final bundle = await _owner.load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return const [];
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    if (!SpaceAcl(state).allows(_owner._signer.selfId, SpacePermission.view)) {
      return const [];
    }
    final protected = await _owner._protectedChannelsOf(bundle, state);
    final channels = [
      for (final channel in state.channels.values)
        if (includeArchived || !channel.archived) channel,
      for (final clear in protected.values)
        if (includeArchived || !clear.channel.archived) clear.channel,
    ];
    channels.sort((left, right) {
      final position = left.position.compareTo(right.position);
      if (position != 0) return position;
      return left.channelId.hex.compareTo(right.channelId.hex);
    });
    return channels;
  }

  /// Authoritative current admission for a voice room. Restricted channels
  /// fail closed when their rotated control/key is unavailable locally.
  Future<bool> canEnterVoiceChannel(
    NodeId groupId,
    NodeId? channelId,
    NodeId member,
  ) async =>
      (await _owner.currentVoiceChannelAdmission(
        groupId,
        channelId,
      ))?.recipients.contains(member) ??
      false;

  Future<List<NodeId>?> channelMembersOf(
    NodeId spaceId,
    NodeId channelId,
  ) async {
    final bundle = await _owner.load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    final protected = await _owner._protectedChannelsOf(bundle, state);
    final clear = protected[channelId.hex];
    if (clear != null) return List.unmodifiable(clear.recipients);
    if (state.channels.containsKey(channelId.hex)) {
      return List.unmodifiable(
        state.members.values.map((member) => member.nodeId),
      );
    }
    return null;
  }

  Future<bool> setChannelArchived(
    NodeId spaceId,
    NodeId channelId,
    bool archived,
  ) async {
    final current = (await channelsOf(
      spaceId,
      includeArchived: true,
    )).where((channel) => channel.channelId == channelId).firstOrNull;
    if (current == null || current.archived == archived) return current != null;
    return _owner.updateChannel(spaceId, current.copyWith(archived: archived));
  }

  Future<bool> setDefaultChannel(NodeId spaceId, NodeId channelId) async {
    final current = (await channelsOf(
      spaceId,
      includeArchived: true,
    )).where((channel) => channel.channelId == channelId).firstOrNull;
    if (current == null ||
        current.kind != SpaceChannelKind.text ||
        current.archived) {
      return false;
    }
    if (current.isDefault) return true;
    return _owner.updateChannel(spaceId, current.copyWith(isDefault: true));
  }
}
