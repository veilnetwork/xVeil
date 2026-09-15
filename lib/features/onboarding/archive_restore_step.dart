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

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/log.dart';
import '../../data/node/sovereign_identity_material.dart'
    show isRecoveryCertificate;
import 'credential_check.dart';
import '../../l10n/app_localizations.dart';

/// What an archive says about itself, as far as this step needs it.
class ArchivePreview {
  const ArchivePreview({
    required this.nodeIdHex,
    required this.createdMs,
    required this.includesIdentity,
    required this.sealed,
    required this.identityToml,
    this.credential,
  });

  final String nodeIdHex;
  final int createdMs;
  final bool includesIdentity;

  /// Whether it was written under a password.
  final bool sealed;

  /// The node config it carries, or null when it carries none. Read by the
  /// caller, which owns the file.
  final String? identityToml;

  /// The sovereign credential it carries, still encrypted.
  ///
  /// This is the half that is actually the identity. Null for every archive
  /// written before the exporter carried one — those restore the transport
  /// key and nothing else, which is exactly the report this field exists to
  /// answer: "восстановилась другая личность (другой node_id)".
  final Uint8List? credential;

  /// Which secret opens [credential] — decided by its own magic, not by what
  /// the screen assumes. An XVSB was wrapped under the 24 words; an XVRC was
  /// re-wrapped under a high-entropy code precisely so the words do not open
  /// it. Asking for the wrong one fails on a perfectly good archive.
  bool get credentialIsCertificate =>
      credential != null && isRecoveryCertificate(credential!);
}

/// Picks an archive, reads its header and its identity, or reports why not.
typedef ArchiveOpener =
    Future<ArchivePreview?> Function({required String? password});

class ArchiveRestoreStep extends StatefulWidget {
  const ArchiveRestoreStep({
    super.key,
    required this.open,
    required this.onIdentity,
    this.check = nativeCredentialOpens,
  });

  /// Asks for a file and reads it. Null means nothing was chosen. Throwing
  /// means it could not be read as an archive, which this step reports rather
  /// than swallows.
  final ArchiveOpener open;

  /// What the archive carried, and the secret that opens the credential.
  ///
  /// Both halves, because they are two different keys doing two different
  /// jobs: the node config is what a peer authenticates against, the
  /// credential is what the identity is NAMED by. The ceremony stores both
  /// before the node boots, which is the whole point of doing this here.
  final void Function(String identityToml, Uint8List? credential, String secret)
  onIdentity;

  /// Proves the secret before the install commits to it.
  final CredentialSecretCheck check;

  @override
  State<ArchiveRestoreStep> createState() => _ArchiveRestoreStepState();
}

class _ArchiveRestoreStepState extends State<ArchiveRestoreStep> {
  final _password = TextEditingController();
  ArchivePreview? _preview;
  bool _bad = false;

  /// Why it would not open, shown under the plain refusal.
  String? _badReason;

  /// The secret that opens the archive's credential — the 24 words, or the
  /// certificate's own code. Not the archive password: that one unwraps the
  /// FILE, this one unwraps the identity inside it, and they are different
  /// secrets protecting different things.
  final _secret = TextEditingController();
  bool _secretRefused = false;
  bool _checking = false;
  bool _needsPassword = false;
  bool _busy = false;

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    _secret.clear();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _bad = false;
      _badReason = null;
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
    } catch (e) {
      // WHAT WENT WRONG, not just that something did.
      //
      // Reported from the field: an archive that this app's own reader opens
      // correctly — header parsed, identity extracted, 883 bytes of it — was
      // refused here as "damaged". So the failure is not in the parsing, and
      // "damaged" was the only thing anyone could see. A single opaque
      // sentence is the reason that report could not be acted on.
      //
      // The reason is shown small and last, under the plain message. It is a
      // path or an exception type and it costs the person nothing to ignore,
      // while being the whole difference between "my backup is ruined" and a
      // defect somebody can find.
      devLog(() => 'xVeil[onboard-archive]: could not open the archive: $e');
      if (mounted) {
        setState(() {
          _preview = null;
          _bad = true;
          _badReason = e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _take(ArchivePreview preview) async {
    final credential = preview.credential;
    if (credential == null) {
      // An older archive: the node config is all it has. Taken as before, and
      // the ceremony says plainly that the identity is not in it.
      widget.onIdentity(preview.identityToml!, null, '');
      return;
    }
    setState(() {
      _checking = true;
      _secretRefused = false;
    });
    final secret = _secret.text.trim();
    final opens = await widget.check(credential, secret);
    if (!mounted) return;
    setState(() => _checking = false);
    if (!opens) {
      // STOPS HERE. Letting a refused secret through takes the node config
      // without the identity, which is a working install at an address nobody
      // writes to — the failure this whole step was reported for.
      setState(() => _secretRefused = true);
      return;
    }
    widget.onIdentity(preview.identityToml!, credential, secret);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final preview = _preview;
    final usable =
        preview != null &&
        preview.includesIdentity &&
        (preview.identityToml ?? '').isNotEmpty &&
        // An archive that carries the credential cannot be taken without the
        // secret that opens it. Taking the node config alone is exactly the
        // half-restore this step exists to stop.
        (preview.credential == null || _secret.text.trim().isNotEmpty);
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
            if (_badReason != null) ...[
              const SizedBox(height: 4),
              Text(
                _badReason!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
          if (preview?.credential != null) ...[
            const SizedBox(height: 16),
            // WHICH secret, named by the credential rather than guessed. An
            // XVRC is opened by its code and an XVSB by the words, and asking
            // for the wrong one fails on a perfectly good archive.
            TextField(
              controller: _secret,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() => _secretRefused = false),
              decoration: InputDecoration(
                labelText: preview!.credentialIsCertificate
                    ? l.onboardRestoreCodeLabel
                    : l.onboardArchiveSecretPhrase,
                helperText: l.onboardArchiveSecretWhy,
                helperMaxLines: 3,
              ),
            ),
            if (_secretRefused) ...[
              const SizedBox(height: 8),
              Text(
                l.onboardRestoreCodeRefused,
                style: TextStyle(color: scheme.error),
              ),
            ],
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
            onPressed: usable && !_busy && !_checking
                ? () => _take(preview)
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
