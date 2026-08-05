import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/features/settings/storage_settings_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/whisper_model_controller.dart';

/// A [KvLogStore] that reports a chosen slot occupancy — what a real
/// hidden-volume space answers from `HvSpace.stats()`, which no in-memory fake
/// can produce on its own.
class _UtilStore implements KvLogStore {
  _UtilStore(this._utilization, {FakeKvLogStore? inner})
    : _inner = inner ?? FakeKvLogStore();

  final FakeKvLogStore _inner;
  final SlotUtilization? _utilization;

  @override
  SlotUtilization? slotUtilization() => _utilization;

  @override
  int commit(List<KvLogOp> ops) => _inner.commit(ops);
  @override
  Uint8List? get(int namespace, Uint8List key) => _inner.get(namespace, key);
  @override
  Uint8List? readLog(int namespace, int logId) =>
      _inner.readLog(namespace, logId);
  @override
  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) => _inner.iterLogRange(
    namespace: namespace,
    start: start,
    end: end,
    limit: limit,
  );
  @override
  int count(int namespace) => _inner.count(namespace);
  @override
  List<Uint8List> kvKeys(int namespace) => _inner.kvKeys(namespace);
  @override
  int eraseNamespace(int namespace) => _inner.eraseNamespace(namespace);
  @override
  void scrub() => _inner.scrub();
  @override
  Uint8List exportKeys() => _inner.exportKeys();
  @override
  void close() => _inner.close();
}

/// A [MultiSpaceBacking] that answers a DIFFERENT occupancy per hosted space,
/// so a view that reports another space's numbers is visible as such.
class _PerIdBacking implements MultiSpaceBacking {
  _PerIdBacking(this._byId);
  final Map<int, SlotUtilization?> _byId;

  @override
  SlotUtilization? slotUtilization(int id) => _byId[id];

  @override
  int openSpace(Uint8List keys) => throw UnimplementedError();
  @override
  int commit(int id, List<KvLogOp> ops) => throw UnimplementedError();
  @override
  Uint8List? get(int id, int namespace, Uint8List key) =>
      throw UnimplementedError();
  @override
  Uint8List? readLog(int id, int namespace, int logId) =>
      throw UnimplementedError();
  @override
  List<KvLogEntry> iterLogRange(
    int id, {
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) => throw UnimplementedError();
  @override
  int count(int id, int namespace) => throw UnimplementedError();
  @override
  List<Uint8List> kvKeys(int id, int namespace) => throw UnimplementedError();
  @override
  Uint8List exportKeys(int id) => throw UnimplementedError();
  @override
  void scrub(int id) {}
  @override
  void vacuumOrphans(int id) {}
  @override
  void close() {}
}

/// Drive the screen's load to completion.
///
/// `pumpAndSettle` cannot do it: the load awaits the container's real length on
/// the filesystem and the preferences platform channel, and neither turns
/// inside the test's fake-async zone — it would spin the loading indicator
/// until it times out. Alternate real time ([WidgetTester.runAsync]) with
/// frames until the chain of awaits has drained.
Future<void> _settleWithIo(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await tester.pump();
}

/// A container file of EXACTLY [bytes] on disk (sparse — nothing is written).
File _containerOfSize(int bytes) {
  final dir = Directory.systemTemp.createTempSync('xveil_reclaim');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  final f = File('${dir.path}/store.hv');
  final raf = f.openSync(mode: FileMode.write);
  raf.truncateSync(bytes);
  raf.closeSync();
  return f;
}

void main() {
  group('SlotUtilization', () {
    test('the dead share is what compaction would give back', () {
      const u = SlotUtilization(ownedChunks: 100, totalSlots: 400);
      expect(u.liveFraction, 0.25);
      expect(u.deadFraction, 0.75);
    });

    test('an EMPTY container is 0% dead, not 100%', () {
      // The trap: hidden-volume's `utilization_ratio` answers 0.0 for a
      // container with no slots — "there is nothing here", not "everything
      // here is garbage". Inverting it blindly reports a brand-new container
      // as entirely reclaimable and pops the nudge on day one.
      const u = SlotUtilization(ownedChunks: 0, totalSlots: 0);
      expect(u.liveFraction, 0.0);
      expect(u.deadFraction, 0.0);
    });

    test('a fully-live container has nothing to reclaim', () {
      const u = SlotUtilization(ownedChunks: 64, totalSlots: 64);
      expect(u.deadFraction, 0.0);
    });

    test('more owned chunks than slots still clamps to 0% dead', () {
      // Cannot happen through the FFI, but the arithmetic must not produce a
      // NEGATIVE reclaimable size if it ever did.
      const u = SlotUtilization(ownedChunks: 9, totalSlots: 4);
      expect(u.liveFraction, 1.0);
      expect(u.deadFraction, 0.0);
    });
  });

  group('AppController.estimateStorageReclaim', () {
    StorageReclaim estimate({
      required int sizeBytes,
      required int owned,
      required int total,
      bool autoCompact = false,
    }) => AppController.estimateStorageReclaim(
      sizeBytes: sizeBytes,
      utilization: SlotUtilization(ownedChunks: owned, totalSlots: total),
      autoCompactEnabled: autoCompact,
    );

    test('reclaimable bytes are the dead share of the file', () {
      // The stand's shape: 7.0 GB on disk, essentially all of it padding.
      final r = estimate(sizeBytes: 7000000000, owned: 1, total: 1000);
      expect(r.reclaimableBytes, 6993000000);
      expect(r.sizeBytes, 7000000000);
    });

    test('a container with nothing dead reclaims nothing', () {
      final r = estimate(sizeBytes: 33554432, owned: 8, total: 8);
      expect(r.reclaimableBytes, 0);
      expect(r.worthCompacting, isFalse);
    });

    test('the nudge needs BOTH the size floor and a big dead share', () {
      // 20 MiB, 90% dead — over both gates.
      expect(
        estimate(sizeBytes: 20971520, owned: 1, total: 10).worthCompacting,
        isTrue,
      );
      // 20 MiB, but only half dead — under the dead-share gate.
      expect(
        estimate(sizeBytes: 20971520, owned: 1, total: 2).worthCompacting,
        isFalse,
      );
      // 90% dead, but a 4 MiB file — under the size floor, and the padding
      // there is noise however lopsided the ratio looks.
      expect(
        estimate(sizeBytes: 4194304, owned: 1, total: 10).worthCompacting,
        isFalse,
      );
    });

    test('the size floor is 16 MiB INCLUSIVE', () {
      // Pinned as literals, not as `AppController`'s constant: a test that
      // reads the same constant the code does moves with it and proves
      // nothing.
      expect(
        estimate(sizeBytes: 16777216, owned: 1, total: 10).worthCompacting,
        isTrue,
        reason: 'exactly 16 MiB is over the floor',
      );
      expect(
        estimate(sizeBytes: 16777215, owned: 1, total: 10).worthCompacting,
        isFalse,
        reason: 'one byte under 16 MiB is not',
      );
    });

    test('the dead-share gate is two thirds, INCLUSIVE', () {
      // Two thirds is where auto-compaction's "grown 3x past its live size"
      // trigger sits, expressed as a share of dead slots. One live slot in
      // three is exactly it; one in two is under.
      expect(
        estimate(sizeBytes: 20971520, owned: 1, total: 3).worthCompacting,
        isTrue,
        reason: '1 live slot of 3 = two thirds dead, exactly at the gate',
      );
      expect(
        estimate(sizeBytes: 20971520, owned: 2, total: 3).worthCompacting,
        isFalse,
        reason: '2 live slots of 3 = one third dead, well under',
      );
      expect(
        estimate(sizeBytes: 20971520, owned: 34, total: 100).worthCompacting,
        isFalse,
        reason: '66% dead is a hair under two thirds',
      );
    });

    test('auto-compaction being ON suppresses the nudge', () {
      // Nothing to ask for: the next unlock compacts by itself. The figures
      // are still reported — only the unprompted remark goes away.
      final r = estimate(
        sizeBytes: 7000000000,
        owned: 1,
        total: 1000,
        autoCompact: true,
      );
      expect(r.worthCompacting, isFalse);
      expect(r.reclaimableBytes, 6993000000);
    });
  });

  group('the metric reaches the Storage port', () {
    test('an open space reports its container occupancy', () async {
      final storage = HiddenVolumeStorage(
        ({required password, required bool create}) =>
            _UtilStore(const SlotUtilization(ownedChunks: 3, totalSlots: 12)),
      );
      expect(await storage.open(password: 'p', createIfMissing: true), isTrue);

      final u = await storage.containerUtilization();
      expect(u, isNotNull);
      expect(u!.ownedChunks, 3);
      expect(u.totalSlots, 12);
      expect(u.deadFraction, 0.75);
    });

    test('a LOCKED space answers unknown instead of throwing', () async {
      final storage = HiddenVolumeStorage(
        ({required password, required bool create}) =>
            _UtilStore(const SlotUtilization(ownedChunks: 3, totalSlots: 12)),
      );
      // Never opened: the settings screen can be reached before/after a lock,
      // and a readout must not take it down.
      expect(await storage.containerUtilization(), isNull);
    });

    test('a backing that cannot measure reports unknown, not zero', () async {
      final storage = HiddenVolumeStorage(
        ({required password, required bool create}) => FakeKvLogStore(),
      );
      await storage.open(password: 'p', createIfMissing: true);
      expect(await storage.containerUtilization(), isNull);
    });

    test('a multi-space view reports ITS OWN space, not a sibling', () async {
      final backing = SyncWrappedAsyncMultiSpaceBacking(
        _PerIdBacking({
          0: const SlotUtilization(ownedChunks: 1, totalSlots: 100),
          1: const SlotUtilization(ownedChunks: 90, totalSlots: 100),
        }),
      );
      final view0 = AsyncMultiSpaceKvLogStore(backing, 0);
      final view1 = AsyncMultiSpaceKvLogStore(backing, 1);

      expect((await view0.slotUtilization())!.ownedChunks, 1);
      expect((await view1.slotUtilization())!.ownedChunks, 90);
    });
  });

  group('storage settings screen', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<void> pumpScreen(
      WidgetTester tester, {
      required int sizeBytes,
      required SlotUtilization? utilization,
    }) async {
      final file = _containerOfSize(sizeBytes);
      final storage = HiddenVolumeStorage(
        ({required password, required bool create}) => _UtilStore(utilization),
      );
      await storage.open(password: 'p', createIfMissing: true);
      // Deliberately NOT closed in a tearDown: closing reaches the on-disk
      // blob tier, whose real file I/O cannot complete inside the widget
      // test's fake-async zone — the teardown would hang forever. Nothing
      // here holds an OS handle to leak.

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // The screen also hosts the speech-model tile, which resolves the
            // support directory through path_provider — unanswerable in a
            // widget test. Point it at a real temp dir so it settles instead
            // of throwing over the top of what is under test here.
            whisperModelStoreProvider.overrideWithValue(
              WhisperModelStore(supportDirectory: () async => file.parent),
            ),
            storageProvider.overrideWith((ref) => storage),
            deniableBootProvider.overrideWith(
              (ref) => DeniableBootConfig(
                runtimeDir: file.parent.path,
                storePath: file.path,
              ),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: const StorageSettingsScreen(),
          ),
        ),
      );
      await _settleWithIo(tester);
    }

    testWidgets('a bloated container says how much compacting would free', (
      tester,
    ) async {
      // 20 MiB on disk, 1 live slot in 100 → 99% padding.
      await pumpScreen(
        tester,
        sizeBytes: 20971520,
        utilization: const SlotUtilization(ownedChunks: 1, totalSlots: 100),
      );

      // 20971520 * 0.99 = 20761804.8 -> 20761804 B -> 19.8 MB.
      expect(
        find.textContaining('19.8 MB of it can be reclaimed'),
        findsOneWidget,
        reason: 'the size tile carries the reclaimable figure',
      );
      expect(
        find.textContaining('Compacting would free about 19.8 MB'),
        findsOneWidget,
        reason: 'and the nudge names it too',
      );
    });

    testWidgets('a healthy container is NOT nudged', (tester) async {
      // 20 MiB on disk, half of it live — over the size floor but well under
      // the dead-share gate.
      await pumpScreen(
        tester,
        sizeBytes: 20971520,
        utilization: const SlotUtilization(ownedChunks: 50, totalSlots: 100),
      );

      expect(
        find.textContaining('10.0 MB of it can be reclaimed'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Compacting would free about'),
        findsNothing,
        reason: 'half-dead is not worth interrupting anyone over',
      );
    });

    testWidgets('a SMALL container is not nudged however lopsided it is', (
      tester,
    ) async {
      // 4 MiB, 99% padding: the ratio is extreme but the absolute waste is
      // not, and an unlock-time repack is not worth it.
      await pumpScreen(
        tester,
        sizeBytes: 4194304,
        utilization: const SlotUtilization(ownedChunks: 1, totalSlots: 100),
      );

      expect(find.textContaining('can be reclaimed'), findsOneWidget);
      expect(find.textContaining('Compacting would free about'), findsNothing);
    });

    testWidgets('an unmeasurable container shows the size ALONE', (
      tester,
    ) async {
      await pumpScreen(tester, sizeBytes: 20971520, utilization: null);

      expect(find.text('20.0 MB'), findsOneWidget);
      expect(
        find.textContaining('can be reclaimed'),
        findsNothing,
        reason: '"0 B reclaimable" would be a claim we cannot make',
      );
      expect(find.textContaining('Compacting would free about'), findsNothing);
    });

    testWidgets('the nudge opens the ordinary compaction flow, and only on '
        'the user asking', (tester) async {
      await pumpScreen(
        tester,
        sizeBytes: 20971520,
        utilization: const SlotUtilization(ownedChunks: 1, totalSlots: 100),
      );

      // Nothing has been compacted by putting the remark on screen — the file
      // is untouched and no password was asked for.
      expect(find.byType(CompactPasswordDialog), findsNothing);

      await tester.tap(find.textContaining('Compacting would free about'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // dialog transition

      // It asks for the password like the button does; compaction happens only
      // after that is answered.
      expect(find.byType(CompactPasswordDialog), findsOneWidget);
    });
  });
}
