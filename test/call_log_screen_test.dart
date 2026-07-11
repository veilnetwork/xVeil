// Call journal screen: renders synced CallLogStore rows (alias, outcome,
// duration, missed tint), the empty state, and live-updates on a new row.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/call_log.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/features/calls/call_log_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/call_log.dart';
import 'package:xveil/state/providers.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

Widget _app(HiddenVolumeStorage storage) => ProviderScope(
      overrides: [storageProvider.overrideWithValue(storage)],
      child: const MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: CallLogScreen(),
      ),
    );

void main() {
  testWidgets('empty state, then rows render with alias/outcome/duration and '
      'the screen live-updates when a (mirrored) row lands', (tester) async {
    // The widget-test surface is short — give the list room.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final storage = HiddenVolumeStorage(_mem());
    await storage.open(password: 'p', createIfMissing: true);
    final peer = _id(2);
    await storage.upsertContact(
        Contact(nodeId: peer, name: 'Алиса', status: ContactStatus.accepted));

    await tester.pumpWidget(_app(storage));
    await tester.pumpAndSettle();
    expect(find.text('No calls yet'), findsOneWidget);

    // Reach the SAME store instance the screen watches via its container.
    final el = tester.element(find.byType(CallLogScreen));
    final store = ProviderScope.containerOf(el).read(callLogStoreProvider);
    await store.add(CallLogEntry(
      id: 'c1',
      peerHex: peer.hex,
      outgoing: true,
      video: false,
      outcome: CallLogOutcome.completed,
      atMs: DateTime(2026, 7, 11, 12).millisecondsSinceEpoch,
      durationSec: 75,
    ));
    await store.addMirrored(CallLogEntry(
      id: 'c2',
      peerHex: peer.hex,
      outgoing: false,
      video: true,
      outcome: CallLogOutcome.missed,
      atMs: DateTime(2026, 7, 11, 13).millisecondsSinceEpoch,
    ));
    await tester.pumpAndSettle();

    expect(find.text('No calls yet'), findsNothing);
    expect(find.text('Алиса'), findsNWidgets(2), reason: 'alias resolves');
    expect(find.text('1:15'), findsOneWidget, reason: 'talk duration');
    expect(find.text('Missed'), findsOneWidget);
    expect(find.byIcon(Icons.call_missed), findsOneWidget);
    expect(find.byIcon(Icons.call_made), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
  });
}
