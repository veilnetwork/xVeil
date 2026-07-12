import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/cloud.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/features/storage/cloud_storage_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/cloud_service.dart';

import 'support/fake_hv_container.dart';

class _Sync implements CloudSyncPort {
  final _changes = StreamController<void>.broadcast();
  final rows = <DeviceSyncRecord>[];

  @override
  NodeId get selfId => NodeId(Uint8List(32)..[0] = 7);

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<NodeId>> members() async => [selfId];

  @override
  Future<List<DeviceSyncRecord>> records() async => [...rows];

  @override
  Future<bool> postItem(CloudItem item) async {
    rows.add((event: item.toEvent(), author: selfId));
    return true;
  }

  @override
  Future<bool> postClaim(CloudReplicaClaim claim) async {
    rows.add((event: claim.toEvent(), author: selfId));
    return true;
  }

  @override
  Future<bool> fetch(String contentId, NodeId holder) async => false;

  @override
  Future<void> close() async => unawaited(_changes.close());
}

Future<void> _pumpTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('personal cloud note opens, edits, and saves through the UI', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = CloudService(
      storage,
      _Sync(),
      contentReceived: const Stream.empty(),
      now: () => DateTime.fromMillisecondsSinceEpoch(1000),
      newId: () => 'note_1',
      integrityChecks: false,
    );
    addTearDown(() {
      unawaited(service.close());
      unawaited(storage.close());
    });
    await service.saveTextNote(title: 'Private note', body: 'first body');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [cloudServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: CloudStorageScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Private note'), findsOneWidget);
    expect(find.byIcon(Icons.note_outlined), findsOneWidget);

    await tester.tap(find.text('Private note'));
    await _pumpTransition(tester);
    expect(find.text('Edit note'), findsOneWidget);
    expect(find.text('first body'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), 'Updated note');
    await tester.enterText(find.byType(TextField).at(1), 'second body');
    await tester.tap(find.text('Save'));
    await _pumpTransition(tester);

    expect(find.text('Updated note'), findsOneWidget);
    final updated = (await service.listItems()).single;
    expect(updated.revision, 2);
    expect(await service.loadTextNote(updated), 'second body');
  });

  testWidgets('note editor exposes a merge choice on a stale revision', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    var clock = 2000;
    final service = CloudService(
      storage,
      _Sync(),
      contentReceived: const Stream.empty(),
      now: () => DateTime.fromMillisecondsSinceEpoch(clock++),
      newId: () => 'note_conflict',
      integrityChecks: false,
    );
    addTearDown(() {
      unawaited(service.close());
      unawaited(storage.close());
    });
    final original = await service.saveTextNote(
      title: 'Conflict note',
      body: 'v1',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cloudServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: CloudStorageScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Conflict note'));
    await _pumpTransition(tester);

    await service.saveTextNote(
      itemId: original.id,
      expectedRevision: original.revision,
      title: 'Conflict note',
      body: 'remote v2',
    );
    await tester.enterText(find.byType(TextField).at(1), 'local draft');
    await tester.tap(find.text('Save'));
    await _pumpTransition(tester);

    expect(find.text('This note changed on another device'), findsOneWidget);
    expect(find.textContaining('remote v2'), findsOneWidget);
    expect(find.text('local draft'), findsWidgets);
    await tester.tap(find.text('Save merged version'));
    await _pumpTransition(tester);

    final merged = (await service.listItems()).single;
    expect(merged.revision, 3);
    expect(await service.loadTextNote(merged), 'local draft');
  });

  testWidgets('personal cloud renders imported file and replication controls', (
    tester,
  ) async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = CloudService(
      storage,
      _Sync(),
      contentReceived: const Stream.empty(),
      now: () => DateTime.fromMillisecondsSinceEpoch(1000),
      newId: () => 'file_1',
      integrityChecks: false,
    );
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    await service.importContent(
      name: 'proof.bin',
      size: bytes.length,
      readRange: (offset, length) async =>
          Uint8List.fromList(bytes.sublist(offset, offset + length)),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [cloudServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: CloudStorageScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Personal cloud'), findsOneWidget);
    expect(find.text('proof.bin'), findsOneWidget);
    expect(find.text('4 B · on this device · 1 verified copy'), findsOneWidget);
    expect(find.textContaining('1 verified copy'), findsOneWidget);
    expect(find.text('Index only'), findsOneWidget);
    expect(find.byIcon(Icons.health_and_safety_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Share with contact'), findsOneWidget);
    await tester.tap(find.text('Share with contact'));
    await tester.pumpAndSettle();
    expect(find.text('No accepted contacts to share with'), findsOneWidget);
  });
}
