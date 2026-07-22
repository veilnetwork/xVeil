import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/space_recommendation.dart';
import 'package:xveil/features/chat/chat_search.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

Message _msg(String body, {String? fileName}) => Message(
  id: 'm-$body',
  conversationId: 'c',
  direction: MessageDirection.incoming,
  body: body,
  timestamp: DateTime(2026, 7, 9),
  status: MessageStatus.delivered,
  fileName: fileName,
);

void main() {
  group('messageMatchesQuery', () {
    test('matches body case-insensitively', () {
      expect(messageMatchesQuery(_msg('Привет МИР'), 'мир'), isTrue);
      expect(messageMatchesQuery(_msg('hello'), 'ELL'.toLowerCase()), isTrue);
      expect(messageMatchesQuery(_msg('hello'), 'nope'), isFalse);
    });

    test('matches attached file name', () {
      expect(
        messageMatchesQuery(_msg('', fileName: 'Report-2026.PDF'), 'report'),
        isTrue,
      );
    });

    test('never matches service echoes or empty queries', () {
      expect(messageMatchesQuery(_msg('↩︎ echo: {"t":9}'), 'echo'), isFalse);
      expect(messageMatchesQuery(_msg('anything'), ''), isFalse);
    });

    test('searches recommendation display fields without exposing marker', () {
      final body = encodeSpaceRecommendationMessage(
        SpaceRecommendationCard(
          campaignId: 'ab' * 32,
          spaceId: _id(8),
          name: 'Public lab',
          description: 'Open community',
          text: 'Take a look',
          joinCode: 'ticket',
        ),
      );
      final message = _msg(body);
      expect(messageMatchesQuery(message, 'community'), isTrue);
      expect(messageSearchText(message), contains('Public lab'));
      expect(messageSearchText(message), isNot(contains('xveil:')));
    });
  });

  group('searchSnippet', () {
    test('centers on the match with ellipses', () {
      final body = '${'a' * 100}needle${'b' * 100}';
      final s = searchSnippet(body, 'needle');
      expect(s.contains('needle'), isTrue);
      expect(s.startsWith('…'), isTrue);
      expect(s.endsWith('…'), isTrue);
      expect(s.length, lessThan(body.length));
    });

    test('falls back to head when match is not in body', () {
      final s = searchSnippet('short body', 'zzz');
      expect(s, 'short body');
    });
  });

  group('pinned message encode/decode', () {
    test('round-trips id and snippet', () {
      final rec = decodePinned(encodePinned('m1', 'hello world'));
      expect(rec?.id, 'm1');
      expect(rec?.text, 'hello world');
    });

    test('caps a long snippet with an ellipsis', () {
      final rec = decodePinned(encodePinned('m2', 'x' * 500));
      expect(rec!.text.length, lessThan(500));
      expect(rec.text.endsWith('…'), isTrue);
    });

    test('blank / null / corrupt decode to null', () {
      expect(decodePinned(null), isNull);
      expect(decodePinned(''), isNull);
      expect(decodePinned('not json'), isNull);
      expect(decodePinned('{"t":"no id"}'), isNull);
    });
  });

  test('filterConversationsByName matches label and name', () {
    final convos = [
      Conversation(
        peer: Contact(nodeId: _id(1), name: 'Alice'),
      ),
      Conversation(
        peer: Contact(nodeId: _id(2), name: 'Bob'),
      ),
      Conversation(peer: Contact(nodeId: _id(3))),
    ];
    expect(filterConversationsByName(convos, 'ali').length, 1);
    expect(filterConversationsByName(convos, '').length, 3);
    // No name → label falls back to the short node id.
    final shortId = convos.last.peer.label.toLowerCase();
    expect(filterConversationsByName(convos, shortId).isNotEmpty, isTrue);
  });
}
