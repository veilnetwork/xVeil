import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/node/ssh_client.dart';
import '../../l10n/app_localizations.dart';

/// The fingerprint to connect with, or null if the user did not confirm one.
///
/// Returns [pinned] unchanged when the host is already known — the common
/// case, and no dialog appears. On FIRST contact it opens a connection that
/// learns the host key without authenticating ([sshDiscoverHostKey]), shows it
/// for out-of-band comparison, and only returns it once the user says it
/// matches.
///
/// The order is the point. Trust-on-first-use used to be decided inside the
/// connection that then sent the password and ran the provisioning script, so
/// a man-in-the-middle on that first contact collected both, replied with
/// something plausible, and got its own key saved as trusted. The user was
/// shown a fingerprint to check only once there was nothing left to protect.
Future<String?> confirmSshHost(
  BuildContext context, {
  required String host,
  required int port,
  String? pinned,
}) async {
  if (pinned != null && pinned.isNotEmpty) return pinned;
  final String observed;
  try {
    observed = await sshDiscoverHostKey(host: host, port: port);
  } on SshException {
    return null;
  }
  if (!context.mounted) return null;
  final l = AppL10n.of(context);
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l.sshConfirmHostTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.sshConfirmHostBody(host)),
            const SizedBox(height: 16),
            SelectableText(
              observed,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            TextButton.icon(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: observed)),
              icon: const Icon(Icons.copy),
              label: Text(l.actionCopy),
            ),
            const SizedBox(height: 8),
            Text(
              l.sshConfirmHostHint,
              style: Theme.of(dialog).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(l.sshConfirmHostAccept),
        ),
      ],
    ),
  );
  return accepted == true ? observed : null;
}
