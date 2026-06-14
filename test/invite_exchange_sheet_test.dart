import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/features/contacts/invite_exchange_sheet.dart';

const _inviteA =
    'veil:bootstrap?pk=l/Mxk9sBuZDJh9fAFU/O0a+6vglkoE1bneO0K+OFwgM=&t=tcp://127.0.0.1:9100&a=ed25519&nc=AYX/vg==';
const _inviteB =
    'veil:bootstrap?pk=UmYafaeNyllMnwNeeDbSwuqzZAXlj0YGFwCTiQkCdxo=&t=tcp://127.0.0.1:9101&a=ed25519&nc=AJPSqQ==';
const _nodeIdB =
    '75cb65f33601923fe0ee3b5ec039eec6a1a9b5fd066d5854892d95e0f55eea79';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  testWidgets('renders my invite as a QR', (tester) async {
    await tester.pumpWidget(_host(
      InviteExchangeSheet(myInvite: _inviteA, onAddContact: (_) {}),
    ));
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('Copy my invite'), findsOneWidget);
  });

  testWidgets('parsing a pasted invite fires onAddContact with the peer',
      (tester) async {
    BootstrapInvite? added;
    await tester.pumpWidget(_host(
      InviteExchangeSheet(myInvite: _inviteA, onAddContact: (i) => added = i),
    ));

    await tester.enterText(find.byType(TextField), _inviteB);
    await tester.tap(find.widgetWithText(FilledButton, 'Add contact'));
    await tester.pump();

    expect(added, isNotNull);
    expect(added!.nodeId.hex, _nodeIdB);
  });

  testWidgets('invalid invite shows an error and does not add', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_host(
      InviteExchangeSheet(myInvite: _inviteA, onAddContact: (_) => calls++),
    ));

    await tester.enterText(find.byType(TextField), 'not-an-invite');
    await tester.tap(find.widgetWithText(FilledButton, 'Add contact'));
    await tester.pump();

    expect(calls, 0);
    expect(find.text('That is not a valid xVeil invite'), findsOneWidget);
  });

  testWidgets('hides the QR section when no invite is ready yet',
      (tester) async {
    await tester.pumpWidget(_host(
      InviteExchangeSheet(myInvite: null, onAddContact: (_) {}),
    ));
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('Paste their invite'), findsOneWidget);
  });
}
