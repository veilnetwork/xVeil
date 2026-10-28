import 'dart:math';

/// Local notification scope. Never a network identifier or an authorization
/// token: Android's one-use capability separately authenticates the button.
class CallNotificationSession {
  Object? _owner;
  String? _callId;
  DateTime? _startedAt;
  String? _session;

  String bind(Object owner, String callId, DateTime startedAt) {
    if (!identical(owner, _owner) ||
        callId != _callId ||
        startedAt != _startedAt) {
      _owner = owner;
      _callId = callId;
      _startedAt = startedAt;
      final rng = Random.secure();
      _session = List.generate(
        32,
        (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
    }
    return _session!;
  }

  void clear() {
    _owner = null;
    _callId = null;
    _startedAt = null;
    _session = null;
  }

  String? actionFor(
    Object? payload, {
    required Object owner,
    required String callId,
    required DateTime startedAt,
  }) {
    if (_session == null ||
        !identical(owner, _owner) ||
        callId != _callId ||
        startedAt != _startedAt ||
        payload is! Map ||
        payload['session'] != _session) {
      return null;
    }
    final action = payload['action'];
    return action == 'accept' || action == 'hangup' ? action as String : null;
  }
}
