import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/state/model_exchange_service.dart';

import 'support/fake_messaging.dart';
import 'support/fake_setting_storage.dart';

class _Messaging extends FakeMessagingForModels {
  Future<void> Function(NodeId peer)? onAsk;
  @override
  Future<void> sendModelInventoryRequest(NodeId peer) async {
    await super.sendModelInventoryRequest(peer);
    await onAsk?.call(peer);
  }
}

Map<String, Object> _translation(String from, String to, [int bytes = 100]) => {
  'kind': 'translate',
  'from': from,
  'to': to,
  'bytes': bytes,
};

String _code(int i) =>
    String.fromCharCode(97 + i ~/ 26) + String.fromCharCode(97 + i % 26);

void main() {
  final peer = NodeId.fromHex('a' * 64);
  final other = NodeId.fromHex('b' * 64);
  late _Messaging messaging;
  late ModelExchangeService service;
  late DateTime clock;
  late List<PeerModelOffers> seen;
  setUp(() {
    messaging = _Messaging();
    clock = DateTime.utc(2026, 10, 29);
    service = ModelExchangeService(
      messaging: messaging,
      storage: FakeSettingStorage(),
      translateRoot: () async => null,
      speechRoot: () async => null,
      now: () => clock,
    );
    seen = [];
    service.answers.listen(seen.add);
    addTearDown(service.dispose);
  });
  void answer(NodeId from, List<Map<String, Object>> rows) =>
      messaging.onModelInventoryOffer!(from, jsonEncode(rows));

  test(
    'catalogs of sibling devices accumulate under their contact identity',
    () async {
      await service.ask([peer]);
      answer(peer, [_translation('ru', 'en')]);
      await pumpEventQueue();
      final first = seen.single;
      answer(peer, [
        _translation('en', 'ru'),
        {'kind': 'speech', 'bytes': 500},
      ]);
      await pumpEventQueue();
      expect(seen.last.peer, peer);
      expect(seen.last.offers.map((o) => o.label), [
        'en → ru',
        'ru → en',
        'speech',
      ]);
      expect(first.offers.map((o) => o.label), ['ru → en']);
    },
  );

  test(
    'identical metadata is deduplicated without another publication',
    () async {
      await service.ask([peer]);
      final row = _translation('ru', 'en');
      answer(peer, [row, row]);
      await pumpEventQueue();
      expect(seen.single.offers, hasLength(1));
      answer(peer, [row]);
      await pumpEventQueue();
      expect(seen, hasLength(1));
    },
  );

  test(
    'different advertised sizes remain distinct and sort deterministically',
    () async {
      await service.ask([peer]);
      answer(peer, [
        _translation('ru', 'en', 200),
        _translation('ru', 'en', 100),
      ]);
      await pumpEventQueue();
      expect(seen.single.offers.map((o) => o.bytes), [100, 200]);
    },
  );

  test(
    'published snapshots cannot be used to rewrite future results',
    () async {
      await service.ask([peer]);
      answer(peer, [_translation('ru', 'en')]);
      await pumpEventQueue();
      expect(() => seen.single.offers.clear(), throwsUnsupportedError);
      answer(peer, [_translation('en', 'ru')]);
      await pumpEventQueue();
      expect(seen.last.offers, hasLength(2));
    },
  );

  for (final reverse in [false, true]) {
    test(
      'combined catalog cap is deterministic across device order ($reverse)',
      () async {
        await service.ask([peer]);
        final rows = [
          for (var i = 0; i < kMaxRowsPerPeer + 20; i++)
            _translation(_code(i), 'zz'),
        ];
        final fragments = [rows.sublist(0, 26), rows.sublist(26)];
        for (final part in reverse ? fragments.reversed : fragments) {
          answer(peer, part);
          await pumpEventQueue();
          expect(seen.last.offers.length, lessThanOrEqualTo(kMaxRowsPerPeer));
        }
        expect(seen.last.offers.map((o) => o.pair!.from), [
          for (var i = 0; i < kMaxRowsPerPeer; i++) _code(i),
        ]);
      },
    );
  }

  test('a new question starts a fresh catalog for only that contact', () async {
    await service.ask([peer, other]);
    answer(peer, [_translation('ru', 'en')]);
    answer(other, [_translation('de', 'en')]);
    await pumpEventQueue();
    await service.ask([peer]);
    answer(peer, [_translation('en', 'ru')]);
    answer(other, [_translation('fr', 'en')]);
    await pumpEventQueue();
    expect(seen.where((r) => r.peer == peer).last.offers.map((o) => o.label), [
      'en → ru',
    ]);
    expect(seen.where((r) => r.peer == other).last.offers.map((o) => o.label), [
      'de → en',
      'fr → en',
    ]);
  });

  test('expired responses cannot merge into the next question', () async {
    await service.ask([peer]);
    answer(peer, [_translation('ru', 'en')]);
    await pumpEventQueue();
    clock = clock.add(kModelAnswerWindow + const Duration(seconds: 1));
    answer(peer, [_translation('de', 'en')]);
    await pumpEventQueue();
    expect(seen, hasLength(1));
    await service.ask([peer]);
    answer(peer, [_translation('fr', 'en')]);
    await pumpEventQueue();
    expect(seen.last.offers.map((o) => o.label), ['fr → en']);
  });

  test('question retention is bounded before a slow send returns', () async {
    final peers = [
      for (var i = 0; i < kMaxAnsweringPeers + 1; i++)
        NodeId.fromHex(i.toRadixString(16).padLeft(64, '0')),
    ];
    final entered = Completer<void>(), release = Completer<void>();
    messaging.onAsk = (p) async {
      if (p == peers.last) {
        entered.complete();
        await release.future;
      }
    };
    final run = service.ask(peers);
    await entered.future;
    try {
      expect(
        service.debugPendingQuestions,
        lessThanOrEqualTo(kMaxAnsweringPeers),
      );
    } finally {
      release.complete();
      await run;
    }
  });

  test(
    'each question has its own answer window after a slow preceding send',
    () async {
      messaging.onAsk = (p) async {
        if (p == peer) {
          clock = clock.add(kModelAnswerWindow + const Duration(seconds: 1));
        } else {
          answer(p, [_translation('ru', 'en')]);
        }
      };
      await service.ask([peer, other]);
      await pumpEventQueue();
      expect(seen.single.peer, other);
    },
  );

  test(
    'disposing an in-flight question prevents later identity disclosures',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      messaging.onAsk = (p) async {
        if (p == peer) {
          entered.complete();
          await release.future;
        }
      };
      final run = service.ask([peer, other]);
      await entered.future;
      service.dispose();
      release.complete();
      await run;
      expect(messaging.asked, [peer]);
    },
  );

  test('asking a disposed identity sends nothing', () async {
    service.dispose();
    await service.ask([peer]);
    expect(messaging.asked, isEmpty);
  });
}
