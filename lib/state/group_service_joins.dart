part of 'group_service.dart';

/// Joining a Space by link: minting and revoking the capability-bound code,
/// asking to join, the owner's pending queue, and the accept/decline round
/// trip in both directions.
///
/// A collaborator rather than an extension, for the same reason as
/// [_Reactions] and [_SpaceInvites].
///
/// Extracted member by member rather than as a line range. After ten slices
/// the remaining clusters are interleaved with delegates the earlier ones left
/// behind, and a span cut here swallowed the [_Recommendations] field on the
/// first attempt.
///
/// `_acceptedSpaceJoinRequestFor` stays on the owner — it belongs to the
/// stranger-ingest path — and reaches this store through the collaborator.
class _SpaceJoins {
  _SpaceJoins(this._owner);

  final GroupService _owner;

  static const String _spaceJoinRequestsSetting = 'spaces.join_requests.v1';
  static const int _maxSpaceJoinRecords = 256;
  Future<void> _spaceJoinMutationTail = Future<void>.value();

  Future<T> _serializeSpaceJoins<T>(Future<T> Function() action) async {
    final previous = _spaceJoinMutationTail;
    final gate = Completer<void>();
    _spaceJoinMutationTail = gate.future;
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
      List<SpaceJoinTicket> tickets,
      List<SpaceJoinInboxEntry> incoming,
      List<SpaceJoinOutboxEntry> outgoing,
    })
  >
  _loadSpaceJoins() async {
    final raw = await _owner._storage.getSetting(_spaceJoinRequestsSetting);
    if (raw == null || raw.isEmpty) {
      return (
        tickets: <SpaceJoinTicket>[],
        incoming: <SpaceJoinInboxEntry>[],
        outgoing: <SpaceJoinOutboxEntry>[],
      );
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['v'] != 1) throw const FormatException();
      return (
        tickets: (value['tickets'] as List? ?? const [])
            .map(SpaceJoinTicket.fromJson)
            .whereType<SpaceJoinTicket>()
            .take(_maxSpaceJoinRecords)
            .toList(),
        incoming: (value['incoming'] as List? ?? const [])
            .map(SpaceJoinInboxEntry.fromJson)
            .whereType<SpaceJoinInboxEntry>()
            .take(_maxSpaceJoinRecords)
            .toList(),
        outgoing: (value['outgoing'] as List? ?? const [])
            .map(SpaceJoinOutboxEntry.fromJson)
            .whereType<SpaceJoinOutboxEntry>()
            .take(_maxSpaceJoinRecords)
            .toList(),
      );
    } catch (_) {
      return (
        tickets: <SpaceJoinTicket>[],
        incoming: <SpaceJoinInboxEntry>[],
        outgoing: <SpaceJoinOutboxEntry>[],
      );
    }
  }

  Future<void> _saveSpaceJoins({
    required List<SpaceJoinTicket> tickets,
    required List<SpaceJoinInboxEntry> incoming,
    required List<SpaceJoinOutboxEntry> outgoing,
  }) => _owner._storage.putSetting(
    _spaceJoinRequestsSetting,
    jsonEncode({
      'v': 1,
      'tickets': [
        for (final ticket in tickets.take(_maxSpaceJoinRecords))
          ticket.toJson(),
      ],
      'incoming': [
        for (final entry in incoming.take(_maxSpaceJoinRecords)) entry.toJson(),
      ],
      'outgoing': [
        for (final entry in outgoing.take(_maxSpaceJoinRecords)) entry.toJson(),
      ],
    }),
  );

  /// Create or reuse a capability-bound join link for one active public Space.
  /// Only an actor who can currently add a member may issue it. The link itself
  /// grants no data and is useless after the local ticket is revoked/expired.
  Future<String?> createSpaceJoinCode(NodeId spaceId) async {
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
    if (!SpaceAcl(state).allowsControl(
      _owner.selfId,
      ControlOp.addMember,
      newRole: GroupRole.member,
    )) {
      return null;
    }
    return _serializeSpaceJoins(() async {
      final now = _owner._now();
      final store = await _loadSpaceJoins();
      SpaceJoinTicket? current;
      for (final ticket in store.tickets) {
        if (ticket.spaceId == spaceId &&
            ticket.approver == _owner.selfId &&
            !ticket.isExpiredAt(now)) {
          current = ticket;
          break;
        }
      }
      current ??= SpaceJoinTicket(
        ticketId: _owner._newSpaceInviteId(),
        spaceId: spaceId,
        approver: _owner.selfId,
        spaceName: state.name,
        createdAtMs: now,
        expiresAtMs: now + kSpaceJoinTicketLifetime.inMilliseconds,
      );
      if (current.spaceName != state.name) {
        current = SpaceJoinTicket(
          ticketId: current.ticketId,
          spaceId: current.spaceId,
          approver: current.approver,
          spaceName: state.name,
          createdAtMs: current.createdAtMs,
          expiresAtMs: current.expiresAtMs,
        );
      }
      final tickets = <SpaceJoinTicket>[
        current,
        for (final ticket in store.tickets)
          if (ticket.spaceId != spaceId && !ticket.isExpiredAt(now)) ticket,
      ];
      final oldTickets = jsonEncode([
        for (final ticket in store.tickets) ticket.toJson(),
      ]);
      final newTickets = jsonEncode([
        for (final ticket in tickets) ticket.toJson(),
      ]);
      if (oldTickets == newTickets) return SpaceJoinCode.encode(current);
      await _saveSpaceJoins(
        tickets: tickets,
        incoming: store.incoming,
        outgoing: store.outgoing,
      );
      _owner.changes.value++;
      return SpaceJoinCode.encode(current);
    });
  }

  Future<bool> revokeSpaceJoinCode(NodeId spaceId) => _serializeSpaceJoins(
    () async {
      final store = await _loadSpaceJoins();
      final revokedTicketIds = <String>{
        for (final ticket in store.tickets)
          if (ticket.spaceId == spaceId && ticket.approver == _owner.selfId)
            ticket.ticketId,
      };
      final tickets = [
        for (final ticket in store.tickets)
          if (!(ticket.spaceId == spaceId && ticket.approver == _owner.selfId))
            ticket,
      ];
      if (tickets.length == store.tickets.length) return false;
      await _saveSpaceJoins(
        tickets: tickets,
        incoming: [
          for (final entry in store.incoming)
            if (!entry.pending ||
                !revokedTicketIds.contains(entry.request.ticketId))
              entry,
        ],
        outgoing: store.outgoing,
      );
      _owner.changes.value++;
      return true;
    },
  );

  Future<String?> currentSpaceJoinCode(NodeId spaceId) async {
    final now = _owner._now();
    for (final ticket in (await _loadSpaceJoins()).tickets) {
      if (ticket.spaceId == spaceId &&
          ticket.approver == _owner.selfId &&
          !ticket.isExpiredAt(now)) {
        return SpaceJoinCode.encode(ticket);
      }
    }
    return null;
  }

  /// Send a requester-authenticated intent using a public bearer link. No
  /// contact relationship is required; blocked peers are still rejected.
  Future<bool> requestToJoinSpace(String code) async {
    final SpaceJoinTicket ticket;
    try {
      ticket = SpaceJoinCode.parse(code);
    } catch (_) {
      return false;
    }
    final now = _owner._now();
    if (ticket.approver == _owner.selfId ||
        ticket.createdAtMs > now + const Duration(minutes: 5).inMilliseconds ||
        ticket.isExpiredAt(now) ||
        !await _owner._canStartSpaceMembershipProposal(ticket.spaceId, now) ||
        (await _owner._storage.getContact(ticket.approver))?.status ==
            ContactStatus.blocked ||
        _owner.sendSpaceJoinRequest == null) {
      return false;
    }
    final prepared = await _serializeSpaceJoins(() async {
      final store = await _loadSpaceJoins();
      for (final existing in store.outgoing) {
        if (existing.ticket.spaceId == ticket.spaceId &&
            !existing.declined &&
            !existing.ticket.isExpiredAt(now)) {
          return existing;
        }
      }
      final request = SpaceJoinRequest(
        requestId: _owner._newSpaceInviteId(),
        ticketId: ticket.ticketId,
        ticketHash: spaceJoinTicketHash(ticket),
        spaceId: ticket.spaceId,
        requester: _owner.selfId,
        approver: ticket.approver,
        createdAtMs: now < ticket.createdAtMs ? ticket.createdAtMs : now,
      );
      final entry = SpaceJoinOutboxEntry(ticket: ticket, request: request);
      if (!entry.isStructurallyValid) return null;
      await _saveSpaceJoins(
        tickets: store.tickets,
        incoming: store.incoming,
        outgoing: [
          entry,
          for (final old in store.outgoing)
            if (old.ticket.spaceId != ticket.spaceId) old,
        ],
      );
      _owner.changes.value++;
      return entry;
    });
    if (prepared == null) return false;
    try {
      await _owner.sendSpaceJoinRequest!(
        prepared.request.approver,
        prepared.request.requestId,
        jsonEncode(prepared.request.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<SpaceJoinOutboxEntry>> outgoingSpaceJoinRequests() async {
    return _serializeSpaceJoins(() async {
      final now = _owner._now();
      final store = await _loadSpaceJoins();
      final outgoing = <SpaceJoinOutboxEntry>[];
      for (final entry in store.outgoing) {
        if (entry.ticket.isExpiredAt(now) ||
            (await _owner._storage.getContact(
                  entry.request.approver,
                ))?.status ==
                ContactStatus.blocked) {
          continue;
        }
        final bundle = await _owner.load(entry.ticket.spaceId);
        if (bundle != null &&
            (!_owner._validSpaceBundle(bundle) ||
                _owner._spaceMembershipForBundle(bundle, now).status !=
                    SpaceMembershipStatus.left)) {
          continue;
        }
        if (entry.declined &&
            now - entry.decision!.decidedAtMs >
                kSpaceJoinRequestRetryDelay.inMilliseconds) {
          continue;
        }
        outgoing.add(entry);
      }
      if (outgoing.length != store.outgoing.length) {
        await _saveSpaceJoins(
          tickets: store.tickets,
          incoming: store.incoming,
          outgoing: outgoing,
        );
        _owner.changes.value++;
      }
      outgoing.sort(
        (left, right) =>
            right.request.createdAtMs.compareTo(left.request.createdAtMs),
      );
      return outgoing;
    });
  }

  Future<bool> dismissSpaceJoinRequest(String requestId) =>
      _serializeSpaceJoins(() async {
        final store = await _loadSpaceJoins();
        final outgoing = [
          for (final entry in store.outgoing)
            if (entry.request.requestId != requestId) entry,
        ];
        if (outgoing.length == store.outgoing.length) return false;
        await _saveSpaceJoins(
          tickets: store.tickets,
          incoming: store.incoming,
          outgoing: outgoing,
        );
        _owner.changes.value++;
        return true;
      });

  /// Validate and durably persist one capability-bound request from an
  /// authenticated Veil sender. The ticket, current public Space policy and
  /// per-requester cooldown all have to pass before an ACK is permitted.
  Future<bool> receiveSpaceJoinRequest(NodeId peer, String requestJson) async {
    final SpaceJoinRequest? request;
    try {
      request = SpaceJoinRequest.fromJson(jsonDecode(requestJson));
    } catch (_) {
      return false;
    }
    final now = _owner._now();
    if (request == null ||
        request.requester != peer ||
        request.approver != _owner.selfId ||
        request.createdAtMs > now + const Duration(minutes: 5).inMilliseconds ||
        (await _owner._storage.getContact(peer))?.status ==
            ContactStatus.blocked) {
      return false;
    }
    final bundle = await _owner.load(request.spaceId);
    if (bundle == null ||
        !bundle.manifest.isSpace ||
        bundle.manifest.visibility != SpaceVisibility.public) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (state.isMember(peer) ||
        !SpaceAcl(state).allowsControl(
          _owner.selfId,
          ControlOp.addMember,
          target: peer,
          newRole: GroupRole.member,
        )) {
      return false;
    }
    final acceptedRequest = request;
    return _serializeSpaceJoins(() async {
      final store = await _loadSpaceJoins();
      if (_liveTicketForSpaceJoinRequest(store.tickets, acceptedRequest, now) ==
          null) {
        return false;
      }
      for (final old in store.incoming) {
        if (old.request.requestId == acceptedRequest.requestId) {
          return old.request.requester == peer &&
              old.request.spaceId == acceptedRequest.spaceId;
        }
        if (old.request.requester == peer &&
            old.request.spaceId == acceptedRequest.spaceId &&
            (old.pending ||
                now - old.decision!.decidedAtMs <
                    kSpaceJoinRequestRetryDelay.inMilliseconds)) {
          return false;
        }
      }
      final entry = SpaceJoinInboxEntry(
        request: acceptedRequest,
        receivedAtMs: now < acceptedRequest.createdAtMs
            ? acceptedRequest.createdAtMs
            : now,
      );
      await _saveSpaceJoins(
        tickets: store.tickets,
        incoming: [
          entry,
          for (final old in store.incoming)
            if (!(old.request.requester == peer &&
                old.request.spaceId == acceptedRequest.spaceId))
              old,
        ],
        outgoing: store.outgoing,
      );
      _owner.changes.value++;
      return true;
    });
  }

  SpaceJoinTicket? _liveTicketForSpaceJoinRequest(
    List<SpaceJoinTicket> tickets,
    SpaceJoinRequest request,
    int now,
  ) {
    for (final ticket in tickets) {
      if (ticket.ticketId == request.ticketId &&
          ticket.spaceId == request.spaceId &&
          ticket.approver == _owner.selfId &&
          request.approver == _owner.selfId &&
          !ticket.isExpiredAt(now) &&
          request.ticketHash == spaceJoinTicketHash(ticket) &&
          request.createdAtMs >= ticket.createdAtMs &&
          request.createdAtMs < ticket.expiresAtMs) {
        return ticket;
      }
    }
    return null;
  }

  Future<List<SpaceJoinInboxEntry>> pendingSpaceJoinRequests(
    NodeId spaceId,
  ) async {
    return _serializeSpaceJoins(() async {
      final now = _owner._now();
      final store = await _loadSpaceJoins();
      final incoming = <SpaceJoinInboxEntry>[];
      final result = <SpaceJoinInboxEntry>[];
      for (final entry in store.incoming) {
        if (entry.pending &&
            ((await _owner._storage.getContact(
                      entry.request.requester,
                    ))?.status ==
                    ContactStatus.blocked ||
                _liveTicketForSpaceJoinRequest(
                      store.tickets,
                      entry.request,
                      now,
                    ) ==
                    null)) {
          continue;
        }
        incoming.add(entry);
        if (entry.pending && entry.request.spaceId == spaceId) {
          result.add(entry);
        }
      }
      if (incoming.length != store.incoming.length) {
        await _saveSpaceJoins(
          tickets: store.tickets,
          incoming: incoming,
          outgoing: store.outgoing,
        );
        _owner.changes.value++;
      }
      result.sort(
        (left, right) => right.receivedAtMs.compareTo(left.receivedAtMs),
      );
      return result;
    });
  }

  Future<bool> decideSpaceJoinRequest(
    String requestId, {
    required bool accept,
  }) async {
    final sender = _owner.sendSpaceJoinDecision;
    if (sender == null) return false;
    final prepared =
        await _serializeSpaceJoins<
          ({SpaceJoinRequest request, SpaceJoinDecision decision})?
        >(() async {
          final store = await _loadSpaceJoins();
          SpaceJoinInboxEntry? pending;
          for (final candidate in store.incoming) {
            if (candidate.request.requestId == requestId && candidate.pending) {
              pending = candidate;
              break;
            }
          }
          if (pending == null) return null;
          final now = _owner._now();
          if ((await _owner._storage.getContact(
                    pending.request.requester,
                  ))?.status ==
                  ContactStatus.blocked ||
              _liveTicketForSpaceJoinRequest(
                    store.tickets,
                    pending.request,
                    now,
                  ) ==
                  null) {
            await _saveSpaceJoins(
              tickets: store.tickets,
              incoming: [
                for (final entry in store.incoming)
                  if (entry.request.requestId != requestId) entry,
              ],
              outgoing: store.outgoing,
            );
            _owner.changes.value++;
            return null;
          }
          if (accept) {
            final added = await _owner._addMemberFromConsent(
              pending.request.spaceId,
              pending.request.requester,
              GroupRole.member,
              requireAcceptedContact: false,
            );
            if (!added) {
              if ((await _owner._storage.getContact(
                    pending.request.requester,
                  ))?.status ==
                  ContactStatus.blocked) {
                await _saveSpaceJoins(
                  tickets: store.tickets,
                  incoming: [
                    for (final entry in store.incoming)
                      if (entry.request.requestId != requestId) entry,
                  ],
                  outgoing: store.outgoing,
                );
                _owner.changes.value++;
              }
              return null;
            }
          }
          final decision = SpaceJoinDecision(
            requestId: requestId,
            spaceId: pending.request.spaceId,
            accepted: accept,
            decidedAtMs: now < pending.receivedAtMs
                ? pending.receivedAtMs
                : now,
          );
          await _saveSpaceJoins(
            tickets: store.tickets,
            incoming: [
              for (final entry in store.incoming)
                if (entry.request.requestId == requestId)
                  SpaceJoinInboxEntry(
                    request: entry.request,
                    receivedAtMs: entry.receivedAtMs,
                    decision: decision,
                  )
                else
                  entry,
            ],
            outgoing: store.outgoing,
          );
          _owner.changes.value++;
          return (request: pending.request, decision: decision);
        });
    if (prepared == null) return false;
    try {
      await sender(
        prepared.request.requester,
        prepared.request.requestId,
        jsonEncode(prepared.decision.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> receiveSpaceJoinDecision(
    NodeId peer,
    String decisionJson,
  ) async {
    final SpaceJoinDecision? decision;
    try {
      decision = SpaceJoinDecision.fromJson(jsonDecode(decisionJson));
    } catch (_) {
      return false;
    }
    if (decision == null ||
        (await _owner._storage.getContact(peer))?.status ==
            ContactStatus.blocked) {
      return false;
    }
    final acceptedDecision = decision;
    return _serializeSpaceJoins(() async {
      final store = await _loadSpaceJoins();
      SpaceJoinOutboxEntry? matched;
      for (final entry in store.outgoing) {
        if (entry.request.requestId == acceptedDecision.requestId &&
            entry.request.spaceId == acceptedDecision.spaceId &&
            entry.request.approver == peer) {
          matched = entry;
          break;
        }
      }
      if (matched == null ||
          acceptedDecision.decidedAtMs < matched.request.createdAtMs ||
          acceptedDecision.decidedAtMs >
              matched.ticket.expiresAtMs +
                  const Duration(minutes: 5).inMilliseconds) {
        return false;
      }
      if (matched.decision != null) {
        return matched.decision!.accepted == acceptedDecision.accepted &&
            matched.decision!.decidedAtMs == acceptedDecision.decidedAtMs;
      }
      await _saveSpaceJoins(
        tickets: store.tickets,
        incoming: store.incoming,
        outgoing: [
          for (final entry in store.outgoing)
            if (entry.request.requestId == acceptedDecision.requestId)
              SpaceJoinOutboxEntry(
                ticket: entry.ticket,
                request: entry.request,
                decision: acceptedDecision,
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
