// Public constructor names match the other persistence owners.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../core/error_journal.dart';
import '../data/storage/storage.dart';
import '../domain/peer_authorization.dart';

/// Checkpoint signed negative authorization evidence inside one identity's
/// encrypted space. No native runtime files, automatic upload or raw logging.
class PeerAuthorizationPersistence {
  PeerAuthorizationPersistence({
    required PeerAuthorizationStateHandle native,
    required Storage storage,
    this.pollEvery = const Duration(seconds: 1),
  }) : _native = native,
       _storage = storage;

  final PeerAuthorizationStateHandle _native;
  final Storage _storage;
  final Duration pollEvery;
  Future<void> _tail = Future<void>.value();
  Timer? _timer;
  int? _savedRevision;
  bool _closed = false;
  bool _restored = false;
  Future<void>? _closing;

  /// Boot only, before the application transport binds any endpoint. Native
  /// code validates every document and replays transient boot observations
  /// against this durable baseline. A corrupt record is never discarded.
  void restore(List<PeerAuthorizationEntry> entries) {
    if (_restored || _timer != null || _closed) {
      throw StateError('Peer authorization restore after startup');
    }
    _native.restorePeerAuthorization(PeerAuthorizationSnapshot(0, entries));
    _restored = true;
  }

  void start() {
    if (_closed || _timer != null) return;
    if (!_restored) throw StateError('Peer authorization restore is required');
    if (pollEvery <= Duration.zero) {
      throw ArgumentError.value(pollEvery, 'pollEvery');
    }
    _timer = Timer.periodic(pollEvery, (_) {
      unawaited(
        flush().catchError((Object error, StackTrace stack) {
          errorJournal.record(
            kind: 'peer-authorization-persist',
            atMs: DateTime.now().millisecondsSinceEpoch,
            error: StateError('Encrypted authorization checkpoint failed'),
          );
        }),
      );
    });
  }

  Future<void> flush() {
    if (_closed) return _closing ?? Future<void>.value();
    if (!_restored) {
      return Future.error(StateError('Peer authorization restore is required'));
    }
    final next = _tail.then((_) => _flush());
    // A failed publication must not wedge later attempts or advance the saved
    // revision. The caller still receives the failure through `next`.
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> _flush() async {
    if (_native.peerAuthorizationVersion() == _savedRevision) return;
    final snapshot = _native.exportPeerAuthorization();
    await _storage.replacePeerAuthorization(snapshot.entries);
    // Exactly the exported revision, not a newer revision sampled after I/O.
    // Changes during the commit remain pending for the next flush.
    _native.acknowledgePeerAuthorization(snapshot.revision);
    _savedRevision = snapshot.revision;
  }

  /// Join an in-flight checkpoint, take one final snapshot, then let the stack
  /// close the shared native handle. Idempotent; never leaves a timer behind.
  Future<void> close() {
    final prior = _closing;
    if (prior != null) return prior;
    _closed = true;
    _timer?.cancel();
    _timer = null;
    return _closing = _tail.then((_) async {
      if (_restored) await _flush();
    });
  }
}
