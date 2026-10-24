// Stand entrypoint: flutter run -d macos -t test/native/startup_unlock_platform_probe.dart
// Uses only a random, disposable OS-vault slot. Never starts the messenger,
// opens a user container, changes the active profile or requests biometrics.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/core/quick_unlock_vault.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Quick unlock storage check'))),
    ),
  );
  final scope =
      Platform.environment['XVEIL_QUICK_PROBE_SCOPE'] ??
      'platform-probe-${Random.secure().nextInt(1 << 32)}';
  final vault = QuickUnlockVault(
    const QuickUnlockSecretStore(),
    scope,
    LocalScreenAuthentication(),
  );
  var passed = false, removed = false;
  String? failure;
  try {
    const password = 'disposable platform fixture password';
    await vault.configure(
      password: password,
      grid: 3,
      nodes: [0, 1, 4, 8],
      system: false,
    );
    final restarted = QuickUnlockVault(
      const QuickUnlockSecretStore(),
      scope,
      LocalScreenAuthentication(),
    );
    passed =
        (await restarted.options()).grid == 3 &&
        await restarted.openPattern([0, 1, 4, 7]) == null &&
        await restarted.openPattern([0, 1, 4, 8]) == password;
  } catch (error) {
    failure = error.runtimeType.toString();
  } finally {
    try {
      await vault.forget();
      removed = !(await vault.options()).enabled;
    } catch (error) {
      failure ??= error.runtimeType.toString();
    }
  }
  stdout.writeln(
    'STARTUP_UNLOCK_PROBE ${jsonEncode({'passed': passed, 'removed': removed, 'failureType': failure})}',
  );
  exit(passed && removed ? 0 : 1);
}
