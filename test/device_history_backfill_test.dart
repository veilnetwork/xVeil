import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/call_log.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/device_history_ask.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/domain/inline_custom_emoji.dart';
import 'package:xveil/domain/media_object.dart';
import 'package:xveil/state/device_history_backfill.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

HiddenVolumeStorage _storage() {
  final store = FakeKvLogStore();
  return HiddenVolumeStorage(
    ({required password, required bool create}) => store,
  );
}

/// One sent event, with the attachment reference that went with it.
typedef _Sent = ({DeviceSyncEvent event, MediaObject? attachment});

void main() {
  late HiddenVolumeStorage storage;
  late List<_Sent> sent;
  final alice = _id(0xA1);
  final bob = _id(0xB2);

  Future<bool> post(DeviceSyncEvent e, {MediaObject? attachment}) async {
    sent.add((event: e, attachment: attachment));
    return true;
  }

  Future<void> addMessage(
    NodeId peer,
    String id,
    String body, {
    int atMs = 1000,
    String? contentId,
    List<InlineCustomEmoji> emoji = const [],
  }) => storage.appendMessage(
    Message(
      id: id,
      conversationId: peer.hex,
      direction: MessageDirection.incoming,
      body: body,
      timestamp: DateTime.fromMillisecondsSinceEpoch(atMs),
      fileContentId: contentId,
      fileName: contentId == null ? null : 'photo.jpg',
      fileSize: contentId == null ? null : 4096,
      customEmoji: emoji,
    ),
  );

  setUp(() async {
    storage = _storage();
    await storage.open(password: 'pw', createIfMissing: true);
    sent = [];
    await storage.upsertContact(
      Contact(nodeId: alice, name: 'Alice', status: ContactStatus.accepted),
    );
    await storage.upsertContact(
      Contact(nodeId: bob, name: 'Bob', status: ContactStatus.blocked),
    );
  });

  List<DeviceSyncEvent> of(DeviceSyncKind kind) => [
    for (final s in sent)
      if (s.event.kind == kind) s.event,
  ];

  Future<DeviceHistoryReplay> replay(DeviceHistoryAsk ask) =>
      replayHistoryForAsk(
        ask: ask,
        storage: storage,
        post: post,
        // Nothing here is measuring cadence, and a real pause would make every
        // case in this file wait out a timer it does not care about.
        pause: Duration.zero,
      );

  const everything = DeviceHistoryAsk(fromDeviceHex: 'aa');

  test(
    'a full ask carries the conversations, the contacts and the calls',
    () async {
      await addMessage(alice, 'm1', 'first', atMs: 1000);
      await addMessage(alice, 'm2', 'second', atMs: 2000);
      await addMessage(bob, 'm3', 'from bob', atMs: 3000);
      await storage.setReadMarker(alice.hex, 2000);
      await storage.appendCallLogEntry(
        const CallLogEntry(
          id: 'call-1',
          peerHex: 'a1',
          outgoing: true,
          video: false,
          outcome: CallLogOutcome.completed,
          atMs: 5000,
        ),
        cap: 100,
      );

      final report = await replay(everything);

      expect(report.conversations, 2);
      expect(report.messages, 3);
      expect(report.contacts, 2);
      expect(report.calls, 1);
      expect(report.readMarks, 1);
      expect(report.stoppedEarly, isFalse);
      expect(of(DeviceSyncKind.msgMirror).map((e) => e.key), {
        'm1',
        'm2',
        'm3',
      });
    },
  );

  /// THE RULE THAT KEEPS A BACKFILL FROM BEING A ROLLBACK.
  ///
  /// The container records what a contact's status IS and never when it was
  /// decided, so a replay has no honest "when" to carry. Stamped with the wall
  /// clock, every stale value becomes the newest thing the fold has ever seen —
  /// an accepted contact put back to blocked, with nothing to say so. Message
  /// mirrors are the opposite case: keyed by message id, so their real
  /// timestamp conflicts with nothing and IS where the message sits in the
  /// conversation.
  test(
    'contact rows can only fill a gap; message rows keep their real time',
    () async {
      await addMessage(alice, 'm1', 'first', atMs: 1700000000000);
      final before = DateTime.now().millisecondsSinceEpoch;

      await replay(everything);

      for (final e in of(DeviceSyncKind.contactUp)) {
        expect(
          e.tsMs,
          lessThan(before),
          reason:
              'a replayed contact row stamped anywhere near now would beat a '
              'real decision this device made and silently undo it',
        );
        expect(e.tsMs, greaterThan(0));
      }
      expect(
        of(DeviceSyncKind.msgMirror).single.tsMs,
        1700000000000,
        reason: 'a mirror stamped with anything else moves the message in time',
      );
    },
  );

  /// NEWEST FIRST. "The last fifty" means the fifty a person sees on opening
  /// the chat, and `loadMessages` returns oldest-first — so the obvious take()
  /// hands back exactly the wrong end of the conversation.
  test(
    'a bounded ask takes the NEWEST messages of each conversation',
    () async {
      for (var i = 1; i <= 5; i++) {
        await addMessage(alice, 'm$i', 'body $i', atMs: 1000 * i);
      }
      await replay(
        const DeviceHistoryAsk(fromDeviceHex: 'aa', perConversation: 2),
      );
      expect(of(DeviceSyncKind.msgMirror).map((e) => e.key).toList(), [
        'm4',
        'm5',
      ]);
    },
  );

  /// CONTROL for the bound: with no cap every message travels, so the guard
  /// above is measuring the cap and not an empty conversation.
  test('an unbounded ask takes all of them', () async {
    for (var i = 1; i <= 5; i++) {
      await addMessage(alice, 'm$i', 'body $i', atMs: 1000 * i);
    }
    await replay(everything);
    expect(of(DeviceSyncKind.msgMirror), hasLength(5));
  });

  test('a narrowed ask carries only the conversations it named', () async {
    await addMessage(alice, 'm1', 'hers');
    await addMessage(bob, 'm2', 'his');
    final report = await replay(
      DeviceHistoryAsk(fromDeviceHex: 'aa', peers: [alice.hex]),
    );
    expect(report.conversations, 1);
    expect(of(DeviceSyncKind.msgMirror).single.key, 'm1');
    expect(
      of(DeviceSyncKind.contactUp).map((e) => e.key),
      isNot(contains(bob.hex)),
      reason: 'a conversation that was not asked for must not travel either',
    );
  });

  /// CONTACTS ARE NOT A CHOICE. A device holding the messages of a
  /// conversation without the contact behind it refuses the next message that
  /// arrives in it — and, until F54, deleted that message from the mailbox for
  /// the whole family while doing so.
  test(
    'every carried conversation carries its contact AND its status',
    () async {
      await addMessage(bob, 'm1', 'hi');
      await replay(everything);
      final keys = of(DeviceSyncKind.contactUp).map((e) => e.key).toSet();
      expect(keys, contains(bob.hex));
      expect(keys, contains('s:${bob.hex}'));
      final status = of(
        DeviceSyncKind.contactUp,
      ).firstWhere((e) => e.key == 's:${bob.hex}');
      expect(status.payload['status'], 'blocked');
    },
  );

  group('files', () {
    test(
      'asked for → the row carries the reference that unlocks the bytes',
      () async {
        await addMessage(alice, 'm1', '', contentId: 'cid-1');
        await replay(everything);
        final row = sent.firstWhere(
          (s) => s.event.kind == DeviceSyncKind.msgMirror,
        );
        expect(row.event.payload['cid'], 'cid-1');
        expect(row.attachment?.cid, 'cid-1');
      },
    );

    /// Off, the row still travels — a conversation missing every picture is
    /// still the conversation, and dropping the message outright would be a
    /// hole the person was never offered.
    test(
      'not asked for → the row still travels, without the reference',
      () async {
        await addMessage(alice, 'm1', '', contentId: 'cid-1');
        await replay(const DeviceHistoryAsk(fromDeviceHex: 'aa', files: false));
        final row = sent.firstWhere(
          (s) => s.event.kind == DeviceSyncKind.msgMirror,
        );
        expect(row.event.payload['cid'], 'cid-1');
        expect(
          row.attachment,
          isNull,
          reason:
              'no reference means no pull, which is what "not the files" is',
        );
      },
    );
  });

  group('stopping', () {
    test('a cancel stops the walk and the report SAYS it stopped', () async {
      for (var i = 1; i <= 20; i++) {
        await addMessage(alice, 'm$i', 'body $i', atMs: 1000 * i);
      }
      var seen = 0;
      final report = await replayHistoryForAsk(
        ask: everything,
        storage: storage,
        post: post,
        pause: Duration.zero,
        cancelled: () => ++seen > 5,
      );
      expect(report.stoppedEarly, isTrue);
      expect(
        report.messages,
        lessThan(20),
        reason: 'a cancel that carries everything anyway is not a cancel',
      );
    });

    /// A post that does not happen must not be counted. A replay reporting
    /// rows it never sent is the "partial copy that claims to be whole" this
    /// campaign keeps finding.
    test('a post that fails stops, and its row is not counted', () async {
      await addMessage(alice, 'm1', 'one');
      await addMessage(alice, 'm2', 'two');
      final report = await replayHistoryForAsk(
        ask: everything,
        storage: storage,
        post: (e, {attachment}) async => false,
        pause: Duration.zero,
      );
      expect(report.stoppedEarly, isTrue);
      expect(report.messages, 0);
      expect(report.contacts, 0);
    });

    /// CONTROL. Without it the two guards above would also pass on a walk that
    /// never sends anything at all.
    test('nothing in the way → nothing is reported as stopped', () async {
      await addMessage(alice, 'm1', 'one');
      final report = await replay(everything);
      expect(report.stoppedEarly, isFalse);
      expect(report.messages, 1);
    });
  });

  /// The drift this builder was introduced to remove: the archive kept its own
  /// copy of this field list and had already lost the inline custom emoji the
  /// live emit carries.
  test('one mirror builder — inline custom emoji travel', () async {
    const glyph = InlineCustomEmoji(offset: 5, dataB64: 'AAECAw==');
    final mirror = deviceMirrorOf(
      alice.hex,
      Message(
        id: 'm1',
        conversationId: alice.hex,
        direction: MessageDirection.incoming,
        body: 'look $kInlineCustomEmojiFallback',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
        customEmoji: const [glyph],
      ),
    );
    expect(mirror.event.payload['ce'], isNotNull);
    expect(
      parseInlineCustomEmoji(
        'look $kInlineCustomEmojiFallback',
        mirror.event.payload['ce'],
      ),
      hasLength(1),
    );
  });

  /// THE RESPONDER'S WHOLE DECISION. Every refusal here was a way to get this
  /// wrong, and three of them would have been silent.
  group('which asks a device answers', () {
    DeviceSyncEvent askEvent({
      required String by,
      required String to,
      int tsMs = 5000,
    }) => DeviceHistoryAsk(
      fromDeviceHex: to,
    ).toEvent(byDeviceHex: by, tsMs: tsMs);

    test('an ask addressed to me, never served → answer it', () {
      expect(
        historyAskToServe(
          event: askEvent(by: 'bb', to: 'aa'),
          myDeviceHex: 'aa',
          alreadyServedMs: null,
        ),
        isNotNull,
      );
    });

    /// The folded device-sync state is replayed into the appliers on EVERY
    /// bridge build. An answered ask that left no record would be answered
    /// again on every app start — a full history re-posted into the shared log
    /// on every launch, for as long as the row lived.
    test('an ask already served is not served again', () {
      expect(
        historyAskToServe(
          event: askEvent(by: 'bb', to: 'aa', tsMs: 5000),
          myDeviceHex: 'aa',
          alreadyServedMs: 5000,
        ),
        isNull,
      );
    });

    /// CONTROL for the watermark: pressing the button again must work, or
    /// the guard above would also pass on a device that answers nothing ever
    /// again.
    test('a NEWER ask from the same device is served', () {
      expect(
        historyAskToServe(
          event: askEvent(by: 'bb', to: 'aa', tsMs: 5001),
          myDeviceHex: 'aa',
          alreadyServedMs: 5000,
        ),
        isNotNull,
      );
    });

    /// Every device sees this row. Without the address check each of them
    /// answers at once, every one posting a full copy into the same log.
    test('an ask addressed to another device is not mine to answer', () {
      expect(
        historyAskToServe(
          event: askEvent(by: 'bb', to: 'cc'),
          myDeviceHex: 'aa',
          alreadyServedMs: null,
        ),
        isNull,
      );
    });

    test('my own ask, echoed back by the log, is not an ask of me', () {
      expect(
        historyAskToServe(
          event: askEvent(by: 'aa', to: 'aa'),
          myDeviceHex: 'aa',
          alreadyServedMs: null,
        ),
        isNull,
      );
    });

    test('a payload this build cannot act on is refused, not guessed at', () {
      expect(
        historyAskToServe(
          event: const DeviceSyncEvent(
            kind: DeviceSyncKind.historyAsk,
            key: 'bb',
            tsMs: 5000,
            payload: {},
          ),
          myDeviceHex: 'aa',
          alreadyServedMs: null,
        ),
        isNull,
      );
    });

    test('an event of another kind is not an ask', () {
      expect(
        historyAskToServe(
          event: const DeviceSyncEvent(
            kind: DeviceSyncKind.contactUp,
            key: 'bb',
            tsMs: 5000,
            payload: {'from': 'aa'},
          ),
          myDeviceHex: 'aa',
          alreadyServedMs: null,
        ),
        isNull,
      );
    });
  });

  group('the ask itself', () {
    test('a full copy is the smallest payload, and survives a round trip', () {
      const ask = DeviceHistoryAsk(fromDeviceHex: 'deadbeef');
      final back = DeviceHistoryAsk.fromPayload(ask.toPayload())!;
      expect(back.fromDeviceHex, 'deadbeef');
      expect(back.peers, isNull);
      expect(back.perConversation, isNull);
      expect(back.callLog, isTrue);
      expect(back.readMarks, isTrue);
      expect(back.files, isTrue);
    });

    test('a narrowed ask survives a round trip', () {
      const ask = DeviceHistoryAsk(
        fromDeviceHex: 'deadbeef',
        peers: ['aa', 'bb'],
        perConversation: 50,
        callLog: false,
        readMarks: false,
        files: false,
      );
      final back = DeviceHistoryAsk.fromPayload(ask.toPayload())!;
      expect(back.peers, ['aa', 'bb']);
      expect(back.perConversation, 50);
      expect(back.callLog, isFalse);
      expect(back.readMarks, isFalse);
      expect(back.files, isFalse);
    });

    /// An ask that names no target is not a narrower ask — it is a demand
    /// every device in the group would answer at once, each posting a full
    /// copy into the same shared log.
    test('an ask with no target is refused, not widened', () {
      expect(DeviceHistoryAsk.fromPayload(const {}), isNull);
      expect(DeviceHistoryAsk.fromPayload(const {'from': ''}), isNull);
    });

    /// And an ask for an EMPTY set of conversations is refused rather than
    /// read as "all of them": widening it would send a full copy on the
    /// strength of a malformed field.
    test('an ask for no conversations is refused, not widened', () {
      expect(
        DeviceHistoryAsk.fromPayload(const {'from': 'aa', 'peers': <String>[]}),
        isNull,
      );
    });

    test('only the named device answers', () {
      const ask = DeviceHistoryAsk(fromDeviceHex: 'aa');
      expect(ask.asks('aa'), isTrue);
      expect(ask.asks('bb'), isFalse);
    });
  });
}
