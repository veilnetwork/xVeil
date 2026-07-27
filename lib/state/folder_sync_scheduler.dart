import 'dart:async';

import '../domain/folder_sync.dart';

/// Decides WHEN a pair syncs, given things that happen to it.
///
/// Three things can mean "there may be work": the folder changed, the cloud
/// index changed, or enough time passed that neither signal can be trusted to
/// have arrived. All three funnel through one quiet period, for a reason that
/// is easy to miss: a pass WRITES files, so its own writes come straight back
/// as folder events. Reacting to each of them would have the mirror chase its
/// own tail. Waiting for the folder to fall silent turns a burst — a save, an
/// unpack, our own downloads — into exactly one pass.
class FolderSyncScheduler {
  /// Positional because Dart forbids a private NAMED parameter and these
  /// fields are internal: (run, quiet period, sweep interval).
  FolderSyncScheduler(this._run, this._quietPeriod, this._sweepInterval);

  final Future<void> Function(FolderSyncPair pair) _run;
  final Duration _quietPeriod;
  final Duration _sweepInterval;

  final Map<String, _PairSchedule> _pairs = {};
  Timer? _sweep;

  /// Start watching [pair]. [localEvents] is anything the folder reports;
  /// its VALUES are ignored, only their arrival matters.
  void watch(FolderSyncPair pair, Stream<void> localEvents) {
    unwatch(pair.id);
    final schedule = _PairSchedule(pair);
    schedule.subscription = localEvents.listen(
      (_) => _touch(pair.id),
      // A watcher can die (the folder was removed, the OS ran out of handles).
      // The periodic sweep is what keeps the pair syncing afterwards, so a
      // dead watcher degrades the cadence rather than stopping the mirror.
      onError: (_) {},
      cancelOnError: false,
    );
    _pairs[pair.id] = schedule;
    _sweep ??= Timer.periodic(_sweepInterval, (_) => _sweepAll());
  }

  void unwatch(String pairId) {
    final schedule = _pairs.remove(pairId);
    schedule?.dispose();
    if (_pairs.isEmpty) {
      _sweep?.cancel();
      _sweep = null;
    }
  }

  /// The cloud index moved. Nothing local happened, so this is the signal for
  /// another device's edit.
  void noteRemoteChange() {
    for (final id in _pairs.keys.toList()) {
      _touch(id);
    }
  }

  void _touch(String pairId) {
    final schedule = _pairs[pairId];
    if (schedule == null) return;
    schedule.pending = true;
    schedule.quiet?.cancel();
    schedule.quiet = Timer(_quietPeriod, () => unawaited(_fire(schedule)));
  }

  void _sweepAll() {
    for (final schedule in _pairs.values.toList()) {
      // The sweep does not wait for quiet: nothing has happened, which is
      // exactly why it is running.
      unawaited(_fire(schedule));
    }
  }

  Future<void> _fire(_PairSchedule schedule) async {
    if (schedule.running) {
      // Something arrived while a pass was in flight. Remember it rather than
      // queue a second pass: the pass in flight may already be acting on a
      // stale picture, and one follow-up settles that whatever the burst size.
      schedule.again = true;
      return;
    }
    schedule.running = true;
    schedule.pending = false;
    try {
      await _run(schedule.pair);
    } catch (_) {
      // A failed pass is reported by the pass itself; the schedule's job is
      // only to keep the next one coming.
    } finally {
      schedule.running = false;
      if (schedule.again && _pairs.containsKey(schedule.pair.id)) {
        schedule.again = false;
        _touch(schedule.pair.id);
      }
    }
  }

  void dispose() {
    for (final id in _pairs.keys.toList()) {
      unwatch(id);
    }
    _sweep?.cancel();
    _sweep = null;
  }
}

class _PairSchedule {
  _PairSchedule(this.pair);

  final FolderSyncPair pair;
  StreamSubscription<void>? subscription;
  Timer? quiet;
  bool pending = false;
  bool running = false;
  bool again = false;

  void dispose() {
    quiet?.cancel();
    unawaited(subscription?.cancel());
  }
}
