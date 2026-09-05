import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/call_log.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/chat_timeline.dart';

/// A call that happened in a conversation belongs in that conversation.
///
/// The journal was already there — encrypted, capped, mirrored between this
/// identity's devices — and had its own screen. What it did not have was a
/// place in the chat, so a missed call left no trace where a person looks: the
/// conversation simply had nothing in it about the call somebody tried to make.
void main() {
  Message msg(String id, int atMs) => Message(
    id: id,
    conversationId: 'c',
    direction: MessageDirection.incoming,
    body: id,
    timestamp: DateTime.fromMillisecondsSinceEpoch(atMs),
  );

  CallLogEntry call(String id, int atMs, {CallLogOutcome? outcome}) =>
      CallLogEntry(
        id: id,
        peerHex: 'aa',
        outgoing: false,
        video: false,
        outcome: outcome ?? CallLogOutcome.missed,
        atMs: atMs,
      );

  List<String> ids(List<ChatTimelineItem> items) => [
    for (final i in items)
      switch (i) {
        ChatMessageItem(:final message) => message.id,
        ChatCallItem(:final call) => call.id,
      },
  ];

  test('a call sits where it happened', () {
    final items = mergeCallsIntoTimeline(
      messages: [msg('m1', 100), msg('m2', 300)],
      calls: [call('c1', 200)],
    );
    expect(ids(items), ['m1', 'c1', 'm2']);
  });

  test('a call newer than every message is kept', () {
    // The one a person opens the chat to see: it just rang and nobody
    // answered. Clipping to the message window at BOTH ends would drop it.
    final items = mergeCallsIntoTimeline(
      messages: [msg('m1', 100)],
      calls: [call('c1', 900)],
    );
    expect(ids(items), ['m1', 'c1']);
  });

  test('calls older than the loaded window stay out of it', () {
    // History is paged. Without this, opening a chat with a year of calls
    // piles them all above the oldest loaded message — with no conversation
    // around them, and pushing what was actually opened off the screen.
    final items = mergeCallsIntoTimeline(
      messages: [msg('m1', 1000), msg('m2', 1100)],
      calls: [call('old', 5), call('c1', 1050)],
    );
    expect(ids(items), ['m1', 'c1', 'm2']);
  });

  test('a conversation whose only history is a call is not empty', () {
    final items = mergeCallsIntoTimeline(
      messages: const [],
      calls: [call('c1', 10), call('c2', 20)],
    );
    expect(ids(items), ['c1', 'c2']);
  });

  test('no calls changes nothing', () {
    final items = mergeCallsIntoTimeline(
      messages: [msg('m1', 1), msg('m2', 2)],
      calls: const [],
    );
    expect(ids(items), ['m1', 'm2']);
  });

  test('a shared millisecond does not shuffle between builds', () {
    final messages = [msg('m1', 500)];
    final calls = [call('c1', 500)];
    final first = ids(mergeCallsIntoTimeline(messages: messages, calls: calls));
    for (var i = 0; i < 5; i++) {
      expect(
        ids(mergeCallsIntoTimeline(messages: messages, calls: calls)),
        first,
        reason: 'the row order changed between two identical builds',
      );
    }
  });

  test('every outcome survives the merge, not just the missed one', () {
    // The chat shows what happened, and "declined" is not "missed".
    final items = mergeCallsIntoTimeline(
      messages: const [],
      calls: [
        for (final o in CallLogOutcome.values)
          call(o.name, 100 + o.index, outcome: o),
      ],
    );
    expect(ids(items), [for (final o in CallLogOutcome.values) o.name]);
  });
}
