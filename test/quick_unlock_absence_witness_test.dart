import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/core/storage_unlock_scope.dart';

import 'support/retirement_secret_store.dart';

class _ReadRefusingStore extends RetirementSecretStore {
  bool refuseReads = false;
  @override
  Future<String?> read(String key, {bool biometric = false}) {
    if (refuseReads) throw StateError('synthetic private failure');
    return super.read(key, biometric: biometric);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final first = 'a' * 64, second = 'b' * 64, other = 'c' * 64;
  late _ReadRefusingStore store;
  late RetirementAuthentication auth;
  QuickUnlockVault vault(String scope) => QuickUnlockVault(store, scope, auth);
  QuickUnlockRetirement retirement() =>
      QuickUnlockRetirement(store, StorageUnlockScopes([first, second]), auth);
  setUp(() {
    store = _ReadRefusingStore();
    auth = RetirementAuthentication();
  });

  test(
    'capture preserves data and serializes only exact OS record addresses',
    () async {
      for (final scope in [first, second, other]) {
        await vault(
          scope,
        ).configure(password: 'synthetic password $scope', system: true);
      }
      final before = Map.of(store.values);
      final owner = retirement();
      final witness = await owner.prepareAbsenceWitness();
      expect(store.values, before);
      expect(witness.scopes.ids, [first, second]);
      expect(witness.protectedKeys.toSet(), {
        for (final key in before.keys)
          if (key.startsWith('true:') && !key.contains(other)) key.substring(5),
      });
      final encoded = witness.encode();
      expect(encoded, isNot(contains('synthetic password')));
      expect(encoded, isNot(contains(other)));
      final decoded = QuickUnlockAbsenceWitness.decode(encoded);
      expect(decoded.scopes.ids, witness.scopes.ids);
      expect(decoded.protectedKeys, witness.protectedKeys);
      await expectLater(
        vault(first).configure(password: 'late', system: true),
        throwsStateError,
      );
      await expectLater(
        vault(second).configure(password: 'late', system: true),
        throwsStateError,
      );
      expect(
        await vault(other).openSystem('fixture'),
        'synthetic password $other',
      );
    },
  );

  test(
    'durable witness callback must settle before the first record removal',
    () async {
      await vault(
        first,
      ).configure(password: 'synthetic password', system: true);
      final before = Map.of(store.values);
      final entered = Completer<QuickUnlockAbsenceWitness>();
      final release = Completer<void>();
      final owner = retirement();
      final pending = owner.retire(
        persistWitness: (witness) async {
          entered.complete(witness);
          await release.future;
        },
      );
      final witness = await Future.any<QuickUnlockAbsenceWitness?>([
        entered.future,
        pending.then((_) => null),
      ]);
      try {
        expect(
          witness,
          isNotNull,
          reason: 'removal must not skip witness persistence',
        );
        expect(store.values, before);
        expect(witness!.protectedKeys, hasLength(1));
        await expectLater(
          witness.verifyAbsent(store),
          throwsA(isA<QuickUnlockRetirementFailure>()),
        );
        expect(store.values, before);
      } finally {
        release.complete();
      }
      await pending;
      store.refuseReads = true;
      await QuickUnlockAbsenceWitness.decode(
        witness.encode(),
      ).verifyAbsent(store);
      expect(store.values, isEmpty);
    },
  );

  test(
    'failed witness persistence preserves every record and permits owned retry',
    () async {
      await vault(
        first,
      ).configure(password: 'synthetic password', system: true);
      final before = Map.of(store.values);
      final owner = retirement();
      String? captured;
      await expectLater(
        owner.retire(
          persistWitness: (witness) async {
            captured = witness.encode();
            throw StateError('synthetic write refusal');
          },
        ),
        throwsA(isA<QuickUnlockRetirementFailure>()),
      );
      expect(store.values, before);
      await expectLater(
        vault(second).configure(password: 'late', system: true),
        throwsStateError,
      );
      await owner.retire(
        persistWitness: (witness) async {
          expect(witness.encode(), captured);
        },
      );
      expect(store.values, isEmpty);
    },
  );

  test(
    'unreadable public metadata refuses capture before persistence/deletion',
    () async {
      await vault(
        second,
      ).configure(password: 'synthetic password', system: true);
      store.values['false:xveil.quick.v1.$first'] = jsonEncode({
        'v': 99,
        'secret': 'fixture',
      });
      final before = Map.of(store.values);
      var persisted = false;
      await expectLater(
        retirement().retire(
          persistWitness: (_) async {
            persisted = true;
          },
        ),
        throwsA(isA<QuickUnlockRetirementFailure>()),
      );
      expect(persisted, isFalse);
      expect(store.values, before);
    },
  );

  test(
    'absent public record never initializes its cipher to capture addresses',
    () async {
      store.refuseReads = true;
      final owner = retirement();
      final witness = await owner.prepareAbsenceWitness();
      expect(witness.protectedKeys, isEmpty);
      await owner.retire();
      await witness.verifyAbsent(store);
      expect(store.reads, 0);
    },
  );

  for (final protected in [false, true]) {
    test(
      'decoded witness preserves a reappearing ${protected ? 'protected' : 'public'} record',
      () async {
        await vault(
          first,
        ).configure(password: 'synthetic password', system: true);
        QuickUnlockAbsenceWitness? witness;
        await retirement().retire(
          persistWitness: (value) async => witness = value,
        );
        final key = protected
            ? 'true:${witness!.protectedKeys.single}'
            : 'false:xveil.quick.v1.$first';
        store.values[key] = 'synthetic reappearing value';
        final before = Map.of(store.values);
        store.refuseReads = true;
        await expectLater(
          QuickUnlockAbsenceWitness.decode(
            witness!.encode(),
          ).verifyAbsent(store),
          throwsA(isA<QuickUnlockRetirementFailure>()),
        );
        expect(store.values, before);
      },
    );
  }

  test(
    'capture seals all scopes before joining an accepted enrollment',
    () async {
      store.heldScope = first;
      store.writeEntered = Completer<void>();
      store.writeRelease = Completer<void>();
      final enrollment = vault(first)
          .configure(password: 'synthetic password', system: true)
          .then<Object?>((_) => null, onError: (Object error) => error);
      await store.writeEntered!.future;
      final owner = retirement();
      var settled = false;
      final capture = owner.prepareAbsenceWitness().then((value) {
        settled = true;
        return value;
      });
      try {
        await expectLater(
          vault(second).configure(password: 'late', system: true),
          throwsStateError,
        );
        expect(settled, isFalse);
      } finally {
        store.writeRelease!.complete();
      }
      expect(await enrollment, isA<StateError>());
      await capture;
      await owner.retire();
      expect(store.values, isEmpty);
    },
  );

  test('witness owns immutable copies', () {
    final supplied = ['xveil.quick.v1.$first.bio.synthetic'];
    final witness = QuickUnlockAbsenceWitness(
      scopes: StorageUnlockScopes([first]),
      protectedKeys: supplied,
    );
    supplied.clear();
    expect(witness.protectedKeys, hasLength(1));
    expect(() => witness.protectedKeys.clear(), throwsUnsupportedError);
    expect(() => witness.scopes.ids.clear(), throwsUnsupportedError);
  });

  test(
    'a protected slot appearing after capture is preserved, not newly authorized',
    () async {
      await vault(
        first,
      ).configure(password: 'synthetic password', system: true);
      final owner = retirement();
      Map<String, String>? changed;
      await expectLater(
        owner.retire(
          persistWitness: (_) async {
            final public = 'false:xveil.quick.v1.$first';
            final record =
                jsonDecode(store.values[public]!) as Map<String, dynamic>;
            record['bioSlot'] = 'replacement';
            store.values[public] = jsonEncode(record);
            store.values['true:xveil.quick.v1.$first.bio.replacement'] =
                'synthetic new credential';
            changed = Map.of(store.values);
          },
        ),
        throwsA(isA<QuickUnlockRetirementFailure>()),
      );
      expect(store.values, changed);
    },
  );

  test('malformed and foreign witness data refuses with a safe error', () {
    final valid = {
      'v': 1,
      'scopes': [first],
      'protected': ['xveil.quick.v1.$first.bio.synthetic'],
    };
    for (final value in <Object?>[
      {},
      {...valid, 'extra': true},
      {...valid, 'v': 1.0},
      {...valid, 'v': 2},
      {...valid, 'scopes': []},
      {
        ...valid,
        'scopes': [first, first],
      },
      {
        ...valid,
        'protected': ['xveil.quick.v1.$other.bio.synthetic'],
      },
      {
        ...valid,
        'protected': ['xveil.quick.v1.$first'],
      },
      {
        ...valid,
        'protected': [
          'xveil.quick.v1.$first.bio.synthetic',
          'xveil.quick.v1.$first.bio.synthetic',
        ],
      },
      {
        ...valid,
        'protected': ['xveil.quick.v1.$first.bio.private path'],
      },
      {
        ...valid,
        'protected': [null],
      },
      {
        ...valid,
        'scopes': [null],
      },
    ]) {
      expect(
        () => QuickUnlockAbsenceWitness.decode(jsonEncode(value)),
        throwsA(
          isA<QuickUnlockRetirementFailure>().having(
            (error) => error.toString(),
            'safe error',
            'QuickUnlockRetirementFailure',
          ),
        ),
      );
    }
    expect(
      () => QuickUnlockAbsenceWitness.decode(
        ' ' * (QuickUnlockAbsenceWitness.maxEncodedBytes + 1),
      ),
      throwsA(isA<QuickUnlockRetirementFailure>()),
    );
  });
}
