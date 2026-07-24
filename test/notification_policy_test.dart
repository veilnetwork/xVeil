import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/state/notifications.dart';

void main() {
  group('shouldAlertIncoming (real-time, background-only)', () {
    test('background → alert', () {
      expect(
        shouldAlertIncoming(enabled: true, muted: false, foreground: false),
        isTrue,
      );
    });
    test('foreground → suppress (shown in-app; surfaced on minimize)', () {
      expect(
        shouldAlertIncoming(enabled: true, muted: false, foreground: true),
        isFalse,
      );
    });
    test('muted → never, even backgrounded', () {
      expect(
        shouldAlertIncoming(enabled: true, muted: true, foreground: false),
        isFalse,
      );
    });
    test('notifications disabled → never', () {
      expect(
        shouldAlertIncoming(enabled: false, muted: false, foreground: false),
        isFalse,
      );
    });
  });

  group('shouldAlertOnMinimize (surface unread when leaving the app)', () {
    test('unread, not muted, not the open chat → alert', () {
      expect(
        shouldAlertOnMinimize(
          enabled: true,
          unread: 2,
          muted: false,
          isActive: false,
        ),
        isTrue,
      );
    });
    test('no unread → no alert', () {
      expect(
        shouldAlertOnMinimize(
          enabled: true,
          unread: 0,
          muted: false,
          isActive: false,
        ),
        isFalse,
      );
    });
    test('the chat you were just reading → no alert', () {
      expect(
        shouldAlertOnMinimize(
          enabled: true,
          unread: 3,
          muted: false,
          isActive: true,
        ),
        isFalse,
      );
    });
    test('muted conversation → no alert', () {
      expect(
        shouldAlertOnMinimize(
          enabled: true,
          unread: 3,
          muted: true,
          isActive: false,
        ),
        isFalse,
      );
    });
    test('notifications disabled → no alert', () {
      expect(
        shouldAlertOnMinimize(
          enabled: false,
          unread: 3,
          muted: false,
          isActive: false,
        ),
        isFalse,
      );
    });
  });

  group('notification burst collapse', () {
    test('all conversations replace the same OS notification', () {
      expect(
        notificationIdForIncomingMessage('peer-a'),
        notificationIdForIncomingMessage('group:peer-b'),
      );
    });

    test('newest candidate is selected independent of list order', () {
      final candidates = [
        (name: 'pinned-old', timestamp: 10),
        (name: 'latest-group', timestamp: 30),
        (name: 'middle-chat', timestamp: 20),
      ];

      expect(
        newestByTimestamp(candidates, (candidate) => candidate.timestamp),
        (name: 'latest-group', timestamp: 30),
      );
      expect(newestByTimestamp(<int>[], (value) => value), isNull);
    });
  });

  group('notification mute levels', () {
    test('mentions-only passes only a canonical self mention', () {
      expect(
        notificationModeAllows(
          NotificationMuteMode.mentionsOnly,
          isMention: true,
        ),
        isTrue,
      );
      expect(
        notificationModeAllows(
          NotificationMuteMode.mentionsOnly,
          isMention: false,
        ),
        isFalse,
      );
    });

    test('all and none remain unconditional', () {
      expect(
        notificationModeAllows(NotificationMuteMode.all, isMention: false),
        isTrue,
      );
      expect(
        notificationModeAllows(NotificationMuteMode.none, isMention: true),
        isFalse,
      );
    });

    test('timed policy expires without a cleanup write', () {
      final now = DateTime.utc(2026, 7, 22, 12);
      final active = NotificationMutePolicy(
        mode: NotificationMuteMode.mentionsOnly,
        until: now.add(const Duration(hours: 8)),
      );
      expect(active.effectiveAt(now), NotificationMuteMode.mentionsOnly);
      expect(
        active.effectiveAt(now.add(const Duration(hours: 9))),
        NotificationMuteMode.all,
      );
    });
  });

  group('notificationContent (hidden/full privacy split)', () {
    const uuidPreview = '📎 3f2b8a54-9c1d-4e7f-8a2b-6d5c4e3f2a1b.opus';

    test('hidden reveals NOTHING sender- or message-derived', () {
      final content = notificationContent(
        mode: NotificationPreview.hidden,
        contactName: 'Alice',
        shortId: 'abcd1234',
        preview: uuidPreview,
        hiddenBody: 'New message',
      );
      expect(content.title, 'xVeil');
      expect(content.body, 'New message');
      expect(content.title.contains('Alice'), isFalse);
      expect(content.title.contains('abcd1234'), isFalse);
      expect(content.body.contains('3f2b8a54'), isFalse);
    });

    test('full shows the saved contact name and the derived preview', () {
      final content = notificationContent(
        mode: NotificationPreview.full,
        contactName: 'Alice',
        shortId: 'abcd1234',
        preview: '🎤 Voice message (0:07)',
        hiddenBody: 'New message',
      );
      expect(content.title, 'Alice');
      expect(content.body, '🎤 Voice message (0:07)');
    });

    test('full without a saved name falls back to the short id', () {
      final content = notificationContent(
        mode: NotificationPreview.full,
        contactName: '  ',
        shortId: 'abcd1234',
        preview: 'hi',
        hiddenBody: 'New message',
      );
      expect(content.title, 'abcd1234');
    });
  });

  group('notification payload routes', () {
    test('community publications open the Space publication surface', () {
      expect(notificationRouteForPayload('space:abc'), '/space/abc/posts');
      expect(notificationPayloadSupportsReply('space:abc'), isFalse);
    });

    test('community discussion alerts open the exact publication thread', () {
      expect(
        notificationRouteForPayload('space-comment:abc:def:7'),
        '/space/abc/comments?post=def%3A7',
      );
      expect(
        notificationPayloadSupportsReply('space-comment:abc:def:7'),
        isFalse,
      );
      expect(notificationRouteForPayload('space-comment:abc'), isNull);
    });

    test('group and direct chat routes retain inline reply support', () {
      expect(notificationRouteForPayload('group:def'), '/group/def');
      expect(notificationRouteForPayload('fedcba'), '/chat/fedcba');
      expect(notificationPayloadSupportsReply('group:def'), isTrue);
      expect(notificationPayloadSupportsReply('fedcba'), isTrue);
      expect(notificationRouteForPayload(''), isNull);
    });

    test('mention payload keeps an exact internal destination', () {
      const route = '/group/abc?msg=def%3A7';
      final payload = notificationMentionPayload(route);
      expect(notificationRouteForPayload(payload), route);
      expect(notificationPayloadSupportsReply(payload), isFalse);
      expect(notificationRouteForPayload('mention:not-base64'), isNull);
    });

    test('public Space mention opens the exact signed publication', () {
      const route = '/space/abc/public-posts?post=def%3A7';
      final payload = notificationMentionPayload(route);
      expect(notificationRouteForPayload(payload), route);
      expect(notificationPayloadSupportsReply(payload), isFalse);
    });
  });

  group('Space discussion notification relevance', () {
    test('all includes every accepted root and none excludes every root', () {
      expect(
        shouldNotifySpaceComment(
          mode: SpaceCommentNotificationMode.all,
          repliesToSelf: false,
          commentsOnOwnPost: false,
        ),
        isTrue,
      );
      expect(
        shouldNotifySpaceComment(
          mode: SpaceCommentNotificationMode.none,
          repliesToSelf: true,
          commentsOnOwnPost: true,
        ),
        isFalse,
      );
    });

    test('focused mode includes direct replies and our publication thread', () {
      expect(
        shouldNotifySpaceComment(
          mode: SpaceCommentNotificationMode.replies,
          repliesToSelf: true,
          commentsOnOwnPost: false,
        ),
        isTrue,
      );
      expect(
        shouldNotifySpaceComment(
          mode: SpaceCommentNotificationMode.replies,
          repliesToSelf: false,
          commentsOnOwnPost: true,
        ),
        isTrue,
      );
      expect(
        shouldNotifySpaceComment(
          mode: SpaceCommentNotificationMode.replies,
          repliesToSelf: false,
          commentsOnOwnPost: false,
        ),
        isFalse,
      );
    });
  });
}
