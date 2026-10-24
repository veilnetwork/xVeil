import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/document_export.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/features/settings/data_transfer_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/l10n/app_localizations_en.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/cloud_capability_service.dart';
import 'package:xveil/state/cloud_service.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart';

class _App extends AppController {
  bool ours = true;
  @override
  AppState build() => AppState(
    AppPhase.ready,
    identity: Identity(nodeId: NodeId(Uint8List(32))),
  );
  @override
  bool holdsIdentity(IdentityLease lease) => ours && super.holdsIdentity(lease);
}

class _Document implements ExportDocument {
  int writes = 0, aborts = 0;
  final finishing = Completer<void>(), release = Completer<void>();
  @override
  Future<void> write(List<int> bytes) async {
    writes++;
  }

  @override
  Future<void> finish() async {
    finishing.complete();
    await release.future;
  }

  @override
  Future<void> abort() async {
    aborts++;
  }
}

void main() {
  final l = AppL10nEn();
  late ProviderContainer container;
  late _App app;
  late MessagingService messaging;

  Future<void> mount(WidgetTester tester, ExportDocumentPicker pick) async {
    final storage = HiddenVolumeStorage.fromStore(FakeKvLogStore());
    app = _App();
    messaging = MessagingService(
      LoopbackTransport(localNodeId: NodeId(Uint8List(32))),
      storage,
    );
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(storage),
        appControllerProvider.overrideWith(() => app),
        messagingServiceProvider.overrideWithValue(messaging),
        groupServiceProvider.overrideWithValue(null),
        cloudServiceProvider.overrideWithValue(null),
        cloudCapabilityServiceProvider.overrideWithValue(null),
        exportDocumentPickerProvider.overrideWithValue(pick),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: const DataTransferScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(l.transferExportOpen));
  }

  tearDown(() async {
    await messaging.dispose();
    container.dispose();
  });

  testWidgets(
    'picker failure is caught and shown by the actual export button',
    (tester) async {
      var calls = 0;
      await mount(tester, (_) async {
        calls++;
        throw const DocumentExportException('open');
      });
      await tester.tap(find.text(l.transferExportOpen));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(l.transferExportFailed),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'destination and finish keep export busy; success waits for provider close',
    (tester) async {
      final selected = Completer<ExportDocument?>();
      final document = _Document();
      var calls = 0;
      await mount(tester, (_) {
        calls++;
        return selected.future;
      });
      await tester.tap(find.text(l.transferExportOpen));
      await tester.pump();
      expect(calls, 1);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, l.transferExportOpen),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, l.transferExportSealed),
            )
            .onPressed,
        isNull,
      );
      selected.complete(document);
      for (var i = 0; i < 40 && !document.finishing.isCompleted; i++) {
        await tester.pump();
      }
      expect(document.finishing.isCompleted, isTrue);
      expect(document.writes, greaterThan(0));
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.byWidgetPredicate(
            (w) => w is Text && (w.data ?? '').startsWith('Written:'),
          ),
        ),
        findsNothing,
      );
      document.release.complete();
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.byWidgetPredicate(
            (w) => w is Text && (w.data ?? '').startsWith('Written:'),
          ),
        ),
        findsOneWidget,
      );
      expect(document.aborts, 0);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'identity switch in an open picker aborts selected destination without writing',
    (tester) async {
      final selected = Completer<ExportDocument?>();
      final document = _Document();
      await mount(tester, (_) => selected.future);
      await tester.tap(find.text(l.transferExportOpen));
      await tester.pump();
      app.ours = false;
      selected.complete(document);
      await tester.pumpAndSettle();
      expect(document.writes, 0);
      expect(document.aborts, 1);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(l.transferIdentitySwitched),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
