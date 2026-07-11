// Reactions UX brick: the "who reacted" sheet + the "show reactions" display
// preference (chips under bubbles, quick-react bar in the message menu).

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/features/chat/chat_screen.dart';
import 'package:xveil/features/chat/reactors_sheet.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/reactions_visibility_controller.dart';

final _peerId = NodeId(Uint8List.fromList(List.filled(32, 2)));
final _hex = _peerId.hex;

Message _msg(String body) => Message(
      id: 'm-$body',
      conversationId: _hex,
      direction: MessageDirection.incoming,
      body: body,
      timestamp: DateTime(2024, 1, 1, 12, 0),
    );

Widget _host(List<Message> messages,
        {Map<String, Map<String, String>> reactions = const {}}) =>
    ProviderScope(
      overrides: [
        contactProvider(_hex).overrideWith(
          (ref) => Stream.value(
            Contact(nodeId: _peerId, status: ContactStatus.accepted),
          ),
        ),
        messagesProvider(_hex).overrideWith((ref) => Stream.value(messages)),
        reactionsProvider(_hex).overrideWith((ref) => Stream.value(reactions)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: ChatScreen(peerHex: _hex),
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('invertReactions', () {
    test('groups reactor ids per emoji, preserving order', () {
      final out = invertReactions({'a': '👍', 'b': '❤', 'c': '👍'});
      expect(out, {
        '👍': ['a', 'c'],
        '❤': ['b'],
      });
    });

    test('drops cleared (empty-emoji) entries', () {
      expect(invertReactions({'a': ''}), isEmpty);
    });
  });

  group('ShowReactionsController', () {
    test('defaults to true, set(false) flips and persists', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(showReactionsProvider), isTrue);
      await container.read(showReactionsProvider.notifier).set(false);
      expect(container.read(showReactionsProvider), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('show_reactions'), isFalse);
    });
  });

  testWidgets('long-press on a reaction chip lists the reactors', (tester) async {
    await tester.pumpWidget(_host(
      [_msg('hello')],
      reactions: {
        'm-hello': {_hex: '👍'},
      },
    ));
    await tester.pump();
    await tester.pump();

    // The aggregated chip renders under the bubble…
    expect(find.text('👍 1'), findsOneWidget);

    // …and long-pressing it opens the reactor sheet with the resolved name
    // (no alias set → the short node id).
    await tester.longPress(find.text('👍 1'));
    await tester.pumpAndSettle();
    expect(find.text('Reactions'), findsOneWidget);
    // The reactor tile (the app bar shows the same short id, so scope the find).
    expect(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.text(_peerId.short),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the show-reactions toggle hides chips and the quick-react bar',
      (tester) async {
    await tester.pumpWidget(_host(
      [_msg('hello')],
      reactions: {
        'm-hello': {_hex: '👍'},
      },
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('👍 1'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatScreen)),
    );
    await container.read(showReactionsProvider.notifier).set(false);
    await tester.pumpAndSettle();

    // Chips are gone…
    expect(find.text('👍 1'), findsNothing);

    // …and the message menu opens without the quick-react bar.
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    expect(find.text('Copy text'), findsOneWidget);
    expect(find.text('👍'), findsNothing);
  });

  testWidgets('showReactorsSheet renders emoji sections with names',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      home: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () => showReactorsSheet(context, namesByEmoji: const {
              '👍': ['Alice', 'Bob'],
              '❤': ['You'],
            }),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('👍 2'), findsOneWidget);
    expect(find.text('❤ 1'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
  });
}
