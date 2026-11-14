import 'dart:async';

import 'package:meta/meta.dart';

final class CaptureResourceRetirementFailure implements Exception {
  const CaptureResourceRetirementFailure();
  @override
  String toString() => 'CaptureResourceRetirementFailure';
}

/// An owned source must forget itself only after its accepted work and known
/// platform releases have settled. A timed-out stop is not retirement.
abstract interface class CaptureResource {
  Future<void> retire();
}

final class CaptureResourceRetirement {
  CaptureResourceRetirement._(this._owner);
  final CaptureResourceLifetime _owner;
  bool _released = false;

  Future<void> verifyReleasedResources() async {
    if (_released || !_owner._sealed || _owner._resources.isNotEmpty) {
      throw const CaptureResourceRetirementFailure();
    }
  }

  void releaseAdmission() {
    if (_released) return;
    if (!_owner._sealed ||
        _owner._resources.isNotEmpty ||
        !identical(CaptureResourceLifetime._current, _owner)) {
      throw const CaptureResourceRetirementFailure();
    }
    CaptureResourceLifetime._current = CaptureResourceLifetime._();
    _released = true;
  }
}

/// Process-local ownership of registered capture sources. This does not infer
/// absence of unregistered camera/audio backends; those need their own gates.
final class CaptureResourceLifetime {
  CaptureResourceLifetime._();
  static CaptureResourceLifetime _current = CaptureResourceLifetime._();
  static CaptureResourceLifetime current() => _current;
  final _resources = <CaptureResource>{};
  bool _sealed = false;
  Future<CaptureResourceRetirement>? _retiring;
  CaptureResourceRetirement? _owner;

  bool admit(CaptureResource source) {
    if (_sealed) return false;
    _resources.add(source);
    return true;
  }

  void forget(CaptureResource source) => _resources.remove(source);
  void sealAdmission() => _sealed = true;

  Future<CaptureResourceRetirement> retire() {
    sealAdmission();
    final owner = _owner;
    if (owner != null) return Future.value(owner);
    final pending = _retiring;
    if (pending != null) return pending;
    final result = Completer<CaptureResourceRetirement>();
    _retiring = result.future;
    unawaited(() async {
      try {
        await Future.wait(_resources.toList().map((source) => source.retire()));
        if (_resources.isNotEmpty) {
          throw const CaptureResourceRetirementFailure();
        }
        result.complete(_owner = CaptureResourceRetirement._(this));
      } catch (_) {
        result.completeError(const CaptureResourceRetirementFailure());
      } finally {
        _retiring = null;
      }
    }());
    return result.future;
  }

  @visibleForTesting
  static void resetForTesting() {
    if (_current._resources.isNotEmpty) {
      throw StateError('capture source still owned');
    }
    _current = CaptureResourceLifetime._();
  }
}
