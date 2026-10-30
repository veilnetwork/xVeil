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

  /// Permission sheets can outlive the bounded media-start preflight. Capture
  /// still belongs to the same engine and the person's current camera intent.
  Future<void> startWhenGranted({
    required String callId,
    required Future<bool> permission,
    required bool Function() isCurrent,
    required Future<void> Function() start,
  }) async {
    if (!await permission) return;
    if (isCurrent() && enabledForCall(callId)) await start();
  }

  void clear() {
    _callId = null;
    _enabled = false;
  }
}
