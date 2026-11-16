// Opt-in native Windows notification check. Requires an external supervisor
// that creates a fresh QA namespace and removes its history/registration even
// if an old plugin terminates this test process at the FFI boundary.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/notifications/notification_service.dart';

// Same real backend and XML serializer; only the OS chime is disabled.
class _SilentBackend extends FlutterLocalNotificationsWindows {
  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    String? payload,
    WindowsNotificationDetails? notificationDetails,
  }) => super.show(
    id: id,
    title: title,
    body: body,
    payload: payload,
    notificationDetails: WindowsNotificationDetails(
      audio: WindowsNotificationAudio.silent(),
    ),
  );
}

Future<Map<String, dynamic>> _history(String aumid) async {
  final script =
      "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new();"
      "\$ErrorActionPreference='Stop';\$h=[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]::History;"
      "\$v=@(\$h.GetHistory('$aumid'));\$bytes=0;\$route=\$true;foreach(\$t in \$v){"
      "\$bytes=[Math]::Max(\$bytes,[Text.Encoding]::UTF8.GetByteCount(\$t.Content.GetXml()));"
      "\$route=\$route -and (\$t.Content.DocumentElement.GetAttribute('launch') -eq 'incoming-call')};"
      "@{count=\$v.Count;maxXmlBytes=\$bytes;routeMatches=\$route;"
      "first=@(\$v|Where-Object {\$_.Tag -eq '2018919234'}).Count}|ConvertTo-Json -Compress";
  final utf16 = [
    for (final c in script.codeUnits) ...[c & 255, c >> 8],
  ];
  final value = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-EncodedCommand',
    base64Encode(utf16),
  ]);
  if (value.exitCode != 0) throw StateError('Windows history observer failed');
  return jsonDecode(value.stdout as String) as Map<String, dynamic>;
}

void main() {
  const enabled = bool.fromEnvironment('XVEIL_NATIVE_WINDOWS_TOAST_TEST');
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native errors are contained and long service previews remain usable',
    () async {
      const namespace = String.fromEnvironment(
        'XVEIL_WINDOWS_NOTIFICATION_NAMESPACE',
      );
      // Refuse before constructing any backend if someone forgot the QA define.
      expect(RegExp(r'^dart-qa-[a-f0-9]{12}$').hasMatch(namespace), isTrue);
      final settings = windowsNotificationSettingsForNamespace(namespace);
      final env = Platform.environment;
      final output = File(env['XVEIL_TOAST_PROBE_RESULT']!);
      final result = <String, Object?>{'stage': 'begin', 'passed': false};
      void save() => output.writeAsStringSync(jsonEncode(result));
      save();
      final setErrorMode = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
            'SetErrorMode',
          );
      final priorErrorMode = setErrorMode(0x8003);
      DynamicLibrary.open(env['XVEIL_TOAST_PROBE_DLL']!);
      final backend = _SilentBackend();
      FlutterLocalNotificationsPlatform.instance = backend;
      final service = NotificationService();
      final previousPlatform = debugDefaultTargetPlatformOverride;
      // Flutter tests default their theme/platform dispatch to Android even
      // on Windows. Exercise the host's real Windows plugin branch explicitly.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        result['stage'] = 'initialize';
        save();
        await service.init(onTap: (_) {});
        expect(service.isReady, isTrue);
        expect((await _history(settings.appUserModelId))['count'], 0);
        result['stage'] = 'short';
        save();
        expect(
          await service.show(
            id: 2018919234,
            title: 'QA',
            body: 'Short',
            payload: 'incoming-call',
          ),
          isTrue,
        );
        expect((await _history(settings.appUserModelId))['count'], 1);
        await service.cancelAll();
        result['stage'] = 'raw-oversized';
        save();
        // Exercise the native bool boundary, bypassing the service's preview cap.
        await expectLater(
          backend.show(
            id: 2018919234,
            title: 'QA',
            body: 'x' * 65536,
            payload: 'incoming-call',
          ),
          throwsA(isA<Exception>()),
        );
        result['rawRejectedWithoutTermination'] = true;
        save();
        expect((await _history(settings.appUserModelId))['count'], 0);
        final cases = <Map<String, dynamic>>[];
        for (final character in ['x', '&<', '👩🏽‍💻']) {
          result['stage'] = 'service-preview';
          save();
          expect(
            await service.show(
              id: 2018919234,
              title: 'QA' * 10000,
              body: character * 65536,
              payload: 'incoming-call',
            ),
            isTrue,
          );
          final observed = await _history(settings.appUserModelId);
          expect(observed['count'], 1);
          expect(observed['routeMatches'], isTrue);
          expect(observed['maxXmlBytes'], lessThanOrEqualTo(4096));
          cases.add(observed);
          await service.cancelAll();
        }
        result['previewCases'] = cases;
        save();
        expect(
          await service.show(
            id: 2018919234,
            title: 'QA',
            body: 'Short',
            payload: 'x' * 65536,
          ),
          isFalse,
        );
        expect((await _history(settings.appUserModelId))['count'], 0);
        result['oversizedRouteRefused'] = true;
        save();
        for (final id in [2018919234, 2018919235]) {
          expect(
            await service.show(
              id: id,
              title: 'QA',
              body: 'Short',
              payload: 'incoming-call',
            ),
            isTrue,
          );
        }
        expect((await _history(settings.appUserModelId))['count'], 2);
        await service.cancel(2018919234);
        final afterCancel = await _history(settings.appUserModelId);
        expect(afterCancel['count'], 1);
        expect(afterCancel['first'], 0);
        result['afterCancel'] = afterCancel;
        await service.cancelAll();
        expect((await _history(settings.appUserModelId))['count'], 0);
        result['stage'] = 'complete';
        result['passed'] = true;
        save();
      } finally {
        if (service.isReady) await service.cancelAll();
        backend.dispose();
        setErrorMode(priorErrorMode);
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    },
    skip: !Platform.isWindows || !enabled
        ? 'Opt-in Windows toast payload control'
        : false,
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
