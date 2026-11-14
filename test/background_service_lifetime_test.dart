import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/background_service_lifetime.dart';

import 'support/background_resource_backend.dart';

void main() {
  test(
    'retirement joins accepted work and permanently seals every old command',
    () async {
      final native = BackgroundResourceBackend();
      final entered = Completer<void>(), release = Completer<void>();
      final actions = BackgroundServiceActions(
        start: () async {
          entered.complete();
          await release.future;
        },
        stop: () async => fail('old stop reached native'),
        retire: native.acquire,
      );
      final starting = actions.start();
      await entered.future;
      final retiring = actions.retireForErasure();
      expect(identical(retiring, actions.retireForErasure()), isTrue);
      await expectLater(
        actions.start(),
        throwsA(isA<BackgroundServiceRetired>()),
      );
      await expectLater(
        actions.stop(),
        throwsA(isA<BackgroundServiceRetired>()),
      );
      await expectLater(
        actions.startCall(),
        throwsA(isA<BackgroundServiceRetired>()),
      );
      await expectLater(
        actions.setCallPresentation(
          callSession: 'fixture',
          callerName: 'Fixture',
        ),
        throwsA(isA<BackgroundServiceRetired>()),
      );
      expect(native.acquires, 0);
      release.complete();
      await starting;
      final owner = await retiring;
      await owner.verifyReleasedResources();
      await owner.releaseAdmission();
      await expectLater(
        actions.start(),
        throwsA(isA<BackgroundServiceRetired>()),
      );
      await expectLater(
        actions.stop(),
        throwsA(isA<BackgroundServiceRetired>()),
      );
      final fresh = native.actions();
      await fresh.start();
      expect(native.starts, 1);
      await expectLater(
        owner.verifyReleasedResources(),
        throwsA(isA<StateError>()),
      );
      await fresh.stop();
    },
  );

  test(
    'reentrant retirement includes the adapter call that requested it',
    () async {
      final native = BackgroundResourceBackend();
      final release = Completer<void>();
      late BackgroundServiceActions actions;
      late Future<BackgroundResourceRetirement> retiring;
      actions = BackgroundServiceActions(
        start: () {
          retiring = actions.retireForErasure();
          return release.future;
        },
        stop: () async {},
        retire: native.acquire,
      );
      final work = actions.start();
      try {
        await Future<void>(() {});
        expect(
          native.acquires,
          0,
          reason: 'accepted adapter work still pending',
        );
      } finally {
        release.complete();
        await work;
        await retiring;
      }
      expect(native.acquires, 1);
    },
  );

  test(
    'call presentation owns its bytes and is joined before retirement',
    () async {
      final native = BackgroundResourceBackend();
      final accepted = Completer<bool>();
      Uint8List? observed;
      final actions = BackgroundServiceActions(
        start: () async {},
        stop: () async {},
        retire: native.acquire,
        callPresentation:
            ({required callSession, required callerName, avatar}) {
              observed = avatar;
              return accepted.future;
            },
      );
      final bytes = Uint8List.fromList([1, 2, 3]);
      final shown = actions.setCallPresentation(
        callSession: 'fixture',
        callerName: 'Fixture',
        avatar: bytes,
      );
      final retiring = actions.retireForErasure();
      bytes[0] = 99;
      expect(observed, [1, 2, 3]);
      expect(native.acquires, 0);
      accepted.complete(true);
      expect(await shown, isTrue);
      await retiring;
      expect(native.acquires, 1);
    },
  );

  test(
    'refused acquisition stays sealed and retry retains one native owner',
    () async {
      final native = BackgroundResourceBackend()..refuseAcquire = true;
      final actions = native.actions();
      await expectLater(actions.retireForErasure(), throwsA(isA<StateError>()));
      await expectLater(
        actions.start(),
        throwsA(isA<BackgroundServiceRetired>()),
      );
      native.refuseAcquire = false;
      final owner = await actions.retireForErasure();
      expect(identical(owner, await actions.retireForErasure()), isTrue);
      expect(native.acquires, 2);
    },
  );

  test(
    'a failed accepted call does not prevent later resource retirement',
    () async {
      final native = BackgroundResourceBackend();
      final actions = BackgroundServiceActions(
        start: () async => throw StateError('synthetic start refusal'),
        stop: () async {},
        retire: native.acquire,
      );
      final starting = actions.start();
      final retiring = actions.retireForErasure();
      await expectLater(starting, throwsA(isA<StateError>()));
      await retiring;
      expect(native.acquires, 1);
    },
  );

  test(
    'missing retirement never substitutes a normal stop or reopens admission',
    () async {
      var stops = 0;
      final actions = BackgroundServiceActions(
        start: () async {},
        stop: () async => stops++,
      );
      await expectLater(
        actions.retireForErasure(),
        throwsA(isA<BackgroundServiceUnavailable>()),
      );
      await expectLater(
        actions.stop(),
        throwsA(isA<BackgroundServiceRetired>()),
      );
      expect(stops, 0);
    },
  );
  test(
    'resource admission seals synchronously even while accepted daemon work waits',
    () async {
      final native = BackgroundResourceBackend();
      final release = Completer<void>();
      var sealed = false;
      final actions = BackgroundServiceActions(
        start: () => release.future,
        stop: () async {},
        retire: native.acquire,
        sealResources: () => sealed = true,
      );
      final start = actions.start();
      final retiring = actions.retireForErasure();
      expect(sealed, isTrue);
      expect(native.acquires, 0);
      release.complete();
      await start;
      await retiring;
    },
  );

  test(
    'resource sealing can reenter retirement without losing ownership',
    () async {
      final native = BackgroundResourceBackend();
      late BackgroundServiceActions actions;
      late Future<BackgroundResourceRetirement> reentrant;
      actions = BackgroundServiceActions(
        start: () async {},
        stop: () async {},
        retire: native.acquire,
        sealResources: () => reentrant = actions.retireForErasure(),
      );
      final retiring = actions.retireForErasure();
      expect(identical(retiring, reentrant), isTrue);
      await retiring;
      expect(native.acquires, 1);
    },
  );
}
