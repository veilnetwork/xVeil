// Asking contacts for models, and answering them.
//
// Two properties carry the weight. Answering is the person's choice, because
// the list names the languages this device holds. And an answer is only
// accepted when this device asked for one — otherwise an accepted contact
// could put entries in front of someone who never opened the screen.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/translation_model_store.dart';
import 'package:xveil/state/model_exchange_service.dart';

import 'support/fake_messaging.dart';
import 'support/fake_setting_storage.dart';

void main() {
  late Directory tmp;
  late Directory translateRoot;
  late Directory speechRoot;
  late FakeMessagingForModels messaging;
  late FakeSettingStorage storage;
  late DateTime clock;
  late ModelExchangeService service;

  final peer = NodeId.fromHex('a' * 64);
  final other = NodeId.fromHex('b' * 64);

  ModelExchangeService build() => ModelExchangeService(
    messaging: messaging,
    storage: storage,
    translateRoot: () async => translateRoot,
    speechRoot: () async => speechRoot,
    now: () => clock,
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xveil-exchange');
    translateRoot = Directory('${tmp.path}/translate')..createSync();
    speechRoot = Directory('${tmp.path}/speech')..createSync();
    final pair = Directory('${translateRoot.path}/ru-en')..createSync();
    for (final name in kPairFiles) {
      File('${pair.path}/$name').writeAsStringSync('$name payload');
    }
    messaging = FakeMessagingForModels();
    storage = FakeSettingStorage();
    clock = DateTime.utc(2026, 8, 11, 12);
    service = build();
    addTearDown(service.dispose);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('answering is on out of the box', () async {
    // Default-on and stored as the ABSENCE of a '0'. An existing profile has
    // no such key, and it must land on the documented default rather than on
    // whatever an empty read happens to mean.
    expect(storage.settings.containsKey(kAnswerModelInventoryKey), isFalse);
    expect(await service.answersAutomatically(), isTrue);
  });

  test('a contact who asks is told what is here', () async {
    messaging.onModelInventoryRequest!(peer);
    await pumpEventQueue();
    expect(messaging.offersSent, hasLength(1));
    expect(messaging.offersSent.single.$1.hex, peer.hex);
    expect(messaging.offersSent.single.$2, contains('"from":"ru"'));
    // What must NOT be in it: nothing about this device's filesystem.
    expect(messaging.offersSent.single.$2, isNot(contains(tmp.path)));
  });

  test('turning it off makes this device silent, not empty-handed', () async {
    await service.setAnswersAutomatically(false);
    messaging.onModelInventoryRequest!(peer);
    await pumpEventQueue();
    // Silence, not an empty list: "I have none" and "I do not answer" must look
    // the same from outside, or the setting itself becomes the disclosure.
    expect(messaging.offersSent, isEmpty);
  });

  test('a device with no models is silent for the same reason', () async {
    translateRoot.deleteSync(recursive: true);
    messaging.onModelInventoryRequest!(peer);
    await pumpEventQueue();
    expect(messaging.offersSent, isEmpty);
  });

  test('an answer to a question we asked is surfaced', () async {
    final seen = <PeerModelOffers>[];
    service.answers.listen(seen.add);
    await service.ask([peer]);
    expect(messaging.asked.single.hex, peer.hex);

    messaging.onModelInventoryOffer!(
      peer,
      '[{"kind":"translate","from":"ru","to":"en","bytes":100}]',
    );
    await pumpEventQueue();
    expect(seen, hasLength(1));
    expect(seen.single.offers.single.label, 'ru → en');
  });

  test('an answer nobody asked for is dropped', () async {
    final seen = <PeerModelOffers>[];
    service.answers.listen(seen.add);
    // `other` was never asked. An accepted contact pushing a list unprompted
    // is how a person ends up looking at entries they did not go looking for.
    messaging.onModelInventoryOffer!(
      other,
      '[{"kind":"translate","from":"ru","to":"en","bytes":100}]',
    );
    await pumpEventQueue();
    expect(seen, isEmpty);
  });

  test('an answer that arrives after the window is dropped', () async {
    final seen = <PeerModelOffers>[];
    service.answers.listen(seen.add);
    await service.ask([peer]);
    clock = clock.add(kModelAnswerWindow + const Duration(seconds: 1));
    messaging.onModelInventoryOffer!(
      peer,
      '[{"kind":"translate","from":"ru","to":"en","bytes":100}]',
    );
    await pumpEventQueue();
    expect(seen, isEmpty);
  });

  test('an answer just inside the window is kept', () async {
    // The positive control for the window: without it, "dropped after 91s"
    // would also pass against a service that dropped everything.
    final seen = <PeerModelOffers>[];
    service.answers.listen(seen.add);
    await service.ask([peer]);
    clock = clock.add(kModelAnswerWindow - const Duration(seconds: 1));
    messaging.onModelInventoryOffer!(
      peer,
      '[{"kind":"translate","from":"ru","to":"en","bytes":100}]',
    );
    await pumpEventQueue();
    expect(seen, hasLength(1));
  });

  test('a huge list from a peer is cut to the cap', () async {
    final seen = <PeerModelOffers>[];
    service.answers.listen(seen.add);
    await service.ask([peer]);
    // Real language codes: the parser takes two or three lowercase letters and
    // nothing else, so a generator with digits in it produces rows that are all
    // dropped for being malformed — and the cap would then read as enforced
    // when nothing had reached it.
    String code(int i) =>
        String.fromCharCode(97 + i ~/ 26) + String.fromCharCode(97 + i % 26);
    final rows = [
      for (var i = 0; i < kMaxRowsPerPeer + 40; i++)
        '{"kind":"translate","from":"${code(i)}","to":"zz","bytes":10}',
    ];
    messaging.onModelInventoryOffer!(peer, '[${rows.join(',')}]');
    await pumpEventQueue();
    expect(seen.single.offers.length, kMaxRowsPerPeer);
  });

  test('a body that is not JSON is dropped without throwing', () async {
    final seen = <PeerModelOffers>[];
    service.answers.listen(seen.add);
    await service.ask([peer]);
    messaging.onModelInventoryOffer!(peer, 'not json at all');
    await pumpEventQueue();
    expect(seen, isEmpty);
  });

  test('the pending-question table does not grow without bound', () async {
    await service.ask([
      for (var i = 0; i < kMaxAnsweringPeers + 20; i++)
        NodeId.fromHex(i.toRadixString(16).padLeft(64, '0')),
    ]);
    expect(messaging.asked.length, kMaxAnsweringPeers + 20);
    // Every question was sent; what is bounded is what this device REMEMBERS,
    // so a peer cannot grow it by never answering.
    expect(service.debugPendingQuestions, lessThanOrEqualTo(kMaxAnsweringPeers));
  });
}
