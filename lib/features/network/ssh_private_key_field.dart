import 'package:flutter/material.dart';

import '../../core/secure_screen.dart';

/// The field an operator pastes an SSH PRIVATE key into, with the screenshot
/// guard attached to it.
///
/// Every other secret on these screens is a single line and is obscured: the
/// SSH password, the key passphrase, the space password. A PEM cannot be —
/// Flutter's `obscureText` forces `maxLines: 1`, and a private key that arrives
/// as one unreadable line is a key nobody can check they pasted correctly. So
/// the four SSH screens each rendered it in a five-line monospace box, in
/// plain sight, on a route nothing protected: a screen recorder, a task-switcher
/// snapshot or a shoulder took the key that opens root on the operator's
/// server, while the obscured password beside it gave up nothing.
///
/// The answer is the one the onboarding phrase step already uses for exactly
/// this shape — "typing it in puts it on screen exactly as showing it does …
/// the field is not obscured, deliberately … guarded for the same reason the
/// display step is". [SecureScreenGuard] is mount-scoped, so wrapping the FIELD
/// rather than each screen holds the flag precisely while a key can be on
/// screen, and gives it back the moment the sheet closes — which matters,
/// because the flag blacks out this app's own screen sharing while it is held.
///
/// It lives in one widget so the next screen that needs the field inherits the
/// guard instead of re-deciding it. There were four copies of the bare version
/// in four files; that is how the first one stayed bare.
class SshPrivateKeyField extends StatelessWidget {
  const SshPrivateKeyField({
    super.key,
    required this.controller,
    required this.labelText,
    this.helperText,
    this.helperMaxLines,
    this.maxLines = 5,
    this.controllerOverride,
  });

  final TextEditingController controller;
  final String labelText;
  final String? helperText;
  final int? helperMaxLines;

  /// Kept per call site so adopting this widget did not reflow four sheets.
  final int maxLines;

  /// Test seam, forwarded to [SecureScreenGuard]. Production uses the app-wide
  /// controller.
  final SecureScreen? controllerOverride;

  @override
  Widget build(BuildContext context) => SecureScreenGuard(
    controller: controllerOverride,
    child: TextField(
      controller: controller,
      minLines: 2,
      maxLines: maxLines,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
      decoration: InputDecoration(
        labelText: labelText,
        helperText: helperText,
        helperMaxLines: helperMaxLines,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    ),
  );
}
