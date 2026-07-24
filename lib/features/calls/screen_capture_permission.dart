import 'dart:async' show unawaited;
import 'dart:io' show Platform, Process;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

const _macScreenCaptureSettings =
    'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture';

Future<bool> openMacScreenCaptureSettings() async {
  if (!Platform.isMacOS) return false;
  final result = await Process.run('/usr/bin/open', [
    _macScreenCaptureSettings,
  ]);
  return result.exitCode == 0;
}

void showScreenCapturePermissionSnackBar(BuildContext context) {
  final l10n = AppL10n.of(context);
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 12),
      content: Text(l10n.callScreenPermissionRequired),
      action: SnackBarAction(
        label: l10n.callOpenScreenSettings,
        onPressed: () => unawaited(openMacScreenCaptureSettings()),
      ),
    ),
  );
}
