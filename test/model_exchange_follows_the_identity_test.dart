// Asking a contact for a model says something about who is asking.
//
// The service was built once with `ref.read` and kept for the session, so
// after an all-online switch — which `_activateOnline` performs with no
// teardown — a question sent from B's screen left over A's pipeline. To the
// contact, A and B answered from the same place, which is precisely what
// separate identities are for. The other direction is quieter and no better:
// B's own pipeline had no handler, so B answered nobody (report17 XV17-H5).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/state/messaging_providers.dart';
import 'package:xveil/state/model_exchange_service.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_messaging.dart';
import 'support/fake_setting_storage.dart';

void main() {
  final peer = NodeId.fromHex('a' * 64);

  late FakeMessagingForModels messagingA;
  late FakeMessagingForModels messagingB;
  late FakeSettingStorage storageA;
  late FakeSettingStorage storageB;
  late ProviderContainer container;
  late void Function() switchToB;

  setUp(() {
    messagingA = FakeMessagingForModels();
    messagingB = FakeMessagingForModels();
    storageA = FakeSettingStorage();
    storageB = FakeSettingStorage();
    var messaging = messagingA;
    var storage = storageA;
    container = ProviderContainer(
      overrides: [
        messagingServiceProvider.overrideWith((ref) => messaging),
        storageProvider.overrideWith((ref) => storage),
      ],
    );
    addTearDown(container.dispose);
    switchToB = () {
      messaging = messagingB;
      storage = storageB;
      container.invalidate(messagingServiceProvider);
      container.invalidate(storageProvider);
    };
  });

  test('the switch moves the service onto the new pipeline', () async {
    final before = container.read(modelExchangeServiceProvider);
    expect(
      messagingA.onModelInventoryRequest,
      isNotNull,
      reason: 'premise: A is answering on its own pipeline',
    );

    switchToB();
    final after = container.read(modelExchangeServiceProvider);

    expect(identical(before, after), isFalse, reason: 'A\'s service survived');
    expect(
      messagingA.onModelInventoryRequest,
      isNull,
      reason: "A's pipeline is still handled after A stopped being shown",
    );
    expect(
      messagingB.onModelInventoryRequest,
      isNotNull,
      reason: 'B answers nobody — the handler is on a pipeline B does not use',
    );
  });

  test('a question asked under B leaves over B', () async {
    container.read(modelExchangeServiceProvider);
    switchToB();
    await container.read(modelExchangeServiceProvider).ask([peer]);

    expect(messagingB.asked, [peer]);
    expect(
      messagingA.asked,
      isEmpty,
      reason:
          "B's question went out over A's transport, tying the two "
          'identities together in front of the contact',
    );
  });

  test('and the answer-contacts switch is the one for this identity', () async {
    await storageA.putSetting(kAnswerModelInventoryKey, '0'); // A declines
    expect(await container.read(answerModelInventoryProvider.future), isFalse);

    switchToB();
    expect(
      await container.read(answerModelInventoryProvider.future),
      isTrue,
      reason: "B's screen showed A's answer setting",
    );

    await container.read(answerModelInventoryProvider.notifier).set(false);
    expect(
      storageB.settings[kAnswerModelInventoryKey],
      '0',
      reason: 'the switch flipped under B wrote into A',
    );
    expect(storageA.settings[kAnswerModelInventoryKey], '0');
  });

  test(
    'a flip that lands after the switch does not move B\'s switch',
    () async {
      // The write goes where it was meant to go — A's setting is A's. What must
      // not happen is B's screen showing A's answer.
      final slow = _SlowSettingStorage();
      var messaging = messagingA;
      var storage = slow as FakeSettingStorage;
      final c = ProviderContainer(
        overrides: [
          messagingServiceProvider.overrideWith((ref) => messaging),
          storageProvider.overrideWith((ref) => storage),
        ],
      );
      addTearDown(c.dispose);

      expect(await c.read(answerModelInventoryProvider.future), isTrue);
      final flipping = c.read(answerModelInventoryProvider.notifier).set(false);

      messaging = messagingB;
      storage = storageB;
      c.invalidate(messagingServiceProvider);
      c.invalidate(storageProvider);
      expect(await c.read(answerModelInventoryProvider.future), isTrue);

      slow.release();
      await flipping;

      expect(
        c.read(answerModelInventoryProvider).value,
        isTrue,
        reason: "A's answer setting was shown as B's",
      );
      expect(slow.settings[kAnswerModelInventoryKey], '0');
    },
  );
  test(
    'an answer already in flight is not sent after the identity moved on',
    () async {
      // report21 XV18-L3. `dispose` detaches the handler, which stops the NEXT
      // request and does nothing about this one: by the time it reaches the
      // send it is several awaits deep — a preference read and two directory
      // scans. So an answer begun under one identity was still delivered after
      // the app had moved to another, telling that contact what the identity
      // the user had left keeps on disk. To the contact, the two answered from
      // the same place, which is precisely what separate identities are for.
      //
      // It was worse than a leak: `_speechRoot` reaches back through the
      // provider `Ref` that built the service, and a `Ref` used after its
      // provider is disposed THROWS — so the parked answer raised out of a
      // messaging callback with nobody to catch it. That is what this test
      // reaches first, which means it pins the check after the preference read
      // and NOT the one before the send: with the throw removed the send is
      // never reached either. The second check stands on the discipline —
      // ask after every await — rather than on this test.
      final slow = _SlowReadStorage();
      slow.settings[kAnswerModelInventoryKey] = '1';
      var messaging = messagingA;
      Object storage = slow;
      final c = ProviderContainer(
        overrides: [
          messagingServiceProvider.overrideWith((ref) => messaging),
          storageProvider.overrideWith((ref) => storage as dynamic),
        ],
      );
      addTearDown(c.dispose);

      c.read(modelExchangeServiceProvider);
      final answering = messagingA.onModelInventoryRequest;
      expect(answering, isNotNull, reason: 'premise: A answers on A');

      // The request arrives, and parks on the preference read.
      answering!(peer);
      await Future<void>.delayed(Duration.zero);
      expect(
        messagingA.offersSent,
        isEmpty,
        reason: 'premise: nothing is sent while the answer is still deciding',
      );

      // The user switches. A's service is disposed under the parked answer.
      messaging = messagingB;
      storage = storageB;
      c.invalidate(messagingServiceProvider);
      c.invalidate(storageProvider);
      c.read(modelExchangeServiceProvider);

      slow.release();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        messagingA.offersSent,
        isEmpty,
        reason: "an answer begun under A was delivered after the app moved to "
            'B, on A pipeline, telling that contact what A holds',
      );
      expect(messagingB.offersSent, isEmpty, reason: 'nor on B');
    },
  );
}

/// A settings store whose READS finish when the test says so.
class _SlowReadStorage extends FakeSettingStorage {
  final _gate = Completer<void>();
  void release() => _gate.complete();

  @override
  Future<String?> getSetting(String key) async {
    await _gate.future;
    return super.getSetting(key);
  }
}

/// A settings store whose writes finish when the test says so.
class _SlowSettingStorage extends FakeSettingStorage {
  final _gate = Completer<void>();
  void release() => _gate.complete();

  @override
  Future<void> putSetting(String key, String value) async {
    await _gate.future;
    return super.putSetting(key, value);
  }
}
