import 'dart:typed_data';

import 'package:xveil/core/background_service_lifetime.dart';

/// In-memory native facts/control. Never invokes an Android channel or claims
/// that an unimplemented backend released resources.
class BackgroundResourceBackend {
  bool resourceHeld = false, sealed = false;
  bool refuseAcquire = false, refuseRelease = false, loseReleaseReply = false;
  int acquires = 0, reads = 0, releases = 0, starts = 0, stops = 0;
  int callStarts = 0, presentations = 0;
  Uint8List? lastAvatar;
  _Retirement? _current;
  _Retirement? _lastReleased;

  BackgroundServiceActions actions({bool retirementSupported = true}) =>
      BackgroundServiceActions(
        start: () async {
          if (sealed) throw StateError('synthetic native admission sealed');
          starts++;
          resourceHeld = true;
        },
        stop: () async {
          if (sealed) throw StateError('synthetic native admission sealed');
          stops++;
          resourceHeld = false;
        },
        retire: retirementSupported ? acquire : null,
        callStart:
            ({
              title,
              text,
              hangupAction = false,
              callSession,
              ringing = false,
              microphone = false,
              camera = false,
            }) async {
              if (sealed) throw StateError('synthetic native admission sealed');
              callStarts++;
              resourceHeld = true;
            },
        callPresentation:
            ({required callSession, required callerName, avatar}) async {
              if (sealed) throw StateError('synthetic native admission sealed');
              presentations++;
              lastAvatar = avatar;
              return true;
            },
      );

  Future<BackgroundResourceRetirement> acquire() async {
    acquires++;
    sealed = true;
    if (refuseAcquire) {
      throw StateError('synthetic resource observation refusal');
    }
    resourceHeld = false;
    if (_current == null || _current!.released) {
      _current = _Retirement(this);
    }
    return _current!;
  }
}

class _Retirement implements BackgroundResourceRetirement {
  _Retirement(this.backend);
  final BackgroundResourceBackend backend;
  bool released = false;

  @override
  Future<void> verifyReleasedResources() async {
    backend.reads++;
    if (released ||
        !identical(backend._current, this) ||
        !backend.sealed ||
        backend.resourceHeld) {
      throw StateError('synthetic resource absence unverified');
    }
  }

  @override
  Future<void> releaseAdmission() async {
    backend.releases++;
    if (released) {
      if (identical(backend._lastReleased, this) && !backend.sealed) return;
      throw StateError('synthetic released owner superseded');
    }
    if (!identical(backend._current, this) ||
        !backend.sealed ||
        backend.resourceHeld ||
        backend.refuseRelease) {
      throw StateError('synthetic resource release refusal');
    }
    backend.sealed = false;
    released = true;
    backend._lastReleased = this;
    if (backend.loseReleaseReply) {
      backend.loseReleaseReply = false;
      throw StateError('synthetic released reply lost');
    }
  }
}
