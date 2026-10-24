import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/recovery_certificate_export.dart';
import 'package:xveil/features/onboarding/recovery_certificate_step.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/l10n/app_localizations_en.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const picker = MethodChannel('miguelruivo.flutter.plugins.filepicker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const certificate = 'xveil-recovery:v1:certificate-only-é';
  const code = 'xvrc-SECRET-KEPT-SEPARATELY';

  tearDown(() {
    messenger.setMockMethodCallHandler(picker, null);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final result in ['saved', 'cancelled', 'failed']) {
      testWidgets(
        '$platform ceremony export: $result',
        (tester) async {
          var calls = 0;
          messenger.setMockMethodCallHandler(picker, (call) async {
            expect(call.method, 'save');
            calls++;
            final args = call.arguments as Map;
            expect(args['fileName'], 'xveil-recovery-aaaaaaaa.xvrc');
            final bytes = args['bytes'] as Uint8List;
            expect(utf8.decode(bytes), certificate);
            expect(utf8.decode(bytes), isNot(contains(code)));
            if (result == 'failed') {
              throw PlatformException(code: 'write_failed');
            }
            // Android's document provider path is not a dart:io file. Reopening
            // it after a successful export would turn success into a UI error.
            return result == 'saved' ? '/document/primary:backup.xvrc' : null;
          });
          bool? observed;
          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: Scaffold(
                body: RecoveryCertificateStep(
                  phrase: 'legacy phrase',
                  already: MintedRecovery(
                    credential: Uint8List.fromList([1, 2, 3]),
                    certificate: certificate,
                    code: code,
                    nodeId: NodeId.fromHex('aa' * 32),
                  ),
                  onDone: ({required bool saved, Uint8List? credential}) {
                    observed = saved;
                  },
                ),
              ),
            ),
          );
          final l = AppL10nEn();
          final saveButton = find.text(l.devicesSaveCertificate);
          await tester.ensureVisible(saveButton);
          await tester.tap(saveButton);
          await tester.pumpAndSettle();
          expect(calls, 1, reason: 'must reach the picker with bytes');
          expect(
            find.text(l.onboardCertFailed),
            result == 'failed' ? findsOneWidget : findsNothing,
          );
          final next = find.text(l.onboardCertContinue);
          await tester.ensureVisible(next);
          await tester.tap(next);
          await tester.pumpAndSettle();
          if (result != 'saved') {
            expect(observed, isNull);
            await tester.ensureVisible(next);
            await tester.pumpAndSettle();
            await tester.tap(next);
            await tester.pumpAndSettle();
          }
          expect(observed, result == 'saved');
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }

  test('desktop reads back the actual bytes before reporting saved', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final dir = await Directory.systemTemp.createTemp('xveil-cert-export-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/certificate.xvrc');
    var corrupt = false;
    messenger.setMockMethodCallHandler(picker, (call) async {
      final bytes = (call.arguments as Map)['bytes'] as Uint8List;
      await file.writeAsBytes(corrupt ? [0] : bytes);
      return file.path;
    });
    expect(
      await saveRecoveryCertificateToFile(certificate, 'backup.xvrc'),
      true,
    );
    expect(await file.readAsString(), certificate);
    corrupt = true;
    await expectLater(
      saveRecoveryCertificateToFile(certificate, 'backup.xvrc'),
      throwsStateError,
    );
  });
}
