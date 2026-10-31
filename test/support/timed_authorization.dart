import 'dart:async';

import 'package:xveil/domain/peer_authorization.dart';
import 'package:xveil/state/peer_authorization_persistence.dart';

import 'timed_group_storage.dart';
import 'timed_native_store.dart';

/// Passive test attribution, with synthetic local operation numbers only.
class TimedAuthorizationStorage extends TimedGroupFileStorage {
  TimedAuthorizationStorage(
    super.opener, {
    required super.observe,
    required super.clock,
    required super.observeFiles,
    required this.observeAuthorization,
  });
  final NativeTiming observeAuthorization;
  int _nextOperation = 0;

  @override
  Future<void> replacePeerAuthorization(
    List<PeerAuthorizationEntry> entries,
  ) async {
    final start = clock.elapsedMicroseconds;
    final operation = ++_nextOperation;
    final flush = Zone.current[authorizationFlushTimingKey];
    var success = false;
    try {
      await runZoned(
        () => super.replacePeerAuthorization(entries),
        zoneValues: {authorizationTimingOpKey: operation},
      );
      success = true;
    } finally {
      observeAuthorization({
        'operation': 'authorization.replace',
        'authorization_operation': operation,
        if (flush is int) 'authorization_flush': flush,
        'start_us': start,
        'duration_us': clock.elapsedMicroseconds - start,
        'documents': entries.length,
        'success': success,
      });
    }
  }
}

class TimedPeerAuthorizationPersistence extends PeerAuthorizationPersistence {
  TimedPeerAuthorizationPersistence({
    required super.native,
    required super.storage,
    super.pollEvery,
    required this.clock,
    required this.observe,
  });
  final Stopwatch clock;
  final NativeTiming observe;
  int _nextFlush = 0;

  @override
  Future<void> flush() async {
    final start = clock.elapsedMicroseconds;
    final flush = ++_nextFlush;
    var success = false;
    try {
      await runZoned(
        () => super.flush(),
        zoneValues: {authorizationFlushTimingKey: flush},
      );
      success = true;
    } finally {
      observe({
        'operation': 'authorization.flush',
        'authorization_flush': flush,
        'start_us': start,
        'duration_us': clock.elapsedMicroseconds - start,
        'success': success,
      });
    }
  }
}
