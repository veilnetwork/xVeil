import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_flutter/veil_flutter.dart';

import '../../l10n/app_localizations.dart';

/// The start-up offer to exempt xVeil from Android's battery optimisation.
///
/// WHY THIS IS ASKED AT ALL, and why the app cannot simply cope without it.
///
/// The background node runs inside a foreground service. From Android 12 the
/// platform refuses `startForeground()` for an app it does not consider
/// eligible, and an app without the battery exemption stops being eligible the
/// moment it is backgrounded. Measured on a phone doing nothing unusual: let
/// the screen switch off, and the node is gone — no sessions with any seed, no
/// mail drained, nothing delivered — while the app still reports itself ready.
/// Until the exemption is granted there is no version of "keep receiving in the
/// background" that works, so this is not a nag about a nicety.
///
/// The offer is separate from the prompt the Network screen already has. That
/// one is user-initiated — a toggle or a help tile — and must always appear
/// when asked for. This one arrives uninvited at start-up, so it carries a
/// "don't ask again", and its body says where the switch lives afterwards: an
/// offer that can be dismissed for good has to leave a way back, or dismissing
/// it once quietly removes the feature.
///
/// SUPPRESSION IS APP-WIDE, not per identity. The exemption is one OS setting
/// for one installed app; a person who has said "don't ask" has said it about
/// their phone, and asking again under a second identity would be the same
/// question about the same switch.

/// Whether the start-up offer has been silenced for good.
///
/// Deliberately NOT the same thing as "the exemption is missing". Someone who
/// dismissed the offer has not thereby decided to run without the exemption —
/// they may grant it from the Network screen the next day, and this key must
/// not be read as an answer to that question.
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

/// Whether to put the offer in front of someone on this launch.
///
/// Pure, and it takes the platform as an argument rather than reading
/// [Platform] itself, so every branch is reachable from a test on one host —
/// the same reason `localEndpointPlanFor` is shaped this way.
bool shouldOfferBackgroundPermission({
  required bool onAndroid,
  required bool exempt,
  required bool suppressed,
}) => onAndroid && !exempt && !suppressed;

/// Ask once per launch, if there is anything to ask about.
///
/// Ordered so the cheapest disqualifier comes first: a platform that has no
/// such setting, then a phone that has already granted it, and only then the
/// preference read — no I/O at all for the overwhelmingly common case of an
/// install that is already exempt.
Future<void> maybeOfferBackgroundPermission(BuildContext context) async {
  if (!Platform.isAndroid) return;
  final exempt = await VeilBackground.isIgnoringBatteryOptimizations();
  if (exempt) return;
  final suppressed = await backgroundOfferSuppressed();
  if (!shouldOfferBackgroundPermission(
    onAndroid: true,
    exempt: exempt,
    suppressed: suppressed,
  )) {
    return;
  }
  if (!context.mounted) return;
  final l = AppL10n.of(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l.networkBackgroundAllowTitle),
      content: Text(l.networkBackgroundOfferBody),
      actions: [
        // "Later" and "don't ask again" are two different answers and are kept
        // apart: the first is a person who has not decided, the second is one
        // who has. Collapsing them into a single dismissal is how an app ends
        // up either nagging forever or falling silent after one stray tap.
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(l.networkBackgroundLater),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(ctx);
            unawaited(suppressBackgroundOffer());
          },
          child: Text(l.networkBackgroundNeverAsk),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(ctx);
            VeilBackground.openBackgroundSettings();
          },
          child: Text(l.networkBackgroundOpenSettings),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            VeilBackground.requestIgnoreBatteryOptimizations();
          },
          child: Text(l.networkBackgroundAllowGrant),
        ),
      ],
    ),
  );
}
