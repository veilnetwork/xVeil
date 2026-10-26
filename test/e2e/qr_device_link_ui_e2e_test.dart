@Timeout(Duration(minutes: 10))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;
import 'package:xveil/data/transport/device_pairing_lan.dart';
import 'package:xveil/domain/device_pairing.dart';
import 'package:xveil/features/settings/devices_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/group_service.dart';

import 'device_fixture.dart';
import 'e2e_env.dart';

/// Only the camera decoder boundary is supplied by this test. Both linking
/// sheets, the QR payload, encrypted LAN exchange, approval and native
/// identity adoption run through the application's actual widgets/services.
class _ScannedQr extends NavigatorObserver {
  String? nextResult;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final result = nextResult;
    if (result != null) E2eLog.line('QR_UI_SCAN_ROUTE=${route.runtimeType}');
    if (result == null || route is! MaterialPageRoute<String>) return;
    nextResult = null;
    scheduleMicrotask(() => navigator!.pop(result));
  }
}

/// UI-originated work belongs to the widget clock. Continue pumping while the
/// real native/storage teardown joins it, rather than waiting on that work
/// with the fake clock stopped inside runAsync.
Future<void> _finishWithFrames(
  WidgetTester tester,
  Future<void> Function() task,
) async {
  var done = false;
  Object? error;
  StackTrace? stack;
  await tester.runAsync(() async {
    unawaited(
      Future<void>.sync(task).then(
        (_) {
          done = true;
        },
        onError: (Object failure, StackTrace trace) {
          error = failure;
          stack = trace;
          done = true;
        },
      ),
    );
  });
  final watch = Stopwatch()..start();
  while (!done && watch.elapsed < const Duration(minutes: 3)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (!done) throw TimeoutException('UI-owned native teardown did not finish');
  if (error != null) Error.throwWithStackTrace(error!, stack!);
}

void main() async {
  final gate = E2eGate.read();
  final lan = gate.enabled ? await localPairingAddresses() : <String>[];
  testWidgets(
    'one QR links a certificate identity through both UI sheets',
    (tester) async {
      final fleet = await tester.runAsync(
        () => E2eFleet.start(gate: gate, labels: const ['A', 'B', 'C']),
      );
      final f = fleet!;
      final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
      if (evidence != null) {
        await tester.runAsync(
          () => File(
            '$evidence/fleet-private.json',
          ).writeAsString(jsonEncode({'root': f.root.path})),
        );
      }
      final a = f.a, b = f.b;
      final restartCalled = Completer<void>();
      final restarted = Completer<bool>();
      final scan = _ScannedQr();
      const sourceKey = ValueKey('source-device-ui');
      const targetKey = ValueKey('target-device-ui');
      addTearDown(() async {
        if (!restarted.isCompleted) restarted.complete(false);
        await tester.pumpWidget(const SizedBox.shrink());
        await _finishWithFrames(tester, f.dispose);
        await tester.binding.setSurfaceSize(null);
      });
      await tester.binding.setSurfaceSize(const Size(1600, 1100));
      final sourceIdentity = a.identityNodeId;
      final originalTargetIdentity = b.identityNodeId;
      final sourceDevice = a.deviceNodeId, targetDevice = b.deviceNodeId;
      expect(originalTargetIdentity, isNot(sourceIdentity));
      await _finishWithFrames(tester, () async {
        await f.introduce(f.c, a);
        expect(
          await f.c.messaging.sendText(sourceIdentity, 'qr-ui-old-history'),
          isTrue,
        );
        await waitUntil(
          () async => (await a.conversation(
            f.c.identityNodeId,
          )).contains('qr-ui-old-history'),
          what: 'source holds pre-link history',
        );
      });

      // Exercise the current certificate/code branch, retaining this fixture's
      // already-proven master identity instead of generating another owner.
      final exported = await tester.runAsync(() async {
        final pair = await a.groups!.exportRecoveryCertificate(
          a.identity.phrase,
        );
        expect(pair, isNotNull);
        expect(pair!.nodeId, sourceIdentity);
        await a.storage.storeFile(
          GroupService.kSovereignBundleSetting,
          pair.certificate,
          name: 'sovereign-credential',
        );
        expect(await a.groups!.sovereignCredentialKind(), 'certificate');
        return pair;
      });
      E2eLog.line('QR_UI_CERTIFICATE_READY');
      b.onHostedNodeReboot(() {
        if (!restartCalled.isCompleted) restartCalled.complete();
        return restarted.future;
      });

      Widget pane(E2eDevice device, Key key, {NavigatorObserver? observer}) =>
          Expanded(
            child: RepaintBoundary(
              key: ValueKey('capture-${device.label}'),
              child: SizedBox(
                key: key,
                child: UncontrolledProviderScope(
                  container: device.container,
                  child: MaterialApp(
                    localizationsDelegates: AppL10n.localizationsDelegates,
                    supportedLocales: AppL10n.supportedLocales,
                    navigatorObservers: [?observer],
                    home: const DevicesScreen(),
                  ),
                ),
              ),
            ),
          );
      Future<void> show({bool target = true}) => tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            children: [
              pane(a, sourceKey),
              if (target)
                pane(b, targetKey, observer: scan)
              else
                const Expanded(child: SizedBox.shrink()),
            ],
          ),
        ),
      );
      Finder within(Key key, Finder finder) =>
          find.descendant(of: find.byKey(key), matching: finder);
      Future<void> until(bool Function() ready, String what) async {
        final watch = Stopwatch()..start();
        while (!ready() && watch.elapsed < const Duration(seconds: 60)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 50));
          final exception = tester.takeException();
          if (exception != null) throw exception;
        }
        if (!ready()) {
          E2eLog.line('QR_UI_SCAN_RETURNED=${scan.nextResult == null}');
        }
        expect(ready(), isTrue, reason: what);
      }

      Future<void> press(Key key, String label) async {
        await tester.pump();
        final finder = within(key, find.text(label));
        expect(finder, findsOneWidget);
        await tester.ensureVisible(finder);
        final buttons = find.ancestor(
          of: finder,
          matching: find.byWidgetPredicate(
            (widget) => widget is ButtonStyleButton,
          ),
        );
        if (buttons.evaluate().isNotEmpty) {
          expect(
            tester.widget<ButtonStyleButton>(buttons.first).onPressed,
            isNotNull,
            reason: 'the visible action must be enabled: $label',
          );
        }
        await tester.tap(finder);
        await tester.pump();
        // A modal's children exist before its entrance animation can be hit.
        // Pump the route transition explicitly; pumpAndSettle would also wait
        // for the linking screen's intentionally continuous progress spinner.
        await tester.pump(const Duration(milliseconds: 400));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }

      await show();
      final l = AppL10n.of(
        tester.element(within(sourceKey, find.byType(DevicesScreen))),
      );
      await until(
        () => within(
          sourceKey,
          find.widgetWithText(ListTile, l.devicesLinkNew),
        ).evaluate().any((e) => (e.widget as ListTile).enabled),
        'source linking action becomes ready',
      );
      await press(sourceKey, l.devicesLinkNew);
      await until(
        () => within(sourceKey, find.byType(QrImageView)).evaluate().isNotEmpty,
        'source displays its one-QR pairing offer',
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final qr = await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('capture-A')),
        );
        final image = await boundary.toImage(pixelRatio: 3);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        final file = File('${f.root.path}/pairing-qr-private.png');
        await file.writeAsBytes(png!.buffer.asUint8List());
        try {
          final decoded = await Process.run('/usr/bin/swift', [
            'test/e2e/support/decode_qr.swift',
            file.path,
          ]);
          if (decoded.exitCode != 0) {
            final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
            if (evidence != null) {
              await file.copy('$evidence/qr-failure-private.png');
            }
            throw StateError(
              'QR pixel decoder failed: ${decoded.exitCode} ${decoded.stderr}',
            );
          }
          return (decoded.stdout as String).trim();
        } finally {
          await file.delete();
        }
      });
      final code = DevicePairingCode.parse(qr!);
      E2eLog.line('QR_UI_CODE_DECODED');
      expect(code.identity, sourceIdentity);
      expect(code.device.nodeId, sourceDevice);

      await until(
        () => within(
          targetKey,
          find.widgetWithText(ListTile, l.devicesJoinExisting),
        ).evaluate().any((e) => (e.widget as ListTile).enabled),
        'target joining action becomes ready',
      );
      await press(targetKey, l.devicesJoinExisting);
      scan.nextResult = qr;
      await press(targetKey, l.devicesPairScan);
      final safety = devicePairingSafetyCode(code.ticket, targetDevice);
      await until(
        () => within(
          sourceKey,
          find.text(l.devicesPairCodesMatch),
        ).evaluate().isNotEmpty,
        'source sees the direct joining request',
      );
      expect(
        within(targetKey, find.text(l.devicesPairWait(safety))),
        findsOneWidget,
      );
      E2eLog.line('QR_UI_REQUEST_VISIBLE');
      expect(
        within(
          sourceKey,
          find.text(l.devicesPairRequest(targetDevice.short, safety)),
        ),
        findsOneWidget,
      );
      expect(
        b.identityNodeId,
        originalTargetIdentity,
        reason: 'an unapproved QR request must not adopt the identity',
      );

      final secret = within(
        sourceKey,
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              w.decoration?.labelText == l.devicesRecoveryCode,
        ),
      );
      await tester.enterText(secret, exported!.code);
      await tester.tap(within(sourceKey, find.byType(CheckboxListTile)));
      await tester.pump();
      expect(
        tester
            .widget<CheckboxListTile>(
              within(sourceKey, find.byType(CheckboxListTile)),
            )
            .value,
        isTrue,
      );
      await press(sourceKey, l.devicesPrepare);
      await until(
        () => restartCalled.isCompleted,
        'approved target persists adoption and requests a native restart',
      );
      E2eLog.line('QR_UI_RESTART_REQUESTED');
      await show(target: false);
      await tester.runAsync(b.restart);
      expect(b.identityNodeId, sourceIdentity);
      expect(b.deviceNodeId, targetDevice);
      E2eLog.line('QR_UI_NODE_RESTARTED');
      restarted.complete(true);
      await until(
        () => within(sourceKey, find.byType(BottomSheet)).evaluate().isEmpty,
        'source sends its snapshot after the actual target restart',
      );
      await tester.runAsync(
        () => waitUntil(
          () async => await b.groups!.deviceGroupIdHex() != null,
          what: 'target adopts the device group after the one-QR ceremony',
        ),
      );
      expect(
        await tester.runAsync(a.groups!.deviceGroupIdHex),
        await tester.runAsync(b.groups!.deviceGroupIdHex),
      );
      for (final device in [a, b]) {
        final roster = await tester.runAsync(
          () async => {
            ...await device.groups!.addressableOwnDevices(),
            await device.groups!.resolveMyDevice(),
          },
        );
        expect(roster, {
          sourceDevice,
          targetDevice,
        }, reason: 'the roster contains exactly the two physical devices');
      }
      await _finishWithFrames(
        tester,
        () => waitUntil(
          () async => (await b.conversation(
            f.c.identityNodeId,
          )).contains('qr-ui-old-history'),
          what: 'the QR-linked device receives existing history',
        ),
      );
      await _finishWithFrames(tester, () async {
        expect(
          await f.c.messaging.sendText(sourceIdentity, 'qr-ui-incoming'),
          isTrue,
        );
        expect(
          await a.messaging.sendText(f.c.identityNodeId, 'qr-ui-outgoing'),
          isTrue,
        );
        await waitUntil(
          () async =>
              (await a.conversation(
                f.c.identityNodeId,
              )).contains('qr-ui-incoming') &&
              (await b.conversation(
                f.c.identityNodeId,
              )).contains('qr-ui-incoming') &&
              (await b.conversation(
                f.c.identityNodeId,
              )).contains('qr-ui-outgoing') &&
              (await f.c.conversation(
                sourceIdentity,
              )).contains('qr-ui-outgoing'),
          what: 'bidirectional traffic converges after UI-only linking',
        );
        for (final body in ['qr-ui-incoming', 'qr-ui-outgoing']) {
          final source = (await a.conversationRows(
            f.c.identityNodeId,
          )).singleWhere((message) => message.body == body);
          final mirrored = (await b.conversationRows(
            f.c.identityNodeId,
          )).singleWhere((message) => message.body == body);
          expect(mirrored.id, source.id);
        }
      });
      E2eLog.line('QR_UI_HISTORY_AND_DELIVERY_PASS');

      Future<void> verifyVisibleRosters() async {
        await show();
        await until(
          () => [sourceKey, targetKey].every(
            (key) =>
                within(
                  key,
                  find.text(sourceDevice.short),
                ).evaluate().isNotEmpty &&
                within(
                  key,
                  find.text(targetDevice.short),
                ).evaluate().isNotEmpty,
          ),
          'both device screens show both physical devices',
        );
        for (final key in [sourceKey, targetKey]) {
          final rows = within(
            key,
            find.byWidgetPredicate((widget) {
              if (widget is! ListTile || widget.leading is! Icon) return false;
              final icon = (widget.leading as Icon).icon;
              return icon == Icons.devices || icon == Icons.phonelink_outlined;
            }),
          );
          expect(rows, findsNWidgets(2), reason: 'no temporary identity row');
        }
      }

      await verifyVisibleRosters();
      await show(target: false);
      await _finishWithFrames(tester, b.stop);
      await _finishWithFrames(tester, () async {
        expect(
          await a.messaging.sendText(f.c.identityNodeId, 'qr-ui-offline-B'),
          isTrue,
        );
        await waitUntil(
          () async => (await f.c.conversation(
            sourceIdentity,
          )).contains('qr-ui-offline-B'),
          what: 'C receives while B is stopped',
        );
        await f.c.stop();
        await b.start();
        await waitUntil(
          () async => (await b.conversation(
            f.c.identityNodeId,
          )).contains('qr-ui-offline-B'),
          what: 'restarted B recovers while C is offline',
        );
      });
      expect(b.identityNodeId, sourceIdentity);
      expect(b.deviceNodeId, targetDevice);
      // The pinned group snapshot intentionally carries an encrypted copy of
      // the recovery certificate. It must not grant master access without the
      // independent recovery code, which was typed only on the source screen.
      await tester.runAsync(() async {
        expect(await b.groups!.localSovereignBundle(), exported.certificate);
        final wrongCode = veil.generateSovereignRecoveryCode();
        expect(wrongCode, isNot(exported.code));
        await expectLater(
          b.groups!.openLocalSovereign(wrongCode),
          throwsA(isA<veil.VeilException>()),
        );
      });
      await verifyVisibleRosters();
      E2eLog.line('QR_UI_RECONNECT_PASS');
      E2eLog.line('QR_UI_PAIRING_PASS');
    },
    skip: !gate.enabled || lan.isEmpty || !Platform.isMacOS,
  );
}
