part of 'group_service.dart';

/// Inviting someone to a Space: minting the invite, the invitee's pending
/// queue, and the accept/decline round trip in both directions.
///
/// A collaborator rather than an extension, for the same reason as
/// [_Reactions] and [_AbuseReports]. The invite storage key, the record cap and
/// the mutation gate move with the code; `_newSpaceInviteId` deliberately does
/// NOT — three other collaborators and the owner mint ids with it, so it stays
/// shared on [GroupService] despite the name.
///
/// The five public entry points stay on the owner; this decomposition does not
/// change the API.
class _SpaceInvites {
  _SpaceInvites(this._owner);

  final GroupService _owner;

  static const String _spaceInvitesSetting = 'spaces.invites.v1';
  static const int _maxSpaceInvites = 256;
  Future<void> _spaceInviteMutationTail = Future<void>.value();

  Future<T> _serializeSpaceInvites<T>(Future<T> Function() action) async {
    final previous = _spaceInviteMutationTail;
    final gate = Completer<void>();
    _spaceInviteMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<({List<PendingSpaceInvite> incoming, List<SpaceInvite> outgoing})>
  _loadSpaceInvites() async {
    final raw = await _owner._storage.getSetting(_spaceInvitesSetting);
    if (raw == null || raw.isEmpty) {
      return (incoming: <PendingSpaceInvite>[], outgoing: <SpaceInvite>[]);
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['v'] != 1) {
        return (incoming: <PendingSpaceInvite>[], outgoing: <SpaceInvite>[]);
      }
      final incoming = (value['incoming'] as List? ?? const [])
          .map(PendingSpaceInvite.fromJson)
          .whereType<PendingSpaceInvite>()
          .take(_maxSpaceInvites)
          .toList();
      final outgoing = (value['outgoing'] as List? ?? const [])
          .map(SpaceInvite.fromJson)
          .whereType<SpaceInvite>()
          .take(_maxSpaceInvites)
          .toList();
      return (incoming: incoming, outgoing: outgoing);
    } catch (_) {
      return (incoming: <PendingSpaceInvite>[], outgoing: <SpaceInvite>[]);
    }
  }

  Future<void> _saveSpaceInvites({
    required List<PendingSpaceInvite> incoming,
    required List<SpaceInvite> outgoing,
  }) => _owner._storage.putSetting(
    _spaceInvitesSetting,
    jsonEncode({
      'v': 1,
      'incoming': [
        for (final invite in incoming.take(_maxSpaceInvites)) invite.toJson(),
      ],
      'outgoing': [
        for (final invite in outgoing.take(_maxSpaceInvites)) invite.toJson(),
      ],
    }),
  );

  /// Propose Space membership to one accepted contact. No membership state,
  /// history or epoch envelope is sent before the recipient explicitly accepts.
  Future<bool> inviteToSpace(
    NodeId spaceId,
    NodeId invitee, {
    GroupRole role = GroupRole.member,
  }) async {
    final bundle = await _owner.load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace || role == GroupRole.owner) {
      return false;
    }
    if (invitee == _owner.selfId) return false;
    if ((await _owner._storage.getContact(invitee))?.status !=
        ContactStatus.accepted) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    if (state.isMember(invitee) ||
        !SpaceAcl(state).allowsControl(
          _owner.selfId,
          ControlOp.addMember,
          target: invitee,
          newRole: role,
        )) {
      return false;
    }
    final sender = _owner.sendSpaceInvite;
    if (sender == null) return false;
    final now = _owner._now();
    final invite = SpaceInvite(
      inviteId: _owner._newSpaceInviteId(),
      spaceId: spaceId,
      inviter: _owner.selfId,
      invitee: invitee,
      spaceName: bundle.manifest.visibility == SpaceVisibility.secret
          ? ''
          : state.name,
      visibility: bundle.manifest.visibility!,
      role: role,
      createdAtMs: now,
      expiresAtMs: now + const Duration(days: 7).inMilliseconds,
    );
    await _serializeSpaceInvites(() async {
      final store = await _loadSpaceInvites();
      final outgoing = [
        invite,
        for (final old in store.outgoing)
          if (!(old.spaceId == spaceId && old.invitee == invitee)) old,
      ];
      await _saveSpaceInvites(incoming: store.incoming, outgoing: outgoing);
    });
    _owner.changes.value++;
    try {
      await sender(invitee, invite.inviteId, jsonEncode(invite.toJson()));
      return true;
    } catch (_) {
      // The proposal remains durable locally so a later explicit retry can use
      // the same consent id instead of silently adding the member.
      return false;
    }
  }

  /// Store a minimal proposal from the authenticated accepted contact.
  Future<bool> receiveSpaceInvite(NodeId peer, String inviteJson) async {
    final SpaceInvite? invite;
    try {
      invite = SpaceInvite.fromJson(jsonDecode(inviteJson));
    } catch (_) {
      return false;
    }
    final now = _owner._now();
    if (invite == null ||
        (await _owner._storage.getContact(peer))?.status !=
            ContactStatus.accepted ||
        invite.inviter != peer ||
        invite.invitee != _owner.selfId ||
        invite.createdAtMs > now + const Duration(minutes: 5).inMilliseconds ||
        invite.isExpiredAt(now) ||
        !await _owner._canStartSpaceMembershipProposal(invite.spaceId, now)) {
      return false;
    }
    final receivedInvite = invite;
    await _serializeSpaceInvites(() async {
      final store = await _loadSpaceInvites();
      PendingSpaceInvite? same;
      for (final old in store.incoming) {
        if (old.invite.inviteId == receivedInvite.inviteId) same = old;
      }
      final incoming = [
        same ?? PendingSpaceInvite(invite: receivedInvite),
        for (final old in store.incoming)
          if (old.invite.inviteId != receivedInvite.inviteId &&
              old.invite.spaceId != receivedInvite.spaceId)
            old,
      ];
      await _saveSpaceInvites(incoming: incoming, outgoing: store.outgoing);
    });
    _owner.changes.value++;
    return true;
  }

  Future<List<PendingSpaceInvite>> pendingSpaceInvites() async {
    return _serializeSpaceInvites(() async {
      final now = _owner._now();
      final store = await _loadSpaceInvites();
      final incoming = <PendingSpaceInvite>[];
      for (final entry in store.incoming) {
        if (entry.invite.isExpiredAt(now) ||
            (await _owner._storage.getContact(entry.invite.inviter))?.status !=
                ContactStatus.accepted) {
          continue;
        }
        incoming.add(entry);
      }
      if (incoming.length != store.incoming.length) {
        await _saveSpaceInvites(incoming: incoming, outgoing: store.outgoing);
        _owner.changes.value++;
      }
      incoming.sort(
        (left, right) =>
            right.invite.createdAtMs.compareTo(left.invite.createdAtMs),
      );
      return incoming;
    });
  }

  Future<bool> decideSpaceInvite(
    String inviteId, {
    required bool accept,
  }) async {
    final sender = _owner.sendSpaceInviteDecision;
    if (sender == null) return false;
    final prepared =
        await _serializeSpaceInvites<
          ({SpaceInvite invite, SpaceInviteDecision decision})?
        >(() async {
          final store = await _loadSpaceInvites();
          PendingSpaceInvite? pending;
          for (final candidate in store.incoming) {
            if (candidate.invite.inviteId == inviteId) pending = candidate;
          }
          if (pending == null) {
            return null;
          }
          final now = _owner._now();
          if (pending.invite.isExpiredAt(now) ||
              (await _owner._storage.getContact(
                    pending.invite.inviter,
                  ))?.status !=
                  ContactStatus.accepted) {
            await _saveSpaceInvites(
              incoming: [
                for (final entry in store.incoming)
                  if (entry.invite.inviteId != inviteId) entry,
              ],
              outgoing: store.outgoing,
            );
            _owner.changes.value++;
            return null;
          }
          final decidedAt = now;
          final decision = SpaceInviteDecision(
            inviteId: inviteId,
            spaceId: pending.invite.spaceId,
            accepted: accept,
            decidedAtMs: decidedAt,
          );
          final incoming = <PendingSpaceInvite>[
            for (final entry in store.incoming)
              if (entry.invite.inviteId != inviteId)
                entry
              else if (accept)
                PendingSpaceInvite(
                  invite: entry.invite,
                  acceptedAtMs: decidedAt,
                ),
          ];
          await _saveSpaceInvites(incoming: incoming, outgoing: store.outgoing);
          _owner.changes.value++;
          return (invite: pending.invite, decision: decision);
        });
    if (prepared == null) return false;
    try {
      await sender(
        prepared.invite.inviter,
        inviteId,
        jsonEncode(prepared.decision.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Match an authenticated invitee decision to our durable proposal. Only a
  /// valid current control-log authority can turn acceptance into membership.
  Future<bool> receiveSpaceInviteDecision(
    NodeId peer,
    String decisionJson,
  ) async {
    final SpaceInviteDecision? decision;
    try {
      decision = SpaceInviteDecision.fromJson(jsonDecode(decisionJson));
    } catch (_) {
      return false;
    }
    if (decision == null) return false;
    final matchedDecision = decision;
    if ((await _owner._storage.getContact(peer))?.status !=
        ContactStatus.accepted) {
      return false;
    }
    final store = await _loadSpaceInvites();
    SpaceInvite? invite;
    for (final candidate in store.outgoing) {
      if (candidate.inviteId == matchedDecision.inviteId &&
          candidate.spaceId == matchedDecision.spaceId &&
          candidate.invitee == peer) {
        invite = candidate;
      }
    }
    final now = _owner._now();
    if (invite == null ||
        invite.isExpiredAt(now) ||
        matchedDecision.decidedAtMs < invite.createdAtMs ||
        matchedDecision.decidedAtMs > invite.expiresAtMs ||
        matchedDecision.decidedAtMs >
            now + const Duration(minutes: 5).inMilliseconds) {
      return false;
    }
    final matchedInvite = invite;
    if (matchedDecision.accepted) {
      final added = await _owner._addMemberFromConsent(
        matchedInvite.spaceId,
        peer,
        matchedInvite.role,
        requireAcceptedContact: true,
      );
      if (!added) {
        if ((await _owner._storage.getContact(peer))?.status !=
            ContactStatus.accepted) {
          await _serializeSpaceInvites(() async {
            final latest = await _loadSpaceInvites();
            await _saveSpaceInvites(
              incoming: latest.incoming,
              outgoing: [
                for (final entry in latest.outgoing)
                  if (entry.inviteId != matchedInvite.inviteId) entry,
              ],
            );
          });
          _owner.changes.value++;
        }
        return false;
      }
    }
    await _serializeSpaceInvites(() async {
      final latest = await _loadSpaceInvites();
      await _saveSpaceInvites(
        incoming: latest.incoming,
        outgoing: [
          for (final entry in latest.outgoing)
            if (entry.inviteId != matchedDecision.inviteId) entry,
        ],
      );
    });
    _owner.changes.value++;
    return true;
  }
}
