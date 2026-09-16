// Two credentials put on screen, and the single bounded route off each.
//
// Lifted out of the devices screen when the identity ceremony needed the same
// pair: the certificate and the code are shown at creation now as well as in
// settings, and a second copy of a control whose whole job is to BOUND a
// secret's life on the clipboard is two places to keep honest about the
// bound. The devices screen re-exports them, so every existing import and
// every test that names them still resolves here.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'clipboard_secret.dart';

/// A copy control for a credential, with the clipboard's lifetime attached.
///
/// Three secrets on this screen went onto the system-wide clipboard and stayed
/// there for as long as the person did not copy something else: the recovery
/// CERTIFICATE, the recovery CODE, and the device-adoption TOKEN. The
/// certificate and the code TOGETHER are a whole recovery capability for this
/// identity — the sheet's own warning says as much — and the token adopts a
/// device into the group. That is the same credential class as the API token,
/// which was bounded first, and strictly more dangerous: the API token is
/// revocable from the same screen, a sovereign recovery capability is not.
///
/// Why the clear is UNCONDITIONAL rather than compare-then-clear is argued in
/// clipboard_secret.dart and is not repeated here: reading the clipboard back
/// on iOS 16+ raises a "pasted from xVeil" banner, so the check would announce
/// itself every time. The honest price of clearing blind is telling the person
/// the window exists before it starts — which is what [copiedMessage] is for,
/// and why it takes the number of seconds rather than hard-coding one that can
/// drift away from [kClipboardSecretLifetime].
class SecretCopyButton extends StatelessWidget {
  const SecretCopyButton({
    super.key,
    required this.label,
    required this.value,
    required this.copiedMessage,
    this.schedule = clearClipboardLater,
    this.onCopied,
  });

  /// Text on the button.
  final String label;

  /// Read at TAP time, not captured at build time: these sheets rebuild around
  /// the secret as it is produced, and a stale capture would copy the value
  /// from a previous frame.
  final String Function() value;

  /// The localised "copied, cleared in N seconds" line, taking the window.
  /// The generated getter is passed directly so the number the person is told
  /// and the number the timer waits are one value.
  final String Function(int seconds) copiedMessage;

  /// Injectable so a test can watch the scheduling without waiting 45 s.
  final Future<void> Function() schedule;

  /// Told that the value left the screen this way.
  ///
  /// A caller that gates on the secret having been kept needs to know: copying
  /// IS how people keep things — into a password manager, into a note — and a
  /// screen that only counts files tells someone holding their certificate
  /// that they are holding nothing. What the caller must NOT do is record it
  /// as a durable copy: this clipboard clears itself.
  final VoidCallback? onCopied;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: value()));
        // Fire and forget, deliberately: the clear must happen even when this
        // sheet is closed a second later, which is the case where the person
        // is least likely to clear it themselves.
        unawaited(schedule());
        onCopied?.call();
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(copiedMessage(kClipboardSecretLifetime.inSeconds)),
          ),
        );
      },
      icon: const Icon(Icons.copy),
      label: Text(label),
    );
  }
}

/// A credential put on screen, and put there ONLY — the copy control beside it
/// is the single route off it.
///
/// The three secrets on this screen were displayed in [SelectableText], which
/// is an `EditableText` in read-only clothes. Long-press → Copy on a phone and
/// Ctrl/Cmd-C on a desktop both land in `Clipboard.setData` inside the
/// framework: no timer, no snackbar, no bound. So beside the [SecretCopyButton]
/// that schedules the clear and states the window, each of the certificate, the
/// code and the adoption token also had a second, unbounded route onto a
/// clipboard every app can read — on the one sheet the app wraps in
/// [SecureScreenGuard] precisely because a capture of it reconstructs the
/// signer.
///
/// Hiding the toolbar item was NOT the fix: `copySelection` is reached by the
/// keyboard shortcut with no toolbar ever built, so a `contextMenuBuilder` that
/// drops "Copy" is a lid laid over the hole. The text has to stop being
/// selectable.
///
/// [SelectionContainer.disabled] is not redundant with plain [Text]. There is
/// no ancestor `SelectionArea` on this screen today, and this is what stops
/// that from being a fact somebody has to keep remembering: wrap a sheet in one
/// tomorrow and every other line becomes selectable while these three do not.
class SecretText extends StatelessWidget {
  const SecretText(this.secret, {super.key, this.maxLines, this.fontSize});

  /// The credential itself.
  final String secret;

  /// Clipped past this many lines, as the certificate was before.
  final int? maxLines;

  /// Null keeps the surrounding text size; the long values ask for 10.
  final double? fontSize;

  @override
  Widget build(BuildContext context) => SelectionContainer.disabled(
    child: Text(
      secret,
      maxLines: maxLines,
      style: TextStyle(fontFamily: 'monospace', fontSize: fontSize),
    ),
  );
}

