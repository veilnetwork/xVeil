import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/features/chat/custom_emoji_controller.dart';
import 'package:xveil/features/chat/mention_composer.dart';
import 'package:xveil/features/chat/message_markdown.dart';
import 'package:xveil/features/chat/message_mentions.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/nickname_peers.dart';

NodeId _id(int byte) => NodeId(Uint8List.fromList(List.filled(32, byte)));

void main() {
  test('canonical mention round-trips node id and a safe DHT hint', () {
    final nodeId = _id(0x2a);
    final encoded = encodeMessageMention(nodeId, dhtName: 'public_name');

    expect(encoded, '@[${nodeId.hex}|public%name]');
    final parsed = parseMessageMentions('hello $encoded!').single;
    expect(parsed.nodeId, nodeId);
    expect(parsed.dhtName, 'public_name');
    expect(parsed.start, 6);
    expect(messageMentionsFallbackText(encoded), '@${nodeId.short}');
    expect(messageMentionsNode(encoded, nodeId), isTrue);
    expect(messageMentionsNode(encoded, _id(0x2b)), isFalse);
    expect(parseFormatted(encoded), [FmtToken(FmtKind.plain, encoded)]);
  });

  test('malformed mentions stay ordinary text', () {
    expect(parseMessageMentions('@[1234]'), isEmpty);
    expect(parseMessageMentions('@[${_id(1).hex}|bad_name]'), isEmpty);
    expect(parseMessageMentions('@[${_id(1).hex}|UPPER]'), isEmpty);
  });

  test('active query supports opening punctuation but rejects e-mail text', () {
    final query = activeMentionQuery(
      'hello (@alice',
      const TextSelection.collapsed(offset: 13),
    );
    expect(query?.query, 'alice');
    expect(query?.start, 7);
    expect(
      activeMentionQuery(
        'mail@example',
        const TextSelection.collapsed(offset: 12),
      ),
      isNull,
    );
    expect(
      activeMentionQuery('', const TextSelection.collapsed(offset: 0)),
      isNull,
    );
  });

  test('composer wire value never contains the local contact alias', () {
    final controller = CustomEmojiEditingController()..text = '@Priv';
    addTearDown(controller.dispose);
    final nodeId = _id(7);
    controller.replaceRangeWithMention(
      0,
      controller.text.length,
      nodeId,
      label: 'Private Alice',
      dhtName: 'alice_public',
    );
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    expect(controller.insertCustomEmoji(Uint8List.fromList([1, 2, 3])), isTrue);

    final wire = controller.toWireValue();
    final token = encodeMessageMention(nodeId, dhtName: 'alice_public');
    expect(wire.body, '$token ☺');
    expect(wire.body, isNot(contains('Private Alice')));
    expect(wire.customEmoji.single.offset, token.length + 1);

    final restored = CustomEmojiEditingController();
    addTearDown(restored.dispose);
    restored.loadWireValue(wire.body, wire.customEmoji);
    expect(restored.mentionNodeHexes, contains(nodeId.hex));
    expect(restored.toWireValue().body, wire.body);
  });

  testWidgets('local alias is selectable but node id is the stored authority', (
    tester,
  ) async {
    final nodeId = _id(9);
    final controller = CustomEmojiEditingController()
      ..text = '@Priv'
      ..selection = const TextSelection.collapsed(offset: 5);
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationsProvider.overrideWith(
            (ref) => Stream.value([
              Conversation(
                peer: Contact(nodeId: nodeId, name: 'Private Alice'),
              ),
            ]),
          ),
          peerNicknameProvider.overrideWith((ref, hex) async => null),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: MentionComposerRegion(
              controller: controller,
              focusNode: focusNode,
              child: TextField(controller: controller, focusNode: focusNode),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('mention-suggestions')), findsOneWidget);
    expect(find.text('@Private Alice'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('mention-choice-${nodeId.hex}')));
    await tester.pump();

    final wire = controller.toWireValue().body;
    expect(wire, contains(nodeId.hex));
    expect(wire, isNot(contains('Private Alice')));
  });

  testWidgets('formatted mention prefers the local contact alias', (
    tester,
  ) async {
    final nodeId = _id(11);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationsProvider.overrideWith(
            (ref) => Stream.value([
              Conversation(
                peer: Contact(nodeId: nodeId, name: 'Saved locally'),
              ),
            ]),
          ),
          peerNicknameProvider.overrideWith(
            (ref, hex) async => const PeerNickname(
              name: 'public_name',
              checkedAtUnix: 1,
              ownerChanged: false,
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: FormattedText(encodeMessageMention(nodeId))),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('@Saved locally'), findsOneWidget);
    expect(find.textContaining(nodeId.hex), findsNothing);
  });

  testWidgets('verified DHT name outranks the node id fallback', (
    tester,
  ) async {
    final nodeId = _id(12);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationsProvider.overrideWith(
            (ref) =>
                Stream.value([Conversation(peer: Contact(nodeId: nodeId))]),
          ),
          peerNicknameProvider.overrideWith(
            (ref, hex) async => const PeerNickname(
              name: 'public_name',
              checkedAtUnix: 1,
              ownerChanged: false,
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: FormattedText(encodeMessageMention(nodeId))),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('@public_name'), findsOneWidget);
    expect(find.text('@${nodeId.short}'), findsNothing);
  });
}
