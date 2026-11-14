import 'dart:async';

import 'profile_storage_router.dart';

/// Owns successive router lifetimes without redirecting old storage facades.
/// Suspension is synchronous; reopening requires a confirmed native close.
/// The normal opener still refuses an unfinished profile-erasure intent.
final class ProfileStorageRouterOwner {
  ProfileStorageRouterOwner(
    ProfileStorageRouter initial, {
    required Future<ProfileStorageRouter> Function() reopen,
  }) : _router = initial,
       _profile = initial.profileDirectory,
       _openReplacement = reopen;

  final String _profile;
  final Future<ProfileStorageRouter> Function() _openReplacement;
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  ProfileStorageRouter? _router;
  Future<void> _tail = Future.value();
  Future<void>? _suspending, _opening, _closing;
  bool _available = true, _disposed = false;
  int _epoch = 0;

  ProfileStorageRouter get router {
    if (!_available || _disposed) {
      throw StateError('storage router lifetime is unavailable');
    }
    return _router!;
  }

  Future<void> _enqueue(Future<void> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _release() async {
    final current = _router;
    if (current == null) return;
    // Retain a refused close, including an unpublished replacement, for retry.
    await current.close();
    _router = null;
  }

  Future<void> suspend() {
    if (_disposed) return Future.error(StateError('storage owner is closed'));
    final pending = _suspending;
    if (pending != null) return pending;
    _available = false;
    _epoch++;
    final result = _suspending = _enqueue(
      _release,
    ).whenComplete(() => _suspending = null);
    _changes.add(null);
    return result;
  }

  /// Explicit replacement after maintenance. This grants no OS-vault handoff:
  /// erasure callers must separately verify their exact release receipt.
  Future<void> reopen() {
    if (_disposed) return Future.error(StateError('storage owner is closed'));
    final pending = _opening;
    if (pending != null) return pending;
    if (_available) {
      return Future.error(StateError('suspend the storage owner first'));
    }
    final ticket = _epoch;
    return _opening = _enqueue(() async {
      if (_disposed || ticket != _epoch || _router != null) {
        throw StateError('storage router release is not confirmed');
      }
      final candidate = await _openReplacement();
      _router = candidate;
      if (_disposed ||
          ticket != _epoch ||
          candidate.profileDirectory != _profile) {
        await _release();
        throw StateError('storage router replacement superseded');
      }
      _available = true;
      _changes.add(null);
    }).whenComplete(() => _opening = null);
  }

  /// Dispose owns both the original router and any in-flight replacement.
  /// A failed close remains retryable and can never make this owner available.
  Future<void> close() {
    final pending = _closing;
    if (pending != null) return pending;
    _disposed = true;
    _available = false;
    _epoch++;
    final result = _closing = _enqueue(() async {
      await _release();
      // A paused observer cannot hold up the native ownership release.
      unawaited(_changes.close());
    }).whenComplete(() => _closing = null);
    if (!_changes.isClosed) _changes.add(null);
    return result;
  }
}
