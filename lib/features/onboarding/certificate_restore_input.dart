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
//
// AND THE CODE IS CHECKED HERE, AGAINST THE CERTIFICATE. Reported from the
// field: "код восстановления могу ввести любой (первый раз ввел фразу и
// получил другую личность)". That was exactly what happened. Nothing on this
// screen opened the certificate, so any non-empty string walked through; the
// wrong one then failed deep in the boot, where the failure was swallowed —
// `ensureSovereignIdentity` returns null on a provisioning error, and the node
// comes up on the device key it had just mined. A working app, a new address,
// and not a word about it. The code is Argon2id-wrapped, so checking it means
// actually opening the certificate, which is why this is the only place it can
// be done before anything is committed.

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:veil_flutter/veil_ffi.dart' as veil;

import '../../core/ids.dart';
import '../../core/log.dart';
import '../../domain/sovereign_recovery.dart';
import '../../l10n/app_localizations.dart';

/// Whether [code] actually opens [certificate].
///
/// Injectable because the real one is Argon2id over a native handle: a widget
/// test cannot run it, and a widget test that skipped it would be asserting
/// the very thing this screen exists to stop.
typedef RecoveryCodeCheck =
    Future<bool> Function(Uint8List certificate, String code);

/// The real check: open the certificate with the code and throw away the
/// signer. Nothing is kept — the question is only whether it opens.
Future<bool> nativeRecoveryCodeOpens(
  Uint8List certificate,
  String code,
) async {
  try {
    final signer = veil.VeilSovereignSigner.openRecoveryCertificate(
      certificate,
      code,
    );
    signer.close();
    return true;
  } on Object catch (e) {
    // Every way this fails is the same answer to the person in front of it:
    // this code does not open this certificate. The reason is not theirs to
    // debug, and the message must not vary with it — a wrong code and a
    // tampered file are indistinguishable by design (ChaCha20-Poly1305 over
    // an AAD that binds the node id).
    devLog(() => 'xVeil[restore]: the code did not open the certificate: $e');
    return false;
  }
}

/// Reads a certificate file and its code, and hands both back.
class CertificateRestoreInput extends StatefulWidget {
  const CertificateRestoreInput({
    super.key,
    required this.onSubmit,
    this.pick,
    this.check = nativeRecoveryCodeOpens,
  });

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

  /// Proves the code before the install commits to it.
  final RecoveryCodeCheck check;

  @override
  State<CertificateRestoreInput> createState() =>
      _CertificateRestoreInputState();
}

class _CertificateRestoreInputState extends State<CertificateRestoreInput> {
  final _code = TextEditingController();
  final _pasted = TextEditingController();
  SovereignRecoveryCertificate? _certificate;
  bool _bad = false;
  bool _codeRefused = false;
  bool _checking = false;

  @override
  void dispose() {
    _code.clear();
    _code.dispose();
    _pasted.clear();
    _pasted.dispose();
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
    _accept(text);
  }

  /// One road in for both ways of holding a certificate.
  ///
  /// A copy and a download are the same artefact — the export sheet offers a
  /// copy button beside the save button — so they must not have different
  /// fates here. `parse` carries the tolerance for how a copy arrives.
  void _accept(String text) {
    setState(() {
      _bad = false;
      _codeRefused = false;
    });
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

  Future<void> _submit(SovereignRecoveryCertificate certificate) async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _codeRefused = false;
    });
    final code = _typedCode;
    final opens = await widget.check(certificate.bytes, code);
    if (!mounted) return;
    setState(() => _checking = false);
    if (!opens) {
      // STOPS HERE. Letting a refused code through is not a smaller failure
      // than refusing a good one — it is the larger one: the boot mints a
      // device key, the node comes up at an address nobody holds, and the
      // certificate that would have restored the real identity is now sitting
      // beside an install that looks finished.
      setState(() => _codeRefused = true);
      return;
    }
    widget.onSubmit(certificate.bytes, code);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final certificate = _certificate;
    final ready = certificate != null && _typedCode.isNotEmpty && !_checking;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l.onboardRestoreCertificateBody),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _checking ? null : _choose,
          icon: const Icon(Icons.folder_open),
          label: Text(l.onboardRestorePickCertificate),
        ),
        const SizedBox(height: 12),
        // The other half of how people actually hold this. The sheet that
        // creates a certificate offers a copy button, and what is copied gets
        // pasted — into a password manager, a note, a message to oneself. A
        // screen that only takes files tells those people, wrongly, that they
        // have nothing.
        TextField(
          controller: _pasted,
          minLines: 2,
          maxLines: 4,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (value) {
            final text = value.trim();
            if (text.isEmpty) {
              setState(() {
                _certificate = null;
                _bad = false;
                _codeRefused = false;
              });
              return;
            }
            _accept(text);
          },
          decoration: InputDecoration(
            labelText: l.onboardRestorePasteCertificate,
            helperText: l.onboardRestorePasteCertificateHint,
            helperMaxLines: 3,
          ),
        ),
        if (certificate != null) ...[
          const SizedBox(height: 8),
          // The address it names, so a person with two certificates can tell
          // which one they just chose before they commit to it.
          Text(
            l.onboardRestoreCertificateChosen(_shortId(certificate.nodeId)),
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
          onChanged: (_) => setState(() => _codeRefused = false),
          decoration: InputDecoration(
            labelText: l.onboardRestoreCodeLabel,
            helperText: l.onboardRestoreCodeHint,
          ),
        ),
        if (_codeRefused) ...[
          const SizedBox(height: 8),
          Text(
            l.onboardRestoreCodeRefused,
            style: TextStyle(color: scheme.error),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: ready ? () => _submit(certificate) : null,
          child: Text(l.onboardRestoreCertificateSubmit),
        ),
        if (_checking)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }
}

String _shortId(NodeId id) => id.hex.substring(0, 16);
