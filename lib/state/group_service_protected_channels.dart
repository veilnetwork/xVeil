part of 'group_service.dart';

/// How one revision of a PROTECTED channel is assembled, signed and written:
/// who the recipients are, what the next epoch looks like, and the repair pass
/// that heals epochs written by older builds.
///
/// A collaborator rather than an extension, for the reason recorded on
/// [_ChannelKeyRotation]: extension members cannot be overridden and dispatch
/// statically. The public channel API and the per-group lock stay on the
/// owner; this file holds the rules a revision must satisfy.
class _ProtectedChannels {
  _ProtectedChannels(this._owner);

  final GroupService _owner;

  List<NodeId>? recipientsFor(
    GroupState state,
    Iterable<NodeId> requested,
  ) {
    final recipients = <String, NodeId>{};
    for (final member in requested) {
      if (!state.isMember(member)) return null;
      recipients[member.hex] = member;
    }
    for (final member in state.members.values) {
      if (member.role.rank >= GroupRole.admin.rank) {
        recipients[member.nodeId.hex] = member.nodeId;
      }
    }
    recipients[_owner._signer.selfId.hex] = _owner._signer.selfId;
    final ordered = recipients.values.toList()
      ..sort((left, right) => left.hex.compareTo(right.hex));
    if (ordered.isEmpty || ordered.length > maxSpaceChannelRecipientCount) {
      return null;
    }
    return ordered;
  }

  Future<_PreparedProtectedChannelRevision?> prepare(
    GroupBundle bundle,
    GroupState state,
    SpaceChannel channel, {
    required Iterable<NodeId> requestedRecipients,
    required bool create,
    GroupState? recipientState,
    int? createdAtMs,
  }) async {
    final epochService = _owner._epochService;
    if (epochService == null ||
        channel.access != SpaceChannelAccess.restricted ||
        channel.kind == SpaceChannelKind.category ||
        channel.categoryId != null ||
        channel.isDefault) {
      return null;
    }
    final recipients = recipientsFor(
      recipientState ?? state,
      requestedRecipients,
    );
    if (recipients == null) return null;
    final previous = state.protectedChannels[channel.channelId.hex];
    if ((create && previous != null) || (!create && previous == null)) {
      return null;
    }
    SpaceRetentionPolicy? currentRetentionPolicy;
    var hasCurrentRetentionPolicy = false;
    SpaceChannelControlCleartext? previousClear;
    if (previous != null && state.protectedRetention.isNotEmpty) {
      previousClear = await _owner._materializeProtectedChannel(
        bundle,
        state,
        previous,
        requireCurrentAcl: false,
      );
      if (previousClear == null) return null;
      final retention = await _owner._materializedRetentionHistory(
        bundle,
        state,
        currentChannels: {channel.channelId.hex: previousClear},
      );
      if (retention.hiddenThroughMs[channel.channelId.hex] ==
          0x7fffffffffffffff) {
        return null;
      }
      for (final revision in retention.revisions) {
        final policy = revision.policy;
        if (policy.channelId != channel.channelId) continue;
        currentRetentionPolicy = policy;
        hasCurrentRetentionPolicy = true;
      }
      final addsRecipient = recipients.any(
        (recipient) => !previousClear!.recipients.contains(recipient),
      );
      if (addsRecipient &&
          hasCurrentRetentionPolicy &&
          state.roleOf(_owner._signer.selfId) != GroupRole.owner) {
        // Only the owner can preserve a manageStorage decision in the new
        // epoch. Never grant an old content key merely to reveal policy.
        return null;
      }
    }
    final link = _owner._nextControlLink(
      bundle.manifest,
      bundle.control,
      _owner._signer.selfId,
    );
    if (link.blocked) return null;
    final channelEpoch = create ? 1 : previous!.channelEpoch + 1;
    final key = _owner._randomEpochKey();
    Uint8List? clear;
    Uint8List? retentionClear;
    var transferredKey = false;
    try {
      final sealed = await epochService.sealEpoch(
        groupId: channel.channelId,
        epoch: channelEpoch,
        epochKey: key,
        recipients: recipients,
      );
      final controlClear = SpaceChannelControlCleartext(
        channel: channel,
        recipients: recipients,
      );
      if (!controlClear.isStructurallyValid) return null;
      clear = controlClear.encode();
      final revisionCreatedAtMs = createdAtMs ?? _owner._now();
      final encrypted = await encryptSpaceChannelControlPayload(
        spaceId: bundle.manifest.groupId,
        channelId: channel.channelId,
        channelEpoch: channelEpoch,
        keyCommitment: sealed.descriptor.keyCommitment,
        author: _owner._signer.selfId,
        policyVersion: state.policyVersion,
        createdAtMs: revisionCreatedAtMs,
        clearText: clear,
        channelKey: key,
      );
      final opaque = SpaceChannelControlEnvelope(
        spaceId: bundle.manifest.groupId,
        channelId: channel.channelId,
        channelEpoch: channelEpoch,
        keyDescriptor: sealed.descriptor,
        encryptedControl: encrypted,
      );
      final signed = _owner._signer.signControl(
        ControlEntry(
          version: 5,
          groupId: bundle.manifest.groupId,
          author: _owner._signer.selfId,
          seq: link.seq,
          prevHash: link.prevHash,
          op: create ? ControlOp.createChannel : ControlOp.updateChannel,
          target: null,
          role: null,
          policyVersion: state.policyVersion,
          createdAtMs: revisionCreatedAtMs,
          signature: Uint8List(0),
          channelControl: opaque,
        ),
      );
      final controls = <ControlEntry>[signed];
      final candidate = <ControlEntry>[...bundle.control, signed];
      if (hasCurrentRetentionPolicy &&
          currentRetentionPolicy != null &&
          state.roleOf(_owner._signer.selfId) == GroupRole.owner) {
        final retentionCreatedAt = revisionCreatedAtMs;
        retentionClear = Uint8List.fromList(
          utf8.encode(jsonEncode(currentRetentionPolicy.toJson())),
        );
        final retentionEncrypted = await encryptSpaceChannelRetentionPayload(
          spaceId: bundle.manifest.groupId,
          channelId: channel.channelId,
          channelEpoch: channelEpoch,
          author: _owner._signer.selfId,
          seq: link.seq + 1,
          prevHash: controlEntryHash(signed),
          policyVersion: state.policyVersion,
          createdAtMs: retentionCreatedAt,
          clearText: retentionClear,
          channelKey: key,
        );
        final retention = _owner._signer.signControl(
          ControlEntry(
            version: 15,
            groupId: bundle.manifest.groupId,
            author: _owner._signer.selfId,
            seq: link.seq + 1,
            prevHash: controlEntryHash(signed),
            op: ControlOp.setRetention,
            target: null,
            role: null,
            channelRetention: SpaceChannelRetentionEnvelope(
              spaceId: bundle.manifest.groupId,
              channelId: channel.channelId,
              channelEpoch: channelEpoch,
              encryptedPolicy: retentionEncrypted,
            ),
            policyVersion: state.policyVersion,
            createdAtMs: retentionCreatedAt,
            signature: Uint8List(0),
          ),
        );
        candidate.add(retention);
        controls.add(retention);
      }
      final folded = foldControlLog(
        owner: bundle.manifest.owner,
        entries: candidate,
        verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
      );
      if (folded.rejected.any(
        (entry) => controls.any(
          (control) =>
              entry.author == control.author && entry.seq == control.seq,
        ),
      )) {
        return null;
      }
      final keyId = _channelKeyId(channel.channelId, channelEpoch);
      final result = _PreparedProtectedChannelRevision(
        bundle: bundle.copyWith(
          control: candidate,
          channelEpochEnvelopes: [
            ...bundle.channelEpochEnvelopes,
            ...sealed.envelopes,
          ],
          localChannelEpochKeys: {
            ...bundle.localChannelEpochKeys,
            keyId: Uint8List.fromList(key),
          },
        ),
        controls: controls,
        transientKey: key,
      );
      transferredKey = true;
      return result;
    } catch (_) {
      return null;
    } finally {
      clear?.fillRange(0, clear.length, 0);
      retentionClear?.fillRange(0, retentionClear.length, 0);
      if (!transferredKey) key.fillRange(0, key.length, 0);
    }
  }

  Future<bool> write(
    GroupBundle bundle,
    GroupState state,
    SpaceChannel channel, {
    required Iterable<NodeId> requestedRecipients,
    required bool create,
  }) async {
    final prepared = await prepare(
      bundle,
      state,
      channel,
      requestedRecipients: requestedRecipients,
      create: create,
    );
    if (prepared == null) return false;
    try {
      await _owner._save(prepared.bundle);
      unawaited(
        _owner.broadcastDelta(bundle.manifest.groupId, control: prepared.controls),
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      prepared.transientKey.fillRange(0, prepared.transientKey.length, 0);
    }
  }

  Future<void> repairEpochs(NodeId spaceId) =>
      _owner._serialized(spaceId, () async {
        var bundle = await _owner.load(spaceId);
        if (bundle == null || !bundle.manifest.isSpace) {
          return;
        }
        var currentBundle = bundle;
        var state = foldControlLog(
          owner: currentBundle.manifest.owner,
          entries: currentBundle.control,
          verify: (entry) => _owner._validControlFor(currentBundle.manifest, entry),
          initialName: currentBundle.manifest.name,
        ).state;
        if (state.roleOf(_owner._signer.selfId) != GroupRole.owner) return;
        final ids = state.protectedChannels.keys.toList();
        for (final id in ids) {
          final envelope = state.protectedChannels[id];
          if (envelope == null) continue;
          final current = await _owner._materializeProtectedChannel(
            currentBundle,
            state,
            envelope,
          );
          if (current != null) continue;
          final stale = await _owner._materializeProtectedChannel(
            currentBundle,
            state,
            envelope,
            requireCurrentAcl: false,
          );
          if (stale == null) continue;
          final recipients = stale.recipients
              .where(state.isMember)
              .toList(growable: false);
          await write(
            currentBundle,
            state,
            stale.channel,
            requestedRecipients: recipients,
            create: false,
          );
          final reloaded = await _owner.load(spaceId);
          if (reloaded == null) return;
          currentBundle = reloaded;
          state = foldControlLog(
            owner: currentBundle.manifest.owner,
            entries: currentBundle.control,
            verify: (entry) => _owner._validControlFor(currentBundle.manifest, entry),
            initialName: currentBundle.manifest.name,
          ).state;
        }
      });
}
