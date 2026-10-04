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
