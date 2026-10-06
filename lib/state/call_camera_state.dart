/// Camera intent survives replacing a call's native engine and route.
class CallCameraState {
  String? _callId;
  bool _enabled = false;

  void beginCall(String callId, {required bool enabled}) {
    if (_callId == callId) return;
    _callId = callId;
    _enabled = enabled;
  }

  void setEnabled(bool enabled) {
    if (_callId != null) _enabled = enabled;
  }

  bool enabledForCall(String callId) => _callId == callId && _enabled;

  void clear() {
    _callId = null;
    _enabled = false;
  }
}
