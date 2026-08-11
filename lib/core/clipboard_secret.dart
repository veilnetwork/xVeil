// Putting a secret on the clipboard, and taking it back off.
//
// The clipboard is shared with every app on the device, it survives the screen
// lock, and on desktop it is read by history tools and synced to other machines
// by the OS. A write-capable API token left there is a credential sitting in
// the one place the whole system can read.
//
// ## Why this clears on a timer instead of checking first
//
// The obvious design is clear-if-unchanged: read the clipboard back, and clear
// it only if it still holds what we put there, so nothing the person copied in
// the meantime is destroyed. It is the right shape and it is not available
// here. Reading the clipboard on iOS 16 and later shows the person a "pasted
// from xVeil" banner — the check would announce itself every time, for a
// benefit they cannot see. A privacy fix whose mechanism is a privacy prompt
// is not a fix.
//
// So it clears unconditionally, and the UI SAYS SO at the moment of copying.
// Something else copied within the window is lost; that is a real cost, and
// the only honest way to charge it is to tell the person the window exists
// before it starts.

import 'dart:async';

import 'package:flutter/services.dart';

/// How long a copied secret is allowed to stay on the clipboard.
///
/// Long enough to switch windows and paste, short enough that walking away
/// from the machine does not leave a credential behind. The number is stated
/// to the person in the same breath as the copy, so it is part of the
/// interface rather than a hidden policy.
const Duration kClipboardSecretLifetime = Duration(seconds: 45);

/// Clear the clipboard after [after].
///
/// Returns the pending work so a test can await it; production fires and
/// forgets. Deliberately NOT tied to the widget's lifetime: the point is that
/// it happens even if the person closes the screen, which is the case where
/// they are least likely to clear it themselves.
Future<void> clearClipboardLater({
  Duration after = kClipboardSecretLifetime,
  Future<void> Function(Duration) delay = _sleep,
  Future<void> Function() clear = _clear,
}) async {
  await delay(after);
  try {
    await clear();
  } on PlatformException {
    // A platform that refuses is not worth an error to the person — they were
    // told the clipboard would be cleared, and the worst case is that it is
    // not. Better than a crash on a screen they have probably already left.
  } on MissingPluginException {
    // Same, for a host with no clipboard at all.
  }
}

Future<void> _sleep(Duration d) => Future<void>.delayed(d);

Future<void> _clear() => Clipboard.setData(const ClipboardData(text: ''));
