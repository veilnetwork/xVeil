// A GROUP request in the list must read as what it is, and its confirmation
// must promise only what the act does: it erases on THIS device, and only what
// was asked. The 1:1 wording ("clear your chat", "…and your other devices")
// would be a sentence the act does not keep.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/clear_request.dart';
import 'package:xveil/features/settings/clear_requests_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/messaging_providers.dart';

void main() {
  PendingClearRequest request(String? kind) => PendingClearRequest(
    chatHex: 'a' * 64,
    requesterHex: 'b' * 64,
    atMs: 1,
    seq: 0,
    watermark: {'b' * 64: 1},
    groupKind: kind,
  );

  Future<AppL10n> pump(WidgetTester tester, PendingClearRequest r) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pendingClearRequestsProvider.overrideWith((ref) => Stream.value([r])),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: ClearRequestsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppL10n.of(tester.element(find.byType(ClearRequestsScreen)));
  }

  for (final (kind, label) in [
    (kGroupClearOwn, 'own'),
    (kGroupClearAll, 'all'),
  ]) {
    testWidgets('a group "$label" request wears group wording end to end', (
      tester,
    ) async {
      final l = await pump(tester, request(kind));
      final who = 'b' * 8;
      final title = kind == kGroupClearOwn
          ? l.clearRequestsGroupOwn(who)
          : l.clearRequestsGroupAll(who);
      expect(find.text(title), findsOneWidget);
      expect(find.text(l.clearRequestsFrom(who)), findsNothing);
      expect(find.text(l.clearRequestsGroupBody), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, l.clearRequestsErase));
      await tester.pumpAndSettle();
      expect(
        find.text(
          kind == kGroupClearOwn
              ? l.clearRequestsGroupOwnConfirmTitle
              : l.clearRequestsGroupAllConfirmTitle,
        ),
        findsOneWidget,
      );
      expect(
        find.text(l.clearRequestsConfirmTitle),
        findsNothing,
        reason: 'the 1:1 title says "this chat" — a group request is not one',
      );
      expect(
        find.text(l.clearRequestsConfirmBody),
        findsNothing,
        reason: 'the 1:1 body promises "your other devices" — this does not',
      );
    });
  }

  testWidgets('a 1:1 request keeps its own wording', (tester) async {
    final l = await pump(tester, request(null));
    final who = 'b' * 8;
    expect(find.text(l.clearRequestsFrom(who)), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, l.clearRequestsErase));
    await tester.pumpAndSettle();
    expect(find.text(l.clearRequestsConfirmTitle), findsOneWidget);
  });
}
