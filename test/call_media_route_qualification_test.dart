import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/call_media_route_qualification.dart';

void main() {
  test('warming relay can qualify a later fresh bounded challenge', () async {
    final attempts = List.generate(3, (_) => Completer<bool>());
    var calls = 0;
    var completed = false;
    final result = qualifyCallMediaHandover(
      from: CallTransportKind.p2p,
      to: CallTransportKind.relay,
      stillOwned: () => true,
      qualify: () => attempts[calls++].future,
    ).whenComplete(() => completed = true);
    expect(calls, 1);
    expect(completed, isFalse);
    attempts[0].complete(false);
    await pumpEventQueue();
    expect(calls, 2, reason: 'keep the same candidate while its source warms');
    expect(completed, isFalse);
    attempts[1].complete(false);
    await pumpEventQueue();
    expect(calls, 3);
    expect(completed, isFalse, reason: 'two failures are never qualification');
    attempts[2].complete(true);
    expect(await result, isTrue);
    expect(calls, 3);
  });

  for (final replies in [
    <bool>[true],
    [false, true],
    [false, false, false],
  ]) {
    test(
      'relay attempts stop at success or the fixed bound $replies',
      () async {
        var calls = 0;
        expect(
          await qualifyCallMediaHandover(
            from: CallTransportKind.p2p,
            to: CallTransportKind.relay,
            stillOwned: () => true,
            qualify: () async => replies[calls++],
          ),
          replies.last,
        );
        expect(calls, replies.length);
      },
    );
  }

  test('P2P upgrade retains one short observation', () async {
    var calls = 0;
    expect(
      await qualifyCallMediaHandover(
        from: CallTransportKind.relay,
        to: CallTransportKind.p2p,
        stillOwned: () => true,
        qualify: () async {
          calls++;
          return false;
        },
      ),
      isFalse,
    );
    expect(calls, 1);
  });

  for (final answer in [false, true]) {
    test('retired owner cannot retry or commit after answer=$answer', () async {
      var owned = true;
      var calls = 0;
      final pending = Completer<bool>();
      final result = qualifyCallMediaHandover(
        from: CallTransportKind.p2p,
        to: CallTransportKind.relay,
        stillOwned: () => owned,
        qualify: () {
          calls++;
          return pending.future;
        },
      );
      expect(calls, 1);
      owned = false;
      pending.complete(answer);
      expect(await result, isFalse);
      expect(calls, 1);
    });
  }

  test('candidate already retired never starts a challenge', () async {
    expect(
      await qualifyCallMediaHandover(
        from: CallTransportKind.p2p,
        to: CallTransportKind.relay,
        stillOwned: () => false,
        qualify: () => throw StateError('must not start'),
      ),
      isFalse,
    );
  });

  test('native failure propagates instead of starting extra probes', () async {
    var calls = 0;
    await expectLater(
      qualifyCallMediaHandover(
        from: CallTransportKind.p2p,
        to: CallTransportKind.relay,
        stillOwned: () => true,
        qualify: () async {
          calls++;
          throw StateError('candidate closed');
        },
      ),
      throwsStateError,
    );
    expect(calls, 1);
  });
}
