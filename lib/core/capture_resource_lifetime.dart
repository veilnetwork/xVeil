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

/// Only capture work which must stop under an in-app privacy cover. Ongoing
/// calls keep their separate policy; a screen lock is not a call hangup.
abstract interface class PrivacyCaptureResource implements CaptureResource {
  Future<void> stopForPrivacy();
}

/// Bind before a chooser/permission await. Privacy interruption revokes old
/// admissions without retiring the profile or reopening an old source.
final class CaptureAdmission {
  CaptureAdmission._(this._owner, this._generation);
  final CaptureResourceLifetime _owner;
  final int _generation;
  bool get isActive =>
      !_owner._sealed && _generation == _owner._privacyGeneration;
  bool isActiveFor(CaptureResourceLifetime owner) =>
      identical(_owner, owner) && isActive;
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
  @visibleForTesting
  factory CaptureResourceLifetime.isolatedForTesting() =>
      CaptureResourceLifetime._();
  final _resources = <CaptureResource>{};
  bool _sealed = false;
  int _privacyGeneration = 0;
  Future<CaptureResourceRetirement>? _retiring;
  CaptureResourceRetirement? _owner;

  CaptureAdmission captureAdmission() =>
      CaptureAdmission._(this, _privacyGeneration);

  bool admit(CaptureResource source, {CaptureAdmission? admission}) {
    if (_sealed || (admission != null && !admission.isActiveFor(this))) {
      return false;
    }
    _resources.add(source);
    return true;
  }

  void forget(CaptureResource source) => _resources.remove(source);
  bool get isAdmitting => !_sealed;
  void sealAdmission() => _sealed = true;

  /// Revoke chooser/permission continuations before asking any adapter to stop.
  /// Failed owners remain registered for retry and for strong profile erasure.
  /// New user actions may obtain a fresh admission; old widgets cannot do so.
  Future<void> stopForPrivacy() {
    _privacyGeneration++;
    final stops = <Future<void>>[
      for (final source in _resources.toList())
        if (source is PrivacyCaptureResource)
          Future<void>.sync(source.stopForPrivacy),
    ];
    return Future.wait(stops).then<void>((_) {});
  }

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
