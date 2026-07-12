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

void main() {
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
