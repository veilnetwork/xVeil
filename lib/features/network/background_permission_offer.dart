import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_flutter/veil_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../../state/background_node_controller.dart'
    show kKeepNodeBackgroundPrefKey;

/// The start-up offer covers two independent choices: running the node in a
/// visible foreground service, and exempting this app from battery optimisation.
/// An OS exemption alone does not enable the service. Never enable it without
/// consent: its persistent notification and battery use are a deliberate trade.
/// Suppression follows the current profile's SharedPreferences storage.
const kBackgroundOfferSuppressedPrefKey =
    'network.background_permission.offer_suppressed.v1';

Future<bool> backgroundOfferSuppressed() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(kBackgroundOfferSuppressedPrefKey) ?? false;
}

Future<void> suppressBackgroundOffer() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(kBackgroundOfferSuppressedPrefKey, true);
}

/// A missing preference means no choice yet; stored false is an explicit opt-out.
bool shouldOfferBackgroundPermission({
  required bool onAndroid,
  required bool exempt,
  required bool suppressed,
  bool? backgroundEnabled,
}) =>
    onAndroid &&
    !suppressed &&
    backgroundEnabled != false &&
    (backgroundEnabled != true || !exempt);

Future<void> maybeOfferBackgroundPermission(
  BuildContext context, {
  required Future<void> Function() enableBackground,
}) async {
  if (!Platform.isAndroid) return;
  final prefs = await SharedPreferences.getInstance();
  final enabled = prefs.getBool(kKeepNodeBackgroundPrefKey);
  final suppressed = prefs.getBool(kBackgroundOfferSuppressedPrefKey) ?? false;
  if (suppressed || enabled == false) return;
  final exempt = await VeilBackground.isIgnoringBatteryOptimizations();
  if (!shouldOfferBackgroundPermission(
        onAndroid: true,
        exempt: exempt,
        suppressed: suppressed,
        backgroundEnabled: enabled,
      ) ||
      !context.mounted) {
    return;
  }
  await showBackgroundPermissionOffer(
    context,
    enableBackground: enableBackground,
    requestExemption: VeilBackground.requestIgnoreBatteryOptimizations,
    openSettings: VeilBackground.openBackgroundSettings,
  );
}

enum _BackgroundChoice { later, never, settings, allow }

/// The same consent dialog is used whether the OS exemption already exists or
/// still needs requesting. Only Allow changes the app's background preference.
Future<void> showBackgroundPermissionOffer(
  BuildContext context, {
  required Future<void> Function() enableBackground,
  required Future<void> Function() requestExemption,
  required Future<void> Function() openSettings,
}) async {
  final l = AppL10n.of(context);
  final choice = await showDialog<_BackgroundChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l.networkBackgroundAllowTitle),
      content: Text(l.networkBackgroundOfferBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, _BackgroundChoice.later),
          child: Text(l.networkBackgroundLater),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, _BackgroundChoice.never),
          child: Text(l.networkBackgroundNeverAsk),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, _BackgroundChoice.settings),
          child: Text(l.networkBackgroundOpenSettings),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, _BackgroundChoice.allow),
          child: Text(l.networkBackgroundAllowGrant),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  try {
    switch (choice) {
      case _BackgroundChoice.allow:
        // Persist and start while the Activity is still in front. Opening the
        // OS prompt first can background it before startForeground is allowed.
        await enableBackground();
        if (context.mounted) await requestExemption();
      case _BackgroundChoice.never:
        await suppressBackgroundOffer();
      case _BackgroundChoice.settings:
        await openSettings();
      case _BackgroundChoice.later:
      case null:
        break;
    }
  } catch (_) {
    // Platform exceptions can contain private paths; show only a fixed message.
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.networkBackgroundSetupFailed)));
    }
  }
}
