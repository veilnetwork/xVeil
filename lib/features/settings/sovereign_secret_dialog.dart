// Ask for the secret that unlocks the identity's master key.
//
// Two screens need it for the same reason: an operation that speaks for the
// IDENTITY — revoking a device, claiming a name — is signed by the master, and
// the master is not in the process until someone types the secret for it. It
// was written once inside the devices screen and lifted here whole when the
// nickname claim needed the same prompt; copying it would have left two
// dialogs to keep honest about which secret the identity actually uses.
//
// Returns the typed secret, or null when the user cancels. The controller is
// cleared before disposal so the secret does not outlive the dialog.

import 'package:flutter/material.dart';

/// Asks for the secret, and owns the controller that holds it.
///
/// The caller used to build the controller, await `showDialog`, then clear and
/// dispose it on the next line. That await returns when `Navigator.pop` runs
/// and the route stays mounted through its exit transition, so the obscured
/// `TextField` went on using a disposed controller. Ownership here also means
/// the secret is cleared by the widget that displayed it, at the moment that
/// widget goes away, rather than by a caller that has already moved on.
class SovereignSecretDialog extends StatefulWidget {
  const SovereignSecretDialog({
    super.key,
    required this.title,
    required this.confirmLabel,
    required this.fieldLabel,
    required this.helperText,
  });

  final String title;
  final String confirmLabel;

  /// What to call the secret. An identity unlocked by a recovery certificate
  /// has a CODE, not a phrase, and asking for the wrong one is how a user
  /// concludes their key is broken — ask the service which it is
  /// (`sovereignCredentialKind`) rather than guessing.
  final String fieldLabel;
  final String helperText;

  @override
  State<SovereignSecretDialog> createState() => _SovereignSecretDialogState();
}

class _SovereignSecretDialogState extends State<SovereignSecretDialog> {
  final TextEditingController _secret = TextEditingController();

  @override
  void dispose() {
    _secret.clear();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _secret,
        obscureText: true,
        maxLines: 1,
        decoration: InputDecoration(
          labelText: widget.fieldLabel,
          helperText: widget.helperText,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _secret.text.trim()),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
