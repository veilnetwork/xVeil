import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/profile_prefs_store.dart';

void main() {
  late Directory fixture;
  late File local;
  late _FileOwner owner;
  const original =
      '{"v":1,"e":{"flutter.original":{"t":"String","v":"synthetic"}}}';
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('xveil-owned-prefs-port-');
    local = File('${fixture.path}/xveil.prefs.json')
      ..writeAsStringSync(original);
    owner = _FileOwner(local.path);
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  test('owned absence never falls through to an existing local file', () async {
    final store = await ProfilePreferencesStore.load(
      local.path,
      ownedFile: owner,
    );
    expect(await store.getAll(), isEmpty);
    expect(local.readAsStringSync(), original);
    await store.releaseFile();
    expect(owner.closes, 1);
  });
  test(
    'owned read refusal propagates instead of loading locally or starting empty',
    () async {
      owner.readFailure = StateError('synthetic refusal');
      await expectLater(
        ProfilePreferencesStore.load(local.path, ownedFile: owner),
        throwsStateError,
      );
      expect(local.readAsStringSync(), original);
      expect(owner.reads, 1);
      // A failed loader has not consumed its caller's file owner.
      await owner.close();
    },
  );
  for (final failure in ['false', 'throw']) {
    test('owned write $failure never triggers local file fallback', () async {
      owner.contents = original;
      owner.writeResult = false;
      if (failure == 'throw') {
        owner.writeFailure = StateError('synthetic refusal');
      }
      final store = await ProfilePreferencesStore.load(
        local.path,
        ownedFile: owner,
      );
      final save = store.setValue('String', 'flutter.changed', 'changed');
      if (failure == 'throw') {
        await expectLater(save, throwsStateError);
      } else {
        expect(await save, isFalse);
      }
      expect(owner.writes, hasLength(1));
      expect(
        (jsonDecode(owner.writes.single) as Map)['e'],
        contains('flutter.changed'),
      );
      await store.releaseFile();
      expect(owner.closes, 1);
      expect(local.readAsStringSync(), original);
      expect(File('${local.path}.tmp').existsSync(), isFalse);
    });
  }
  test(
    'startup preserves its read error if closing the file also fails',
    () async {
      const readFailure = ManagedWorkerFailure(
        ManagedWorkerFailureKind.invalid,
        preferencesReadReason: ManagedPreferencesFailureReason.filePermissions,
      );
      owner
        ..readFailure = readFailure
        ..closeFailures = 1;
      final backend = SharedPreferencesStorePlatform.instance;
      await expectLater(
        installProfilePreferences(
          supportDir: fixture.path,
          args: const [],
          environment: const {},
          legacyBackend: InMemorySharedPreferencesStore.empty(),
          openOwnedFile: (_) async => owner,
        ),
        throwsA(same(readFailure)),
      );
      expect(owner.closes, 1);
      expect(owner.writes, isEmpty);
      expect(SharedPreferencesStorePlatform.instance, same(backend));
      expect(local.readAsStringSync(), original);
      await owner.close();
    },
  );

  test('file owner mismatch refuses before any read', () async {
    final wrong = _FileOwner('${fixture.path}/other.json');
    await expectLater(
      ProfilePreferencesStore.load(local.path, ownedFile: wrong),
      throwsStateError,
    );
    expect(wrong.reads, 0);
    expect(local.readAsStringSync(), original);
    await wrong.close();
  });
  test(
    'failed native close is retryable without reviving ordinary writes',
    () async {
      owner.closeFailures = 1;
      final store = await ProfilePreferencesStore.load(
        local.path,
        ownedFile: owner,
      );
      await expectLater(store.releaseFile(), throwsStateError);
      expect(owner.closes, 1);
      expect(
        () => store.setValue('Bool', 'flutter.late', true),
        throwsStateError,
      );
      await store.releaseFile();
      expect(owner.closes, 2);
      expect(owner.writes, isEmpty);
      expect(local.readAsStringSync(), original);
    },
  );
}

class _FileOwner implements ProfilePreferencesFile {
  _FileOwner(this.path);
  @override
  final String path;
  String? contents;
  Object? readFailure, writeFailure;
  bool writeResult = true;
  int reads = 0, closes = 0, closeFailures = 0;
  final writes = <String>[];
  @override
  Future<String?> read() async {
    reads++;
    if (readFailure case final Object error) throw error;
    return contents;
  }

  @override
  Future<bool> write(String contents) async {
    writes.add(contents);
    if (writeFailure case final Object error) throw error;
    return writeResult;
  }

  @override
  Future<void> close() async {
    closes++;
    if (closeFailures > 0) {
      closeFailures--;
      throw StateError('synthetic close refusal');
    }
  }
}
