import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_notification_session.dart';

void main() {
  final started = DateTime(2026, 10, 28);
  Map<String, Object?> action(String session, [String kind = 'hangup']) => {
    'action': kind,
    'session': session,
  };

  test(
    'current notification survives capture/status updates in the same call',
    () {
      final session = CallNotificationSession(), owner = Object();
      final token = session.bind(owner, 'call', started);
      expect(session.bind(owner, 'call', started), token);
      for (final kind in ['accept', 'hangup']) {
        expect(
          session.actionFor(
            action(token, kind),
            owner: owner,
            callId: 'call',
            startedAt: started,
          ),
          kind,
        );
      }
    },
  );

  test(
    'old action is refused before the next UI build and after rebinding',
    () {
      final session = CallNotificationSession(), owner = Object();
      final old = action(session.bind(owner, 'old', started));
      final nextStart = started.add(const Duration(seconds: 1));
      expect(
        session.actionFor(
          old,
          owner: owner,
          callId: 'next',
          startedAt: nextStart,
        ),
        isNull,
      );
      final next = session.bind(owner, 'next', nextStart);
      expect(
        session.actionFor(
          old,
          owner: owner,
          callId: 'next',
          startedAt: nextStart,
        ),
        isNull,
      );
      expect(
        session.actionFor(
          action(next),
          owner: owner,
          callId: 'next',
          startedAt: nextStart,
        ),
        'hangup',
      );
    },
  );

  test('identity switch or direct/group change cannot reuse a call scope', () {
    final session = CallNotificationSession(),
        owner = Object(),
        nextOwner = Object();
    final old = session.bind(owner, 'same-remote-call-id', started);
    expect(
      session.actionFor(
        action(old),
        owner: nextOwner,
        callId: 'same-remote-call-id',
        startedAt: started,
      ),
      isNull,
    );
    final next = session.bind(nextOwner, 'same-remote-call-id', started);
    expect(next, isNot(old));
    expect(
      session.actionFor(
        action(old),
        owner: nextOwner,
        callId: 'same-remote-call-id',
        startedAt: started,
      ),
      isNull,
    );
  });

  test('reused remote id at a different start time gets a new scope', () {
    final session = CallNotificationSession(), owner = Object();
    final old = session.bind(owner, 'reused', started);
    final nextStart = started.add(const Duration(microseconds: 1));
    final next = session.bind(owner, 'reused', nextStart);
    expect(next, isNot(old));
    expect(
      session.actionFor(
        action(old),
        owner: owner,
        callId: 'reused',
        startedAt: nextStart,
      ),
      isNull,
    );
  });

  test('clear or bridge recreation cannot restore an old notification', () {
    final session = CallNotificationSession(), owner = Object();
    final old = session.bind(owner, 'call', started);
    session.clear();
    expect(
      session.actionFor(
        action(old),
        owner: owner,
        callId: 'call',
        startedAt: started,
      ),
      isNull,
    );
    expect(session.bind(owner, 'call', started), isNot(old));
    expect(
      CallNotificationSession().actionFor(
        action(old),
        owner: owner,
        callId: 'call',
        startedAt: started,
      ),
      isNull,
    );
  });

  test('unscoped, unknown and malformed action payloads fail closed', () {
    final session = CallNotificationSession(), owner = Object();
    final token = session.bind(owner, 'call', started);
    for (final payload in <Object?>[
      null,
      'hangup',
      'accept',
      {},
      {'action': 'hangup'},
      {'session': token},
      action('wrong'),
      action(token, 'unknown'),
      {'session': token, 'action': 1},
      {'session': 1, 'action': 'accept'},
    ]) {
      expect(
        session.actionFor(
          payload,
          owner: owner,
          callId: 'call',
          startedAt: started,
        ),
        isNull,
      );
    }
    expect(token, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(token, isNot(contains('call')));
  });
}
