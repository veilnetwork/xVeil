part of 'group_service.dart';

/// Appealing a moderation action, and deciding on those appeals.
///
/// A collaborator rather than an extension, for the same reason as
/// [_Reactions] and [_AbuseReports]. Like the abuse and recommendation slices
/// it owns its state — the storage key, the record cap and the mutation gate
/// are used nowhere else, so they move with the code.
///
/// The public entry points stay on [GroupService]; this decomposition does not
/// change the API.
class _ModerationAppeals {
  _ModerationAppeals(this._owner);

  final GroupService _owner;

  static const String _spaceModerationAppealsSetting =
      'spaces.moderation_appeals.v1';
  static const int _maxSpaceModerationAppealRecords = 256;
  Future<void> _spaceModerationAppealMutationTail = Future<void>.value();

  Future<T> _serializeSpaceModerationAppeals<T>(
    Future<T> Function() action,
  ) async {
    final previous = _spaceModerationAppealMutationTail;
    final gate = Completer<void>();
    _spaceModerationAppealMutationTail = gate.future;
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
      List<SpaceModerationAppealInboxEntry> incoming,
      List<SpaceModerationAppealOutboxEntry> outgoing,
    })
  >
  _loadSpaceModerationAppeals() async {
    final blob = await _owner._storage.loadFile(_spaceModerationAppealsSetting);
    if (blob == null || blob.isEmpty) {
      return (
        incoming: <SpaceModerationAppealInboxEntry>[],
        outgoing: <SpaceModerationAppealOutboxEntry>[],
      );
    }
    try {
      final value = jsonDecode(utf8.decode(blob, allowMalformed: false));
      if (value is! Map || value['v'] != 1) throw const FormatException();
      return (
        incoming: (value['incoming'] as List? ?? const [])
            .map(SpaceModerationAppealInboxEntry.fromJson)
            .whereType<SpaceModerationAppealInboxEntry>()
            .take(_maxSpaceModerationAppealRecords)
            .toList(),
        outgoing: (value['outgoing'] as List? ?? const [])
            .map(SpaceModerationAppealOutboxEntry.fromJson)
            .whereType<SpaceModerationAppealOutboxEntry>()
            .take(_maxSpaceModerationAppealRecords)
            .toList(),
      );
    } catch (_) {
      return (
        incoming: <SpaceModerationAppealInboxEntry>[],
        outgoing: <SpaceModerationAppealOutboxEntry>[],
      );
    }
  }

  Future<void> _saveSpaceModerationAppeals({
    required List<SpaceModerationAppealInboxEntry> incoming,
    required List<SpaceModerationAppealOutboxEntry> outgoing,
  }) {
    final raw = jsonEncode({
      'v': 1,
      'incoming': [
        for (final entry in incoming.take(_maxSpaceModerationAppealRecords))
          entry.toJson(),
      ],
      'outgoing': [
        for (final entry in outgoing.take(_maxSpaceModerationAppealRecords))
          entry.toJson(),
      ],
    });
    return _owner._storage.storeFile(
      _spaceModerationAppealsSetting,
      Uint8List.fromList(utf8.encode(raw)),
      name: 'moderation-appeals',
    );
  }

  /// Returns self-targeted actions even when the Space itself is hidden after
  /// a ban. Already appealed actions live in [outgoingSpaceModerationAppeals].
  Future<List<SpaceModerationAppealCandidate>>
  appealableSpaceModerationActions() async {
    final outgoing = (await _loadSpaceModerationAppeals()).outgoing;
    final result = <SpaceModerationAppealCandidate>[];
    for (final hex in await _owner._index()) {
      try {
        final bundle = await _owner.load(NodeId.fromHex(hex));
        if (bundle == null || !bundle.manifest.isSpace) continue;
        final state = foldControlLog(
          owner: bundle.manifest.owner,
          entries: bundle.control,
          verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
          initialName: bundle.manifest.name,
          initialDescription: bundle.manifest.description ?? '',
        ).state;
        final reviewer = _owner._effectiveSpaceOwner(state);
        for (final record in await _owner._moderationRecordsOfBundle(
          bundle,
          state,
        )) {
          final appealed = outgoing.any(
            (entry) =>
                entry.appeal.spaceId == bundle.manifest.groupId &&
                entry.appeal.actionId == record.actionId &&
                (entry.decision != null || entry.appeal.reviewer == reviewer),
          );
          if (record.action.target == _owner.selfId &&
              record.revokedAtMs == null &&
              !appealed) {
            result.add(
              SpaceModerationAppealCandidate(
                spaceId: bundle.manifest.groupId,
                spaceName: state.name,
                record: record,
              ),
            );
          }
        }
      } catch (_) {}
    }
    result.sort(
      (left, right) => right.record.action.createdAtMs.compareTo(
        left.record.action.createdAtMs,
      ),
    );
    return result;
  }

  Future<List<SpaceModerationAppealOutboxEntry>>
  outgoingSpaceModerationAppeals() async {
    final result = (await _loadSpaceModerationAppeals()).outgoing.toList()
      ..sort(
        (left, right) =>
            right.appeal.createdAtMs.compareTo(left.appeal.createdAtMs),
      );
    return result;
  }

  Future<Map<String, String>> moderationAppealSpaceNames() async {
    final store = await _loadSpaceModerationAppeals();
    final ids = <String>{
      for (final entry in store.incoming) entry.appeal.spaceId.hex,
      for (final entry in store.outgoing) entry.appeal.spaceId.hex,
    };
    final result = <String, String>{};
    for (final hex in ids) {
      try {
        final bundle = await _owner.load(NodeId.fromHex(hex));
        if (bundle == null || !bundle.manifest.isSpace) continue;
        final state = foldControlLog(
          owner: bundle.manifest.owner,
          entries: bundle.control,
          verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
          initialName: bundle.manifest.name,
          initialDescription: bundle.manifest.description ?? '',
        ).state;
        result[hex] = state.name;
      } catch (_) {}
    }
    return result;
  }

  Future<List<SpaceModerationAppealInboxEntry>> incomingSpaceModerationAppeals({
    NodeId? spaceId,
    bool pendingOnly = false,
  }) async {
    final result =
        (await _loadSpaceModerationAppeals()).incoming
            .where(
              (entry) =>
                  (spaceId == null || entry.appeal.spaceId == spaceId) &&
                  (!pendingOnly || entry.pending),
            )
            .toList()
          ..sort(
            (left, right) => right.receivedAtMs.compareTo(left.receivedAtMs),
          );
    return result;
  }

  /// Persist before enqueueing the external proposal. A second call for the
  /// same immutable action and current reviewer retransmits the exact signed
  /// row. An ownership transfer may create one replacement routed to the new
  /// effective owner; neither path introduces a time window.
  Future<bool> appealSpaceModeration(
    NodeId spaceId,
    String actionId, {
    required String text,
  }) async {
    final sender = _owner.sendSpaceModerationAppeal;
    if (sender == null) return false;
    final normalized = text.trim();
    final bundle = await _owner.load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    final record = await _owner._moderationRecord(bundle, state, actionId);
    final reviewer = _owner._effectiveSpaceOwner(state);
    if (record == null ||
        record.revokedAtMs != null ||
        record.action.target != _owner.selfId ||
        reviewer == null ||
        reviewer == _owner.selfId) {
      return false;
    }
    final appeal = await _serializeSpaceModerationAppeals(() async {
      final store = await _loadSpaceModerationAppeals();
      for (final entry in store.outgoing) {
        if (entry.appeal.spaceId == spaceId &&
            entry.appeal.actionId == actionId &&
            (entry.decision != null || entry.appeal.reviewer == reviewer)) {
          return entry.decision == null ? entry.appeal : null;
        }
      }
      final now = _owner._now();
      final unsigned = SpaceModerationAppeal(
        appealId: _owner._newSpaceInviteId(),
        spaceId: spaceId,
        actionAuthor: record.actor,
        actionSeq: record.actionSeq,
        appellant: _owner.selfId,
        reviewer: reviewer,
        text: normalized,
        // This device's own assertion about when IT appealed, and nothing
        // else's. It used to be lifted to the moderator's
        // `action.createdAtMs` whenever that was ahead, to satisfy the
        // reviewer's "an appeal cannot predate its action" comparison — which
        // handed the moderator a switch: an action dated a year out made the
        // only appeal this code would sign a year out too, and every reviewer
        // refuses an appeal more than [kSpacePublicClockSkew] ahead of its own
        // clock. One number, chosen by the person being appealed against, and
        // the target loses the right to appeal at all, everywhere at once,
        // with nothing they can do about it. See [receiveSpaceModerationAppeal]
        // for the other half.
        createdAtMs: now,
        signature: Uint8List(0),
        authorPubKey: Uint8List(0),
      );
      if (!unsigned.isStructurallyValid) return null;
      final signed = _owner._signer.signModerationAppeal(unsigned);
      if (!_owner._signer.verifyModerationAppeal(signed)) return null;
      await _saveSpaceModerationAppeals(
        incoming: store.incoming,
        outgoing: [
          SpaceModerationAppealOutboxEntry(appeal: signed),
          ...store.outgoing,
        ],
      );
      _owner.changes.value++;
      return signed;
    });
    if (appeal == null) return false;
    try {
      await sender(
        appeal.reviewer,
        appeal.appealId,
        jsonEncode(appeal.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Authenticated-source, signature, owner route and exact action checks all
  /// pass before durable persistence allows the transport ACK.
  Future<bool> receiveSpaceModerationAppeal(
    NodeId peer,
    String appealJson,
  ) async {
    final SpaceModerationAppeal? appeal;
    try {
      appeal = SpaceModerationAppeal.fromJson(jsonDecode(appealJson));
    } catch (_) {
      return false;
    }
    final now = _owner._now();
    if (appeal == null ||
        appeal.appellant != peer ||
        appeal.reviewer != _owner.selfId ||
        appeal.createdAtMs >
            now + kSpacePublicClockSkew.inMilliseconds ||
        !_owner._signer.verifyModerationAppeal(appeal) ||
        (await _owner._storage.getContact(peer))?.status ==
            ContactStatus.blocked) {
      return false;
    }
    final acceptedAppeal = appeal;
    final bundle = await _owner.load(acceptedAppeal.spaceId);
    if (bundle == null || !bundle.manifest.isSpace) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (_owner._effectiveSpaceOwner(state) != _owner.selfId) return false;
    final record = await _owner._moderationRecord(
      bundle,
      state,
      acceptedAppeal.actionId,
    );
    // Deliberately no "the appeal must not predate its action" comparison. It
    // weighed two numbers from two different unauthenticated clocks — the
    // appellant's and the MODERATOR's — so between honest participants it
    // already misfired whenever the moderator's clock led the appellant's, and
    // the only way to satisfy it was for the appellant to copy the moderator's
    // number into its own signed appeal, which is what let one future-dated
    // action retire its target's right of appeal at every reviewer at once.
    //
    // Causality is proved here without a clock and always was: the appeal
    // names an exact action by (actionAuthor, actionSeq), `_moderationRecord`
    // must find that action accepted in the signed control log, and the action
    // must target this very peer. You cannot appeal something that has not
    // happened. The appeal's own stamp is still bounded above by the
    // [kSpacePublicClockSkew] gate on the way in, which is the one thing this
    // device can actually judge.
    if (record == null || record.action.target != peer) {
      return false;
    }
    return _serializeSpaceModerationAppeals(() async {
      final store = await _loadSpaceModerationAppeals();
      for (final old in store.incoming) {
        if (old.appeal.appealId == acceptedAppeal.appealId) {
          return jsonEncode(old.appeal.toJson()) ==
              jsonEncode(acceptedAppeal.toJson());
        }
        if (old.appeal.spaceId == acceptedAppeal.spaceId &&
            old.appeal.actionId == acceptedAppeal.actionId &&
            old.appeal.appellant == peer) {
          return false;
        }
      }
      final entry = SpaceModerationAppealInboxEntry(
        appeal: acceptedAppeal,
        receivedAtMs: now < acceptedAppeal.createdAtMs
            ? acceptedAppeal.createdAtMs
            : now,
      );
      await _saveSpaceModerationAppeals(
        incoming: [entry, ...store.incoming],
        outgoing: store.outgoing,
      );
      _owner.changes.value++;
      return true;
    });
  }

  Future<bool> decideSpaceModerationAppeal(
    String appealId, {
    required SpaceModerationAppealOutcome outcome,
    required String reason,
  }) async {
    final sender = _owner.sendSpaceModerationAppealDecision;
    if (sender == null) return false;
    final normalized = reason.trim();
    final prepared =
        await _serializeSpaceModerationAppeals<
          ({
            SpaceModerationAppeal appeal,
            SpaceModerationAppealDecision decision,
          })?
        >(() async {
          final store = await _loadSpaceModerationAppeals();
          SpaceModerationAppealInboxEntry? pending;
          for (final entry in store.incoming) {
            if (entry.appeal.appealId == appealId && entry.pending) {
              pending = entry;
              break;
            }
          }
          if (pending == null) return null;
          final bundle = await _owner.load(pending.appeal.spaceId);
          if (bundle == null || !bundle.manifest.isSpace) return null;
          final state = foldControlLog(
            owner: bundle.manifest.owner,
            entries: bundle.control,
            verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
            initialName: bundle.manifest.name,
            initialDescription: bundle.manifest.description ?? '',
          ).state;
          if (_owner._effectiveSpaceOwner(state) != _owner.selfId) return null;
          var record = await _owner._moderationRecord(
            bundle,
            state,
            pending.appeal.actionId,
          );
          if (record == null ||
              record.action.target != pending.appeal.appellant) {
            return null;
          }
          final irreversible = {
            SpaceModerationKind.deleteMessage,
            SpaceModerationKind.deletePost,
          }.contains(record.action.kind);
          if (outcome ==
                  SpaceModerationAppealOutcome.acknowledgedIrreversible &&
              !irreversible) {
            return null;
          }
          if (outcome == SpaceModerationAppealOutcome.actionRevoked) {
            if (irreversible) return null;
            if (record.revokedAtMs == null &&
                !await _owner.revokeSpaceModeration(
                  pending.appeal.spaceId,
                  pending.appeal.actionId,
                  reason: normalized,
                )) {
              return null;
            }
            final current = await _owner.load(pending.appeal.spaceId);
            if (current == null) return null;
            final currentState = foldControlLog(
              owner: current.manifest.owner,
              entries: current.control,
              verify: (entry) =>
                  _owner._validControlFor(current.manifest, entry),
              initialName: current.manifest.name,
              initialDescription: current.manifest.description ?? '',
            ).state;
            record = await _owner._moderationRecord(
              current,
              currentState,
              pending.appeal.actionId,
            );
            if (record?.revokedAtMs == null) return null;
          }
          final now = _owner._now();
          final unsigned = SpaceModerationAppealDecision(
            appealId: appealId,
            spaceId: pending.appeal.spaceId,
            appellant: pending.appeal.appellant,
            reviewer: _owner.selfId,
            outcome: outcome,
            reason: normalized,
            decidedAtMs: now < pending.receivedAtMs
                ? pending.receivedAtMs
                : now,
            signature: Uint8List(0),
            authorPubKey: Uint8List(0),
          );
          if (!unsigned.isStructurallyValid) return null;
          final decision = _owner._signer.signModerationAppealDecision(
            unsigned,
          );
          if (!_owner._signer.verifyModerationAppealDecision(decision)) {
            return null;
          }
          await _saveSpaceModerationAppeals(
            incoming: [
              for (final entry in store.incoming)
                if (entry.appeal.appealId == appealId)
                  SpaceModerationAppealInboxEntry(
                    appeal: entry.appeal,
                    receivedAtMs: entry.receivedAtMs,
                    decision: decision,
                  )
                else
                  entry,
            ],
            outgoing: store.outgoing,
          );
          _owner.changes.value++;
          return (appeal: pending.appeal, decision: decision);
        });
    if (prepared == null) return false;
    try {
      await sender(
        prepared.appeal.appellant,
        prepared.appeal.appealId,
        jsonEncode(prepared.decision.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> receiveSpaceModerationAppealDecision(
    NodeId peer,
    String decisionJson,
  ) async {
    final SpaceModerationAppealDecision? decision;
    try {
      decision = SpaceModerationAppealDecision.fromJson(
        jsonDecode(decisionJson),
      );
    } catch (_) {
      return false;
    }
    final now = _owner._now();
    if (decision == null ||
        decision.reviewer != peer ||
        decision.appellant != _owner.selfId ||
        decision.decidedAtMs > now + kSpacePublicClockSkew.inMilliseconds ||
        !_owner._signer.verifyModerationAppealDecision(decision) ||
        (await _owner._storage.getContact(peer))?.status ==
            ContactStatus.blocked) {
      return false;
    }
    final acceptedDecision = decision;
    return _serializeSpaceModerationAppeals(() async {
      final store = await _loadSpaceModerationAppeals();
      SpaceModerationAppealOutboxEntry? matched;
      for (final entry in store.outgoing) {
        if (entry.appeal.appealId == acceptedDecision.appealId &&
            entry.appeal.spaceId == acceptedDecision.spaceId &&
            entry.appeal.reviewer == peer) {
          matched = entry;
          break;
        }
      }
      if (matched == null ||
          acceptedDecision.decidedAtMs < matched.appeal.createdAtMs) {
        return false;
      }
      if (matched.decision != null) {
        return jsonEncode(matched.decision!.toJson()) ==
            jsonEncode(acceptedDecision.toJson());
      }
      await _saveSpaceModerationAppeals(
        incoming: store.incoming,
        outgoing: [
          for (final entry in store.outgoing)
            if (entry.appeal.appealId == acceptedDecision.appealId)
              SpaceModerationAppealOutboxEntry(
                appeal: entry.appeal,
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
