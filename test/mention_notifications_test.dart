import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/features/chat/chat_actions.dart';
import 'package:xveil/features/chat/mentions_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';

NodeId _id(int byte) => NodeId(Uint8List.fromList(List.filled(32, byte)));

void main() {
  testWidgets('mute level keeps the established duration presets', (
    tester,
  ) async {
    NotificationMuteSelection? result;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await pickNotificationMutePolicy(context);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('notification-mute-mentions-only')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('notification-mute-none')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('notification-mute-mentions-only')),
    );
    await tester.pumpAndSettle();
    for (final label in [
      '30 minutes',
      '1 hour',
      '8 hours',
      '3 days',
      '1 week',
      '1 month',
      'Until I turn it back on',
      'Custom…',
    ]) {
      expect(find.text(label), findsOneWidget);
    }

    final before = DateTime.now();
    await tester.tap(find.text('8 hours'));
    await tester.pumpAndSettle();
    expect(result?.mode, NotificationMuteMode.mentionsOnly);
    expect(
      result!.until.difference(before),
      allOf(
        greaterThanOrEqualTo(const Duration(hours: 8)),
        lessThan(const Duration(hours: 8, minutes: 1)),
      ),
    );
  });

  test('mention inbox is newest-first and retains exact destinations', () {
    final entries = sortMentionInboxEntriesNewestFirst([
      MentionInboxEntry(
        id: 'old',
        kind: MentionSourceKind.direct,
        author: _id(1),
        contextName: 'Alice',
        body: 'old',
        timestampMs: 10,
        route: '/chat/a?msg=old',
      ),
      MentionInboxEntry(
        id: 'new',
        kind: MentionSourceKind.spaceComment,
        author: _id(2),
        contextName: 'Space',
        body: 'new',
        timestampMs: 30,
        route: '/space/s/comments?post=p&comment=c',
      ),
      MentionInboxEntry(
        id: 'middle',
        kind: MentionSourceKind.group,
        author: _id(3),
        contextName: 'Group',
        body: 'middle',
        timestampMs: 20,
        route: '/group/g?msg=m',
      ),
    ]);

    expect([for (final entry in entries) entry.id], ['new', 'middle', 'old']);
    expect(entries.first.route, '/space/s/comments?post=p&comment=c');
  });
}
