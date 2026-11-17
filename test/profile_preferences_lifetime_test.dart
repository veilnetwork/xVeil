import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:xveil/data/storage/profile_preferences.dart';
import 'package:xveil/data/storage/profile_prefs_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesStorePlatform original;
  setUp(() {
    original = SharedPreferencesStorePlatform.instance;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => SharedPreferencesStorePlatform.instance = original);

  test(
    'ownership check needs no I/O and never revives a retired backend',
    () async {
      final backend = _GatedStore();
      SharedPreferencesStorePlatform.instance = backend;
      final owner = ProfilePreferencesLifetime.current();
      expect(owner.isCurrent, isTrue);
      expect(backend.reads, 0);
      final replacement = _GatedStore();
      SharedPreferencesStorePlatform.instance = replacement;
      expect(owner.isCurrent, isFalse);
      final fresh = ProfilePreferencesLifetime.current();
      expect(fresh.isCurrent, isTrue);
      expect(replacement.reads, 0);
      await fresh.retire();
      expect(fresh.isCurrent, isFalse);
      SharedPreferencesStorePlatform.instance = backend;
      expect(owner.isCurrent, isFalse);
      expect(backend.reads, 0);
    },
  );

  test(
    'an old preferences reference cannot write into a replacement backend',
    () async {
      final old = await profilePreferences();
      await old.setString('identity', 'old');
      final replacement = InMemorySharedPreferencesStore.empty();
      SharedPreferencesStorePlatform.instance = replacement;
      await expectLater(old.setString('identity', 'late'), throwsStateError);
      expect(await replacement.getAll(), isEmpty);
      final fresh = await profilePreferences();
      expect(fresh.getString('identity'), isNull);
      await fresh.setString('identity', 'fresh');
      expect((await replacement.getAll())['flutter.identity'], 'fresh');
    },
  );

  test(
    'retirement joins admitted writes and permanently rejects late calls',
    () async {
      final backend = _GatedStore();
      SharedPreferencesStorePlatform.instance = backend;
      final owner = ProfilePreferencesLifetime.current();
      final prefs = await owner.preferences;
      backend.writeGate = Completer<bool>();
      final write = prefs.setString('accepted', 'value');
      await backend.writeStarted.future;
      var retired = false;
      final drain = owner.retire().then((_) => retired = true);
      await Future<void>.value();
      expect(retired, isFalse);
      for (final operation in <Future<bool> Function()>[
        () => prefs.setBool('late', true),
        () => prefs.setInt('late', 1),
        () => prefs.setDouble('late', 1.0),
        () => prefs.setString('late', 'late'),
        () => prefs.setStringList('late', ['late']),
        () => prefs.remove('accepted'),
        prefs.clear,
        // ignore: deprecated_member_use
        prefs.commit,
      ]) {
        await expectLater(operation(), throwsStateError);
      }
      await expectLater(prefs.reload(), throwsStateError);
      expect(() => prefs.getString('accepted'), throwsStateError);
      backend.writeGate!.complete(true);
      expect(await write, isTrue);
      await drain;
      expect(retired, isTrue);
      await expectLater(profilePreferences(), throwsStateError);
      expect((await backend.getAll())['flutter.accepted'], 'value');
      expect((await backend.getAll()).containsKey('flutter.late'), isFalse);
    },
  );

  test(
    'a late reload cannot overwrite the replacement lifetime cache',
    () async {
      final backend = _GatedStore();
      SharedPreferencesStorePlatform.instance = backend;
      final old = await profilePreferences();
      backend.readGate = Completer<Map<String, Object>>();
      final reload = old.reload();
      await backend.readStarted.future;
      final freshBackend = _GatedStore();
      SharedPreferencesStorePlatform.instance = freshBackend;
      var exposed = false;
      final freshPending = profilePreferences().then((value) {
        exposed = true;
        return value;
      });
      await Future<void>.value();
      expect(exposed, isFalse);
      backend.readGate!.complete({'flutter.identity': 'retired'});
      await reload;
      final fresh = await freshPending;
      expect(fresh.getString('identity'), isNull);
      expect(freshBackend.reads, greaterThan(0));
      expect(() => old.getKeys(), throwsStateError);
      expect(() => old.containsKey('identity'), throwsStateError);
    },
  );

  test(
    'a pending initial read is joined and cannot expose a retired view',
    () async {
      final backend = _GatedStore()
        ..readGate = Completer<Map<String, Object>>();
      SharedPreferencesStorePlatform.instance = backend;
      final owner = ProfilePreferencesLifetime.current();
      final loading = owner.preferences;
      final rejected = expectLater(loading, throwsStateError);
      await backend.readStarted.future;
      var drained = false;
      final retirement = owner.retire().then((_) => drained = true);
      await Future<void>.value();
      expect(drained, isFalse);
      backend.readGate!.complete({});
      await rejected;
      await retirement;
      expect(drained, isTrue);
    },
  );

  test(
    'failed accepted writes remain failures while retirement still drains',
    () async {
      final backend = _GatedStore();
      SharedPreferencesStorePlatform.instance = backend;
      final prefs = await profilePreferences();
      backend.writeGate = Completer<bool>();
      final save = prefs.setBool('accepted', true);
      final failed = expectLater(save, throwsA(isA<FileSystemException>()));
      final drain = ProfilePreferencesLifetime.current().retire();
      backend.writeGate!.completeError(const FileSystemException('synthetic'));
      await failed;
      await drain;
      expect(await backend.getAll(), isEmpty);
    },
  );

  test(
    'the file backend drains queued writes and cannot recreate a removed file',
    () async {
      final dir = await Directory.systemTemp.createTemp('xveil-prefs-retire-');
      try {
        final file = File('${dir.path}/prefs.json');
        final store = await ProfilePreferencesStore.load(file.path);
        SharedPreferencesStorePlatform.instance = store;
        final prefs = await profilePreferences();
        final saves = [
          prefs.setString('one', '1'),
          prefs.setString('two', '2'),
        ];
        await ProfilePreferencesLifetime.current().retire();
        expect(await Future.wait(saves), [true, true]);
        final raw = await ProfilePreferencesStore.load(file.path);
        expect(
          (await raw.getAll()).keys,
          containsAll(['flutter.one', 'flutter.two']),
        );
        await file.delete();
        expect(
          () => store.setValue('String', 'flutter.late', 'value'),
          throwsStateError,
        );
        expect(() => store.remove('flutter.one'), throwsStateError);
        expect(store.clear, throwsStateError);
        await expectLater(prefs.setString('late', 'value'), throwsStateError);
        expect(file.existsSync(), isFalse);
        expect(File('${file.path}.tmp').existsSync(), isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'reinstating a retired backend does not discard an intermediate drain',
    () async {
      final firstBackend = SharedPreferencesStorePlatform.instance;
      final first = await profilePreferences();
      final middleBackend = _GatedStore();
      SharedPreferencesStorePlatform.instance = middleBackend;
      final middle = await profilePreferences();
      middleBackend.writeGate = Completer<bool>();
      final accepted = middle.setString('accepted', 'middle');
      await middleBackend.writeStarted.future;
      SharedPreferencesStorePlatform.instance = firstBackend;
      await expectLater(profilePreferences(), throwsStateError);
      expect(() => first.getString('accepted'), throwsStateError);
      SharedPreferencesStorePlatform.instance =
          InMemorySharedPreferencesStore.empty();
      var exposed = false;
      final last = profilePreferences().then((value) {
        exposed = true;
        return value;
      });
      await Future<void>.value();
      expect(exposed, isFalse);
      middleBackend.writeGate!.complete(true);
      await accepted;
      expect((await last).getString('accepted'), isNull);
    },
  );

  test('returned lists cannot mutate a later persisted snapshot', () async {
    final dir = await Directory.systemTemp.createTemp('xveil-prefs-snapshot-');
    try {
      final file = File('${dir.path}/prefs.json');
      final store = await ProfilePreferencesStore.load(file.path);
      await store.setValue('StringList', 'flutter.list', <String>['accepted']);
      final exposed = (await store.getAll())['flutter.list'] as List<String>;
      exposed[0] = 'changed';
      expect(await store.setValue('Bool', 'flutter.another', true), isTrue);
      final reopened = await ProfilePreferencesStore.load(file.path);
      expect((await reopened.getAll())['flutter.list'], ['accepted']);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('application preference access uses the bound entry point', () {
    final bypass = RegExp(
      r'\bSharedPreferences\s*\.\s*(?:getInstance|resetStatic|setMockInitialValues|setPrefix)\s*\(',
    );
    final offenders = <String>[];
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') ||
          file.path.replaceAll(Platform.pathSeparator, '/') ==
              'lib/data/storage/profile_preferences.dart') {
        continue;
      }
      final source = file
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      if (bypass.hasMatch(source)) offenders.add(file.path);
    }
    expect(
      offenders,
      isEmpty,
      reason: 'raw singleton references can adopt another backend',
    );
  });

  test(
    'a temporary initialization error can be retried in the same lifetime',
    () async {
      final backend = _GatedStore()
        ..readGate = Completer<Map<String, Object>>();
      SharedPreferencesStorePlatform.instance = backend;
      final first = profilePreferences();
      final failed = expectLater(first, throwsA(isA<FileSystemException>()));
      await backend.readStarted.future;
      backend.readGate!.completeError(const FileSystemException('synthetic'));
      await failed;
      backend.readGate = null;
      final recovered = await profilePreferences();
      expect(await recovered.setBool('recovered', true), isTrue);
      expect((await backend.getAll())['flutter.recovered'], isTrue);
    },
  );

  test('a synchronous acknowledged save retires cleanly', () async {
    SharedPreferencesStorePlatform.instance = _SynchronousStore();
    final owner = ProfilePreferencesLifetime.current();
    final prefs = await owner.preferences;
    expect(await prefs.setBool('accepted', true), isTrue);
    await owner.retire();
    await expectLater(prefs.setBool('late', true), throwsStateError);
  });

  test(
    'an admitted file write owns its string list before the next microtask',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'xveil-prefs-lifetime-',
      );
      try {
        final file = File('${dir.path}/prefs.json');
        final store = await ProfilePreferencesStore.load(file.path);
        final values = <String>['accepted'];
        final write = store.setValue('StringList', 'flutter.list', values);
        values[0] = 'changed';
        expect(await write, isTrue);
        final reopened = await ProfilePreferencesStore.load(file.path);
        expect((await reopened.getAll())['flutter.list'], ['accepted']);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}

class _GatedStore extends InMemorySharedPreferencesStore {
  _GatedStore() : super.empty();
  Completer<bool>? writeGate;
  final writeStarted = Completer<void>();
  Completer<Map<String, Object>>? readGate;
  final readStarted = Completer<void>();
  int reads = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    final gate = writeGate;
    if (gate != null && !await gate.future) return false;
    return super.setValue(valueType, key, value);
  }

  @override
  Future<Map<String, Object>> getAll() async {
    reads++;
    if (!readStarted.isCompleted) readStarted.complete();
    final gate = readGate;
    if (gate != null) return gate.future;
    return super.getAll();
  }
}

class _SynchronousStore extends InMemorySharedPreferencesStore {
  _SynchronousStore() : super.empty();

  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      SynchronousFuture<bool>(true);
}
