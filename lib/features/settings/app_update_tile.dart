import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_update_controller.dart';
import '../common/shown_cause.dart';

/// Update checking, said plainly and switchable.
///
/// The hint names what the request DISCLOSES rather than describing the
/// feature: "checks for updates" is true of every app and tells a person
/// nothing they could weigh. What matters here is that asking github.com is an
/// outbound connection that says this device runs xVeil, and from what address
/// — in a deniable messenger that is the fact worth putting on the screen.
///
/// The offer is a link, not a download. This app installs nothing on its own:
/// what it can honestly do is say a newer release exists and open the page
/// where a person decides.
class AppUpdateTile extends ConsumerStatefulWidget {
  const AppUpdateTile({super.key});

  @override
  ConsumerState<AppUpdateTile> createState() => _AppUpdateTileState();
}

class _AppUpdateTileState extends ConsumerState<AppUpdateTile> {
  bool _busy = false;
  String? _notice;

  Future<void> _checkNow() async {
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await ref.read(appUpdateProvider.notifier).checkNow();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openRelease(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        setState(() => _notice = AppL10n.of(context).linkOpenFailed);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _notice = shownCause(error, kind: 'update-open'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final enabled = ref.watch(updateCheckEnabledProvider);
    final update = ref.watch(appUpdateProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.system_update_outlined),
          title: Text(l.updateCheckSwitch),
          subtitle: Text(l.updateCheckHint),
          isThreeLine: true,
          value: enabled,
          onChanged: _busy
              ? null
              : (value) =>
                    ref.read(updateCheckEnabledProvider.notifier).set(value),
        ),
        if (update != null)
          ListTile(
            leading: Icon(Icons.download_outlined, color: scheme.primary),
            title: Text(l.updateAvailable(update.tag)),
            subtitle: Text(l.updateOpenRelease),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => _openRelease(update.url),
          )
        else
          ListTile(
            leading: const Icon(Icons.check_circle_outline),
            // Three states, not two. "Up to date" is a claim about the
            // RELEASE FEED, and the stamp cannot support it: the stamp is
            // written BEFORE the request — deliberately, so a device that
            // cannot reach github.com does not ask on every launch — so its
            // presence says an attempt was made and nothing about how it went.
            // A failed check used to read as up to date (report16 XV-15).
            title: Text(
              switch ((
                ref.watch(updateLastCheckProvider).value,
                ref.watch(appUpdateProvider.notifier).lastReached,
              )) {
                (null, _) => l.updateNotChecked,
                (_, false) => l.updateCouldNotCheck,
                _ => l.updateUpToDate,
              },
            ),
          ),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(_notice!, style: TextStyle(color: scheme.error)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _checkNow,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(_busy ? l.updateChecking : l.updateCheckNow),
            ),
          ),
        ),
      ],
    );
  }
}
