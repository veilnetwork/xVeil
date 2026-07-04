import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/chat_folder.dart';
import 'package:xveil/features/chat/chats_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/folder_panel_controller.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

Conversation _conv(int seed, String name) => Conversation(
  peer: Contact(nodeId: _id(seed), name: name, status: ContactStatus.accepted),
);

/// Pins the panel position without prefs (tests have none).
class _FixedPanel extends FolderPanelController {
  _FixedPanel(this.pos);
  final FolderPanelPosition pos;
  @override
  FolderPanelPosition build() => pos;
}

Widget _host(
  List<Conversation> convos,
  List<ChatFolder> folders, {
  FolderPanelPosition? position,
}) => ProviderScope(
  overrides: [
    conversationsProvider.overrideWith((ref) => Stream.value(convos)),
    chatFoldersProvider.overrideWith((ref) => Stream.value(folders)),
    if (position != null)
      folderPanelPositionProvider.overrideWith(() => _FixedPanel(position)),
  ],
  child: MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: const ChatsScreen(),
  ),
);

void main() {
  final folders = [
    const ChatFolder(
      id: 'f1',
      name: 'Work',
      memberHexes: [
        '0101010101010101010101010101010101010101010101010101010101010101',
      ],
    ),
  ];

  testWidgets('default: left drawer with folders; selecting filters the list', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_conv(1, 'Alice'), _conv(2, 'Bob')], folders),
    );
    await tester.pump();

    // Drawer placement: hamburger present, no top chip bar.
    expect(find.byType(DrawerButton), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);

    await tester.tap(find.byType(DrawerButton));
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(ChatsScreen)));
    expect(find.text(l.chatsFolderAll), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);

    // Selecting a folder closes the drawer, filters the list, and names the
    // active folder in the app bar title.
    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();
    expect(find.text(l.chatsFolderAll), findsNothing); // drawer closed
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsNothing);
    expect(find.text('Work'), findsOneWidget); // app bar title
  });

  testWidgets('top position keeps the chip bar and shows no drawer', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_conv(1, 'Alice')], folders, position: FolderPanelPosition.top),
    );
    await tester.pump();

    expect(find.byType(DrawerButton), findsNothing);
    expect(find.byType(ChoiceChip), findsWidgets); // "All" + folder chips
    expect(find.text('Work'), findsOneWidget);
  });
}
