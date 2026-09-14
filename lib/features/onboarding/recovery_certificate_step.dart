// The recovery certificate, offered while the phrase is still on screen.
//
// It used to be offered AFTER onboarding finished: the router pushed the
// devices screen with `recovery=1`, and that sheet asked the person to type
// their 24-word phrase back in — a phrase they had written on paper thirty
// seconds earlier and now had to re-enter into a field that shows dots. Two
// things followed. The step reads as an interrogation rather than part of
// making an identity, and a phrase that arrives by paste with a newline in it
// is simply the wrong key, refused with no reason given.
//
// Here the phrase is in hand. Nothing is asked for, and nothing can be
// mistyped: the ceremony already generated these words and is showing them.
//
// WHY THIS CAN BE MINTED BEFORE THE IDENTITY EXISTS. The hybrid master is
// derived from the phrase alone — `decode_master_seed_from_phrase` →
// `derive_master_sk_ed25519` → `hybrid512_keypair_from_ed25519_seed`, with
// randomness only in the encryption salt. So the credential built here holds
// the same key, and names the same node id, as the one the first node boot
// will derive. A certificate made now restores exactly the identity that is
// about to exist; it does not need the container, the node, or a group.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;

import '../../core/ids.dart';
import '../../core/secret_display.dart';
import '../../core/secure_screen.dart';
import '../../domain/sovereign_recovery.dart';
import '../../l10n/app_localizations.dart';

/// What minting produced, held only for as long as this step is on screen.
class MintedRecovery {
  const MintedRecovery({
    required this.certificate,
    required this.code,
    required this.nodeId,
  });

  /// The `xveil-recovery:v1:` text form — what is written to the file, and
  /// what the import path parses.
  final String certificate;

  /// The independent 256-bit code that unlocks it. Never written into the
  /// same file: the pair is the whole capability.
  final String code;

  final NodeId nodeId;
}

/// Mint a certificate and its code from the phrase, with no container in play.
///
/// Separate from the widget because it is the part worth testing and the part
/// that must not drift: it is the only place in the app that builds a
/// sovereign credential from a phrase the person has not yet been asked to
/// type, and getting the order wrong (code after export, say) would hand back
/// a code that unlocks nothing.
MintedRecovery mintRecoveryFromPhrase(String phrase) {
  final bundle = veil.createHybrid512SovereignBundle(phrase);
  final code = veil.generateSovereignRecoveryCode();
  final bytes = veil.exportSovereignRecoveryCertificate(bundle, phrase, code);
  final certificate = SovereignRecoveryCertificate.fromBytes(bytes);
  return MintedRecovery(
    certificate: certificate.toText(),
    code: code,
    nodeId: certificate.nodeId,
  );
}

/// The ceremony step: say what the three things are, make the pair, let it be
/// saved — and let it be declined, saying where to go instead.
class RecoveryCertificateStep extends StatefulWidget {
  const RecoveryCertificateStep({
    super.key,
    required this.phrase,
    required this.onDone,
    this.mint = mintRecoveryFromPhrase,
  });

  /// The words the previous step displayed, already normalized by being
  /// generated rather than typed.
  final String phrase;

  /// Leaves the step. `saved` is whether a copy of the certificate actually
  /// reached a file — read back after writing, not merely written — so the
  /// standing reminder can stay up for someone who declined.
  final void Function({required bool saved}) onDone;

  /// Injectable so a widget test can exercise the screen without the native
  /// library, which is not loaded in the test host.
  final MintedRecovery Function(String phrase) mint;

  @override
  State<RecoveryCertificateStep> createState() =>
      _RecoveryCertificateStepState();
}

class _RecoveryCertificateStepState extends State<RecoveryCertificateStep> {
  MintedRecovery? _minted;
  bool _busy = false;
  bool _failed = false;
  bool _saved = false;
  bool _nagged = false;

  Future<void> _create() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      // Two Argon2 passes on this isolate. The progress bar below is up
      // before it starts, for the same reason the finish step paints a frame
      // before creating the container: a second of a frozen window reads as a
      // crash.
      await Future<void>.delayed(Duration.zero);
      final minted = widget.mint(widget.phrase);
      if (!mounted) return;
      setState(() => _minted = minted);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Write the certificate out. The CODE is deliberately not in the file: the
  /// two together reconstruct the identity, so a backup carrying both is a
  /// backup of the whole capability.
  Future<void> _save() async {
    final minted = _minted;
    if (minted == null || _busy) return;
    final suggested =
        'xveil-recovery-${minted.nodeId.hex.substring(0, 8)}.xvrc';
    final dest = await FilePicker.saveFile(fileName: suggested);
    if (dest == null || !mounted) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await File(dest).writeAsString(minted.certificate, flush: true);
      // Read back before calling it saved. A write that returned without
      // error and left nothing behind — a full disk, a sandbox that swallowed
      // the path — would otherwise retire the only reminder this person has
      // that their identity holds no copy.
      final wrote = await File(dest).readAsString();
      if (wrote.trim() != minted.certificate.trim()) {
        throw StateError('the certificate did not read back as written');
      }
      if (!mounted) return;
      setState(() => _saved = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Leaving with a certificate on screen and none on disk is the one case
  /// worth interrupting: the pair exists nowhere else and is gone with this
  /// widget. Said once — a second press goes through, because it is their
  /// identity and their decision.
  void _continue() {
    if (_minted != null && !_saved && !_nagged) {
      setState(() => _nagged = true);
      return;
    }
    widget.onDone(saved: _saved);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final minted = _minted;
    // The one screen in onboarding that can show a whole recovery capability
    // at once. Same guard as the settings sheet, for the same reason: a
    // screen recording of it reconstructs the signer.
    return SecureScreenGuard(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.onboardCertTitle, style: textTheme(context).headlineSmall),
            const SizedBox(height: 12),
            Text(l.onboardCertWhy),
            const SizedBox(height: 16),
            _Role(icon: Icons.article_outlined, text: l.onboardCertRolePhrase),
            _Role(icon: Icons.description_outlined, text: l.onboardCertRoleFile),
            _Role(icon: Icons.key_outlined, text: l.onboardCertRoleCode),
            const SizedBox(height: 16),
            if (minted == null) ...[
              FilledButton.icon(
                onPressed: _busy ? null : _create,
                icon: const Icon(Icons.verified_user_outlined),
                label: Text(l.onboardCertCreate),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : () => widget.onDone(saved: false),
                child: Text(l.onboardCertSkip),
              ),
              const SizedBox(height: 8),
              Text(
                l.onboardCertLater,
                style: textTheme(context).bodySmall,
              ),
            ] else ...[
              Text(
                l.devicesCertificateWarning,
                style: TextStyle(color: scheme.error),
              ),
              const SizedBox(height: 12),
              Text('${l.nodeIdLabel}: ${minted.nodeId.hex}'),
              const SizedBox(height: 12),
              SecretText(minted.certificate, maxLines: 5, fontSize: 10),
              SecretCopyButton(
                label: l.devicesCopyCertificate,
                value: () => minted.certificate,
                copiedMessage: l.devicesCertificateCopiedClears,
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.save_alt),
                label: Text(l.devicesSaveCertificate),
              ),
              const SizedBox(height: 12),
              SecretText(minted.code),
              SecretCopyButton(
                label: l.devicesCopyCode,
                value: () => minted.code,
                copiedMessage: l.devicesCodeCopiedClears,
              ),
              const SizedBox(height: 12),
              if (_nagged && !_saved)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    l.onboardCertNotSavedYet,
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              FilledButton(
                onPressed: _busy ? null : _continue,
                child: Text(l.onboardCertContinue),
              ),
            ],
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
            if (_failed)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  l.onboardCertFailed,
                  style: TextStyle(color: scheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

TextTheme textTheme(BuildContext context) => Theme.of(context).textTheme;

class _Role extends StatelessWidget {
  const _Role({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.outline),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
