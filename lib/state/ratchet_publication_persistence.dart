part of 'ratchet_persistence.dart';

const _hostReservationPoll = Duration(milliseconds: 200);

extension _HostRatchetPublication on RatchetPersistence {
  bool _isSupersededPublication() {
    final guard = _publicationGuard;
    final epoch = _publicationEpoch;
    if (guard != null &&
        epoch != null &&
        guard.hostPublicationState(epoch) ==
            RatchetPublicationState.superseded) {
      _publicationRetired = true;
      return true;
    }
    return false;
  }

  void _beginHostPublication() {
    final guard = _publicationGuard;
    if (guard == null) return;
    _publicationEpoch = guard.beginHostPublication();
    devLog(() => 'xVeil[ratchet]: atomic host publication guard active');
    _schedulePublicationPoll();
  }

  void _schedulePublicationPoll([Duration delay = _hostReservationPoll]) {
    if (_publicationClosing ||
        _publicationRetired ||
        _publicationGuard == null) {
      return;
    }
    _publicationTimer?.cancel();
    _publicationTimer = Timer(delay, _pollHostPublication);
  }

  void _publicationFailure(Object error) {
    if (_publicationClosing || _publicationRetired) return;
    _degraded = true;
    final count = ++_publicationFailures;
    if (count & (count - 1) == 0) {
      devLog(
        () =>
            'xVeil[ratchet]: host publication reservation failed '
            '$count time(s) (${error.runtimeType}); ciphertext stays held',
      );
    }
  }

  void _pollHostPublication() {
    _publicationTimer = null;
    if (_publicationClosing || _publicationRetired) return;
    final guard = _publicationGuard;
    final epoch = _publicationEpoch;
    if (guard == null || epoch == null) return;
    try {
      switch (guard.hostPublicationState(epoch)) {
        case RatchetPublicationState.retired:
        case RatchetPublicationState.superseded:
          _publicationRetired = true;
          return;
        case RatchetPublicationState.idle:
          _schedulePublicationPoll();
          return;
        case RatchetPublicationState.needsReservation:
          _pumpHostReservations();
      }
    } catch (error) {
      _publicationFailure(error);
      _schedulePublicationPoll(const Duration(seconds: 2));
    }
  }

  void _pumpHostReservations() {
    if (_publicationPump != null ||
        _publicationClosing ||
        _publicationRetired) {
      return;
    }
    var retryDelay = _hostReservationPoll;
    late final Future<void> work;
    work =
        _exclusive(() async {
              if (_publicationClosing || _publicationRetired) return;
              final state = _publicationGuard!.hostPublicationState(
                _publicationEpoch!,
              );
              if (state == RatchetPublicationState.retired ||
                  state == RatchetPublicationState.superseded) {
                _publicationRetired = true;
                return;
              }
              if (state == RatchetPublicationState.needsReservation) {
                // The native store, not a transport address, names the actual keys.
                // This covers a new/DH-rotated chain and physical-device addressing
                // whose ratchet certificate still names the stable peer identity.
                await _reserveForKeys(_liveKeys());
                devLog(
                  () =>
                      'xVeil[ratchet]: native publication reservation refreshed',
                );
              }
            })
            .catchError((Object error) {
              _publicationFailure(error);
              retryDelay = const Duration(seconds: 2);
            })
            .whenComplete(() {
              if (identical(_publicationPump, work)) _publicationPump = null;
              _schedulePublicationPoll(retryDelay);
            });
    _publicationPump = work;
    unawaited(work);
  }

  void _permitCommittedPositions(
    Uint8List key,
    List<RatchetSendPosition> marks,
    List<RatchetSendPosition> live,
  ) {
    final guard = _publicationGuard;
    final epoch = _publicationEpoch;
    if (guard == null || epoch == null) return;
    if (_publicationClosing || _publicationRetired) {
      throw StateError('ratchet publication owner closed');
    }
    // Stored snapshots can retain retired chains. Keep their durable marks,
    // but submit only the native store's bounded set of currently held chains.
    final current = <RatchetSendPosition>[];
    for (final at in live) {
      RatchetSendPosition? best;
      for (final mark in marks) {
        if (RatchetPersistence._sameKey(at.chain, mark.chain) &&
            (best == null || mark.next > best.next)) {
          best = mark;
        }
      }
      if (best != null) current.add(best);
    }
    guard.allowHostPublication(epoch, key, current);
  }

  Future<int> _closeHostPublication() async {
    _publicationClosing = true;
    _publicationTimer?.cancel();
    _publicationTimer = null;
    Object? closeError;
    StackTrace? closeStack;
    try {
      final epoch = _publicationEpoch;
      if (epoch != null) _publicationGuard?.endHostPublication(epoch);
    } catch (error, stack) {
      closeError = error;
      closeStack = stack;
    }
    await _publicationPump;
    final written = await saveAll();
    if (closeError != null) Error.throwWithStackTrace(closeError, closeStack!);
    return written;
  }
}
