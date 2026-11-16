import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/desktop/desktop_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'notification activation restores minimized window and guards overlap',
    () async {
      const channel = MethodChannel('window_manager');
      final entered = Completer<void>();
      final release = Completer<void>();
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'isMinimized') return true;
        if (call.method == 'show') {
          entered.complete();
          await release.future;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final first = showDesktopWindow();
      await entered.future;
      try {
        await showDesktopWindow();
        expect(calls, ['isMinimized', 'restore', 'show']);
      } finally {
        release.complete();
        await first;
      }
      expect(calls, ['isMinimized', 'restore', 'show', 'focus']);
    },
  );
}
