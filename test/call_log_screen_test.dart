// Call journal screen: renders synced CallLogStore rows (alias, outcome,
// duration, missed tint), the empty state, and live-updates on a new row.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
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

class _UnreadableJournal extends FakeKvLogStore {
  bool refuse = false;

  @override
  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) {
    if (refuse && namespace == Ns.callLog) {
      throw StateError('PRIVATE_JOURNAL_STORAGE_PATH');
    }
    return super.iterLogRange(
      namespace: namespace,
      start: start,
      end: end,
      limit: limit,
    );
  }
}

class _DeferredCallStorage extends HiddenVolumeStorage {
  _DeferredCallStorage(this.rows, this.label) : super(_mem());
  final Future<List<CallLogEntry>> rows;
  final String label;
  int contactLookups = 0;

  @override
  Future<List<CallLogEntry>> callLogEntries() => rows;

  @override
  Future<Contact?> getContact(NodeId id) async {
    contactLookups++;
    return Contact(nodeId: id, name: label, status: ContactStatus.accepted);
  }
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
  for (final priorLoaded in [true, false]) {
    testWidgets(
      'identity switch isolates a ${priorLoaded ? "visible" : "pending"} journal',
      (tester) async {
        final selected = StateProvider<bool>((ref) => false);
        final oldRows = Completer<List<CallLogEntry>>();
        final newRows = Completer<List<CallLogEntry>>();
        final entry = CallLogEntry(
          id: 'prior-private-call',
          peerHex: _id(2).hex,
          outgoing: false,
          video: false,
          outcome: CallLogOutcome.missed,
          atMs: 1000,
        );
        final a = _DeferredCallStorage(
          oldRows.future,
          'PRIOR_IDENTITY_CONTACT',
        );
        final b = _DeferredCallStorage(
          newRows.future,
          'CURRENT_IDENTITY_CONTACT',
        );
        if (priorLoaded) oldRows.complete([entry]);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              storageProvider.overrideWith(
                (ref) => ref.watch(selected) ? b : a,
              ),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: CallLogScreen(),
            ),
          ),
        );
        try {
          await tester.pumpAndSettle();
          expect(
            find.text('PRIOR_IDENTITY_CONTACT'),
            priorLoaded ? findsOneWidget : findsNothing,
          );
          final container = ProviderScope.containerOf(
            tester.element(find.byType(CallLogScreen)),
          );
          container.read(selected.notifier).state = true;
          await tester.pump();
          await tester.pump();
          expect(
            find.text('PRIOR_IDENTITY_CONTACT'),
            findsNothing,
            reason: 'the current identity must never display the prior journal',
          );
          if (!priorLoaded) {
            oldRows.complete([entry]);
            await tester.pumpAndSettle();
            expect(
              b.contactLookups,
              0,
              reason:
                  'a late old read must not resolve contacts in the new identity',
            );
            expect(find.text('PRIOR_IDENTITY_CONTACT'), findsNothing);
          }
          newRows.complete([]);
          await tester.pumpAndSettle();
          expect(find.text('No calls yet'), findsOneWidget);
          expect(find.byIcon(Icons.call_missed), findsNothing);
        } finally {
          if (!oldRows.isCompleted) oldRows.complete([]);
          if (!newRows.isCompleted) newRows.complete([]);
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      },
    );
  }

  testWidgets(
    'journal read failure offers retry without claiming empty history',
    (tester) async {
      final kv = _UnreadableJournal();
      final storage = HiddenVolumeStorage(
        ({required password, required bool create}) => kv,
      );
      await storage.open(password: 'fixture', createIfMissing: true);
      await storage.appendCallLogEntry(
        CallLogEntry(
          id: 'retained-call',
          peerHex: _id(2).hex,
          outgoing: false,
          video: false,
          outcome: CallLogOutcome.missed,
          atMs: 1000,
        ),
        cap: 200,
      );
      try {
        kv.refuse = true;
        await tester.pumpWidget(_app(storage));
        await tester.pumpAndSettle();
        expect(find.text('Could not load call history'), findsOneWidget);
        expect(find.text('No calls yet'), findsNothing);
        expect(
          find.textContaining('PRIVATE_JOURNAL_STORAGE_PATH'),
          findsNothing,
        );
        kv.refuse = false;
        await tester.tap(find.text('Try again'));
        await tester.pumpAndSettle();
        expect(find.text('Could not load call history'), findsNothing);
        expect(find.text('Missed'), findsOneWidget);
        expect(find.byIcon(Icons.call_missed), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await storage.close();
      }
    },
  );

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
  testWidgets(
    'an open journal replaces the sibling placeholder with final duration',
    (tester) async {
      final storage = HiddenVolumeStorage(_mem());
      await storage.open(password: 'p', createIfMissing: true);
      final peer = _id(2);
      await tester.pumpWidget(_app(storage));
      await tester.pumpAndSettle();
      final store = ProviderScope.containerOf(
        tester.element(find.byType(CallLogScreen)),
      ).read(callLogStoreProvider);
      await store.add(
        CallLogEntry(
          id: 'shared-call',
          peerHex: peer.hex,
          outgoing: false,
          video: false,
          outcome: CallLogOutcome.completed,
          atMs: 2000,
          provisional: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Answered on another device'), findsOneWidget);
      expect(find.text('0:00'), findsNothing);
      await store.addMirrored(
        CallLogEntry(
          id: 'shared-call',
          peerHex: peer.hex,
          outgoing: false,
          video: false,
          outcome: CallLogOutcome.completed,
          atMs: 1000,
          durationSec: 75,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Answered on another device'), findsNothing);
      expect(find.text('1:15'), findsOneWidget);
      expect(find.byType(ListTile), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await storage.close();
    },
  );
}
