// Taking an identity out of a transfer archive, before there is one.
//
// The export screen promises this in as many words — "a clean install becomes
// this device from one archive, without the recovery phrase" — and the app had
// no way to keep the promise. An identity-bearing archive is applied only when
// the device holds no identity and no node config, which is true strictly
// before setup finishes; and the importer lived only in Settings, which needs
// a finished setup to open. Two ends of a circle, with the person outside it.
//
// WHY THIS STEP ONLY TAKES THE IDENTITY. The rest of the archive — the
// conversations, the files, the settings — is applied by the device-sync
// appliers, and those are registered by the group service, which needs a
// signer, which needs an identity. So the merge genuinely cannot run before
// the identity exists; the order is not a preference. This step therefore does
// the half that must come first, and the ordinary importer does the half that
// must come second, from the same file.
//
// No file is read here. Real IO inside `testWidgets` does not fail, it hangs,
// so the reading is the caller's and this widget is handed what was read.

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// What an archive says about itself, as far as this step needs it.
class ArchivePreview {
  const ArchivePreview({
    required this.nodeIdHex,
    required this.createdMs,
    required this.includesIdentity,
    required this.sealed,
    required this.identityToml,
  });

  final String nodeIdHex;
  final int createdMs;
  final bool includesIdentity;

  /// Whether it was written under a password.
  final bool sealed;

  /// The node config it carries, or null when it carries none. Read by the
  /// caller, which owns the file.
  final String? identityToml;
}

/// Picks an archive, reads its header and its identity, or reports why not.
typedef ArchiveOpener =
    Future<ArchivePreview?> Function({required String? password});

class ArchiveRestoreStep extends StatefulWidget {
  const ArchiveRestoreStep({
    super.key,
    required this.open,
    required this.onIdentity,
  });

  /// Asks for a file and reads it. Null means nothing was chosen. Throwing
  /// means it could not be read as an archive, which this step reports rather
  /// than swallows.
  final ArchiveOpener open;

  /// The node config the archive carried. The ceremony stores it before the
  /// node boots, which is the whole point of doing this here.
  final void Function(String identityToml) onIdentity;

  @override
  State<ArchiveRestoreStep> createState() => _ArchiveRestoreStepState();
}

class _ArchiveRestoreStepState extends State<ArchiveRestoreStep> {
  final _password = TextEditingController();
  ArchivePreview? _preview;
  bool _bad = false;
  bool _needsPassword = false;
  bool _busy = false;

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _bad = false;
    });
    try {
      final preview = await widget.open(
        password: _password.text.isEmpty ? null : _password.text,
      );
      if (!mounted) return;
      setState(() {
        _preview = preview;
        // A sealed archive whose password has not been typed yet is not a
        // broken file. Saying so, rather than "damaged", is the difference
        // between someone typing their password and someone giving up.
        _needsPassword = preview != null && preview.sealed && _password.text.isEmpty;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _preview = null;
          _bad = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final preview = _preview;
    final usable = preview != null && preview.includesIdentity &&
        (preview.identityToml ?? '').isNotEmpty;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l.onboardArchiveTitle,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text(l.onboardArchiveBody),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: l.onboardArchivePasswordLabel,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _choose,
            icon: const Icon(Icons.folder_open),
            label: Text(l.onboardArchivePick),
          ),
          if (preview != null) ...[
            const SizedBox(height: 8),
            Text(
              l.onboardArchiveChosen(
                // Clipped, not assumed to be 64 characters. The header is
                // written by whoever made the file, and a short id there must
                // not take the screen down before it can say what is wrong
                // with the archive.
                preview.nodeIdHex.length <= 16
                    ? preview.nodeIdHex
                    : preview.nodeIdHex.substring(0, 16),
                DateTime.fromMillisecondsSinceEpoch(
                  preview.createdMs,
                ).toLocal().toString().split('.').first,
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            // An archive without an identity is not a failure of this file — it
            // is the wrong door. Say which door, rather than refusing flatly.
            if (!preview.includesIdentity) ...[
              const SizedBox(height: 8),
              Text(
                l.onboardArchiveNoIdentity,
                style: TextStyle(color: scheme.error),
              ),
            ],
          ],
          if (_needsPassword) ...[
            const SizedBox(height: 8),
            Text(
              l.transferImportPasswordTitle,
              style: TextStyle(color: scheme.error),
            ),
          ],
          if (_bad) ...[
            const SizedBox(height: 8),
            Text(l.onboardArchiveBad, style: TextStyle(color: scheme.error)),
          ],
          const SizedBox(height: 16),
          // Said BEFORE the step is taken, not after. Someone who presses the
          // button is gone from here, and a sentence shown to a screen they
          // have already left explains nothing — least of all where the
          // conversations they came for have gone.
          Text(
            l.onboardArchiveMergeLater,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: usable && !_busy
                ? () => widget.onIdentity(preview.identityToml!)
                : null,
            child: Text(l.onboardArchiveContinue),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}
