// Restoring an identity from its recovery certificate, before a node exists.
//
// This is the only arrangement in which a sovereign identity actually comes
// back. The 24 words fix the Ed25519 half of the hybrid master and nothing
// else — the Falcon half is drawn at random when the credential is made — so
// restoring from words alone succeeds into a DIFFERENT identity, at an address
// nobody who knows you holds. `veil_stack` states it in those words, and the
// boot path has always had the right entry for the other case:
// `provisionIdentityFromCertificate(certificate, code, …)`.
//
// What was missing was a way to REACH it. The certificate could only be handed
// to the app from Settings → Devices, which needs an identity to open — and by
// then the node had already booted under the classic identity, so the
// certificate arrived after the thing it was supposed to decide. Here it
// arrives first: the credential is stored before the container's node ever
// starts, and the node provisions as the identity the certificate names.
//
// THE SECRET HERE IS THE CODE, NOT THE PHRASE. An XVRC is re-wrapped under its
// own high-entropy code precisely so the exported file is not openable by the
// words. Asking for the phrase here would fail on a correct certificate, which
// is how someone concludes their backup is worthless.

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/ids.dart';
import '../../domain/sovereign_recovery.dart';
import '../../l10n/app_localizations.dart';

/// Reads a certificate file and its code, and hands both back.
class CertificateRestoreInput extends StatefulWidget {
  const CertificateRestoreInput({super.key, required this.onSubmit, this.pick});

  /// The certificate bytes and the code that opens it. The caller stores the
  /// credential before the node boots and passes the code as the boot secret.
  final void Function(Uint8List certificate, String code) onSubmit;

  /// Picks a file and returns its CONTENTS, or null if nothing was chosen.
  ///
  /// Contents rather than a path, so the widget performs no file IO of its
  /// own. That is not tidiness: real IO inside `testWidgets` does not fail, it
  /// HANGS — stream events are never delivered in fake time and
  /// `pumpAndSettle` waits ten minutes before saying something unrelated. The
  /// reading belongs outside, where a test can hand over a string.
  final Future<String?> Function()? pick;

  @override
  State<CertificateRestoreInput> createState() =>
      _CertificateRestoreInputState();
}

class _CertificateRestoreInputState extends State<CertificateRestoreInput> {
  final _code = TextEditingController();
  SovereignRecoveryCertificate? _certificate;
  bool _bad = false;

  @override
  void dispose() {
    _code.clear();
    _code.dispose();
    super.dispose();
  }

  Future<String?> _pickContents() async {
    if (widget.pick != null) return widget.pick!();
    final picked = await FilePicker.pickFiles(withReadStream: false);
    final path = picked?.files.single.path;
    if (path == null) return null;
    return File(path).readAsString();
  }

  Future<void> _choose() async {
    String? text;
    try {
      text = await _pickContents();
    } catch (_) {
      // An unreadable file is the same answer to this person as an
      // unparseable one: this is not the certificate.
      text = null;
      if (mounted) {
        setState(() {
          _certificate = null;
          _bad = true;
        });
      }
      return;
    }
    if (text == null || !mounted) return;
    setState(() => _bad = false);
    try {
      // The file holds the TEXT form — it carries its own
      // `xveil-recovery:v1:` prefix, so a copy that was renamed or pasted
      // through a chat still identifies itself. `parse` checks the magic and
      // the version before anything downstream sees it.
      final certificate = SovereignRecoveryCertificate.parse(text);
      if (!mounted) return;
      setState(() => _certificate = certificate);
    } catch (_) {
      if (mounted) {
        setState(() {
          _certificate = null;
          _bad = true;
        });
      }
    }
  }

  /// Only the ends are trimmed. The code is base64url, where case is content:
  /// folding it the way a phrase is folded destroys a correct code.
  String get _typedCode => _code.text.trim();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final certificate = _certificate;
    final ready = certificate != null && _typedCode.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l.onboardRestoreCertificateBody),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _choose,
          icon: const Icon(Icons.folder_open),
          label: Text(l.onboardRestorePickCertificate),
        ),
        if (certificate != null) ...[
          const SizedBox(height: 8),
          // The address it names, so a person with two certificates can tell
          // which one they just chose before they commit to it.
          Text(
            l.onboardRestoreCertificateChosen(
              _shortId(certificate.nodeId),
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (_bad) ...[
          const SizedBox(height: 8),
          Text(
            l.onboardRestoreCertificateBad,
            style: TextStyle(color: scheme.error),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _code,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: l.onboardRestoreCodeLabel,
            helperText: l.onboardRestoreCodeHint,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: ready
              ? () => widget.onSubmit(certificate.bytes, _typedCode)
              : null,
          child: Text(l.onboardRestoreCertificateSubmit),
        ),
      ],
    );
  }
}

String _shortId(NodeId id) => id.hex.substring(0, 16);
