import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/file_download_policy.dart';
import 'package:xveil/features/settings/file_settings_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/messaging.dart';

/// A do-nothing transport — the screen only touches the service's policy, so the
/// service is never started (no retry/content timers to outlive the test).
class _NoTransport implements VeilTransport {
  final _in = StreamController<InboundMessage>.broadcast();
  @override
  Future<NodeId> nodeId() async => NodeId(Uint8List.fromList(List.filled(32, 1)));
  @override
  Stream<InboundMessage> messages() => _in.stream;
  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async {}
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) async {}
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _in.close();
}

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

void main() {
  testWidgets('file settings: shows the active policy and edits persist '
      'per-identity', (tester) async {
    final s = HiddenVolumeStorage(_mem());
    await s.open(password: 'p', createIfMissing: true);
    final t = _NoTransport();
    addTearDown(t.dispose);
    final m = MessagingService(t, s); // not started: no timers in this test
    addTearDown(m.dispose);

    // A tall surface so the LAZY ListView lays out the WHOLE screen — including
    // the blocked-types input at the bottom (an earlier Row/Expanded/button there
    // forced an infinite width that only bit once it was actually laid out, off
    // the 800x600 default viewport).
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [messagingServiceProvider.overrideWithValue(m)],
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: const FileSettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    // Defaults render: the 2 MB auto cap + the executable block list.
    expect(find.text('2 MB'), findsOneWidget);
    expect(find.text('apk'), findsOneWidget);
    expect(find.text('exe'), findsOneWidget);

    // Add a type → applied in-memory AND persisted to this identity's storage.
    await tester.enterText(find.byType(TextField), 'iso');
    await tester.tap(find.byIcon(Icons.add)); // the add suffix-icon
    await tester.pumpAndSettle();
    expect(m.fileDownloadPolicy.blockedExts, contains('iso'));
    expect(find.text('iso'), findsOneWidget);
    final raw = await s.getSetting('file_policy');
    expect(raw, isNotNull, reason: 'setFileDownloadPolicy persisted via putSetting');
    expect(
        FileDownloadPolicy.fromJson(jsonDecode(raw!) as Map<String, dynamic>)
            .blockedExts,
        contains('iso'),
        reason: 'survives a reload from storage');

    // Change the limit via the preset dialog → "Always ask" (offer everything).
    await tester.tap(find.text('2 MB'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Always ask'));
    await tester.pumpAndSettle();
    expect(m.fileDownloadPolicy.autoMaxBytes, 0);
    expect(find.text('Always ask'), findsOneWidget);
  });
}
