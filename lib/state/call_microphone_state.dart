/// Desired capture state belongs to a call, not to a native engine instance.
/// Rebuilding its route must retain a mute chosen after the initial snapshot.
class CallMicrophoneState {
  String? _callId;
  bool _micOn = false;

  void beginCall(String callId, {required bool micOn}) {
    if (_callId == callId) return;
    _callId = callId;
    _micOn = micOn;
  }

  void setMuted(bool muted) {
    if (_callId != null) _micOn = !muted;
  }

  bool belongsToCall(String callId) => _callId == callId;

  bool mutedForCall(String callId) => _callId != callId || !_micOn;

  bool get muted => !_micOn;

  void clear() {
    _callId = null;
    _micOn = false;
  }
}

/// A runtime permission can outlive the bounded call-start preflight. Until
/// its real answer arrives, the audio engine may receive but must not capture.
class CallMicrophonePermission {
  CallMicrophonePermission(Future<bool> permission) {
    result = permission.then((granted) {
      _granted = granted;
      return granted;
    });
  }

  bool _granted = false;
  late final Future<bool> result;

  bool captureMuted(bool requestedMuted) => !_granted || requestedMuted;

  Future<void> applyWhenGranted({
    required bool Function() isCurrent,
    required bool Function() isMuted,
    required void Function(bool muted) apply,
  }) async {
    if (await result && isCurrent()) apply(isMuted());
  }
}
