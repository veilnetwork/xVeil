import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/identity.dart';

enum _Kind { setting, profile, nodeConfig }

extension on _Kind {
  String get key => switch (this) {
    _Kind.setting => 'set:held',
    _Kind.profile => 'identity',
    _Kind.nodeConfig => 'node:config',
  };

  Future<void> write(HiddenVolumeStorage storage, String value) =>
      switch (this) {
        _Kind.setting => storage.putSetting('held', value),
        _Kind.profile => storage.saveProfile(UserProfile(displayName: value)),
        _Kind.nodeConfig => storage.saveNodeConfig(value),
      };

  String decode(String value) => this == _Kind.profile
      ? (jsonDecode(value) as Map)['dn'] as String
      : value;
}

class _Store extends SyncWrappedAsyncKvLogStore {
  _Store(this.raw) : super(raw);
  final FakeKvLogStore raw;
  final entered = Completer<void>();
  final release = Completer<void>();
  String? holdKey;
  bool failNext = false;
  bool closed = false;
  final writes = <String>[];

  @override
  Future<Uint8List?> get(int namespace, Uint8List key) async {
    final value = await super.get(namespace, key);
    if (namespace == Ns.settings && utf8.decode(key) == holdKey) {
      holdKey = null;
      entered.complete();
      await release.future;
    }
    return value;
  }

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    if (closed) throw StateError('closed fixture store');
    if (failNext) {
      failNext = false;
      throw StateError('refused fixture write');
    }
    for (final op in ops.whereType<PutOp>()) {
      if (op.namespace == Ns.settings) writes.add(utf8.decode(op.value));
    }
    return super.commit(ops);
  }

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

String? _read(_Store store, _Kind kind) {
  final value = store.raw.get(
    Ns.settings,
    Uint8List.fromList(utf8.encode(kind.key)),
  );
  return value == null ? null : kind.decode(utf8.decode(value));
}

Future<String> _outcome(Future<void> operation) =>
    operation.then((_) => 'ok', onError: (_) => 'error');

void main() {
  for (final kind in _Kind.values) {
    group(kind.name, () {
      test('concurrent identical settings require one durable write', () async {
        final raw = _Store(FakeKvLogStore());
        final storage = HiddenVolumeStorage.fromAsyncStore(raw);
        addTearDown(storage.close);
        await Future.wait([
          for (var i = 0; i < 16; i++) kind.write(storage, 'value'),
        ]);
        expect(raw.writes.map(kind.decode), ['value']);
        expect(_read(raw, kind), 'value');
      });

      test(
        'same-key writes stay ordered while another key can progress',
        () async {
          final raw = _Store(FakeKvLogStore())..holdKey = kind.key;
          final storage = HiddenVolumeStorage.fromAsyncStore(raw);
          addTearDown(storage.close);
          final first = _outcome(kind.write(storage, 'one'));
          await raw.entered.future;
          final second = _outcome(kind.write(storage, 'two'));
          try {
            await storage.putSetting('independent', 'other');
            expect(await storage.getSetting('independent'), 'other');
          } finally {
            raw.release.complete();
            await Future.wait([first, second]);
          }
          expect([await first, await second], ['ok', 'ok']);
          expect(_read(raw, kind), 'two');
          expect(raw.writes.where((s) => s != 'other').map(kind.decode), [
            'one',
            'two',
          ]);
        },
      );

      test('an earlier failure cannot poison the next setting write', () async {
        final raw = _Store(FakeKvLogStore())..failNext = true;
        final storage = HiddenVolumeStorage.fromAsyncStore(raw);
        addTearDown(storage.close);
        final first = _outcome(kind.write(storage, 'value'));
        final second = _outcome(kind.write(storage, 'value'));
        expect(await first, 'error');
        expect(await second, 'ok');
        expect(_read(raw, kind), 'value');
        expect(raw.writes.map(kind.decode), ['value']);
      });

      test(
        'a suspended setting cannot write into the next opened identity',
        () {
          fakeAsync((time) {
            final a = _Store(FakeKvLogStore());
            final b = _Store(FakeKvLogStore());
            final storage = HiddenVolumeStorage.async(
              ({required password, required create}) async =>
                  utf8.decode(password) == 'a' ? a : b,
            );
            var openedA = false, openedB = false;
            storage.open(password: 'a').then((value) => openedA = value);
            time.flushMicrotasks();
            expect(openedA, isTrue);
            a.holdKey = kind.key;
            String? writeResult;
            _outcome(
              kind.write(storage, 'identity-a-only'),
            ).then((value) => writeResult = value);
            time.flushMicrotasks();
            expect(a.entered.isCompleted, isTrue);
            storage.open(password: 'b').then((value) => openedB = value);
            time.flushMicrotasks();
            a.release.complete();
            time.flushMicrotasks();
            storage.close();
            time.flushMicrotasks();
            expect(openedB, isTrue);
            expect(writeResult, 'ok');
            expect(_read(b, kind), isNull);
            expect(_read(a, kind), 'identity-a-only');
            expect(a.closed && b.closed, isTrue);
          });
        },
      );

      for (final erase in [false, true]) {
        test(
          'accepted setting write drains before ${erase ? 'erase' : 'close'}',
          () {
            fakeAsync((time) {
              final raw = _Store(FakeKvLogStore())..holdKey = kind.key;
              final storage = HiddenVolumeStorage.fromAsyncStore(raw);
              final results = <String>[];
              _outcome(kind.write(storage, 'accepted')).then(results.add);
              time.flushMicrotasks();
              expect(raw.entered.isCompleted, isTrue);
              var maintenanceDone = false;
              final maintenance = erase
                  ? storage.eraseSpace()
                  : storage.close();
              maintenance.then((_) => maintenanceDone = true);
              time.flushMicrotasks();
              final endedBeforeRelease = maintenanceDone;
              _outcome(kind.write(storage, 'refused')).then(results.add);
              time.flushMicrotasks();
              raw.release.complete();
              time.flushMicrotasks();
              if (erase) {
                storage.close();
                time.flushMicrotasks();
              }
              expect(endedBeforeRelease, isFalse);
              expect(maintenanceDone, isTrue);
              expect(results, unorderedEquals(['ok', 'error']));

              expect(_read(raw, kind), erase ? isNull : 'accepted');
              expect(raw.closed, isTrue);
            });
          },
        );
      }
    });
  }
}
