import 'dart:async';

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/clipboard_secret.dart';
import '../../core/log.dart';
import '../../core/secure_screen.dart';
import '../../data/identity/veil_identity.dart';
import '../../data/node/bundled_seeds.dart';
import '../../data/node/bundled_seeds_prefs.dart';
import '../../domain/identity.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/providers.dart';
import 'bundled_seeds_choice.dart';
import '../../state/data_import.dart';
import 'archive_restore_step.dart';
import 'certificate_restore_input.dart';
import 'recovery_certificate_step.dart';
import 'recovery_phrase_input.dart';

/// First-launch wizard. Steps:
///   0 welcome → 1 choose path → 2 recovery phrase → 3 storage mode →
///   7 network entry → 4 password
///   restore:             1 → 5 phrase entry → 3 → 7 → 4
///   link:                1 → 6 what happens → 3 → 7 → 4
///
/// Create and restore both drive the deterministic first-boot identity
/// derivation from the phrase (P2/P3). A file-based backup action is
/// intentionally absent: there is no matching secure export format, and
/// writing identity documents to disk would violate the deniable canon.
///
/// The link path mints NO phrase: the identity it creates is a temporary one
/// (origin `mined`), enough to boot a node and be adopted into an existing
/// device group. It still creates a container — the node identity lives INSIDE
/// the space, which is the point of deniable storage, not a gap in it. What it
/// skips is the sovereign ritual: a device that is about to be governed by
/// someone else's device group must not be told to write down 24 words that
/// restore an identity it will never own.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({
    super.key,
    this.validatePhrase = veilPhraseValid,
    this.generatePhrase = veilGeneratePhrase,
  });

  /// Injectable so widget tests can drive the restore path without the
  /// native library; production uses the FFI-backed validator.
  final bool Function(String phrase) validatePhrase;

  /// Injectable for the same reason, and for the opposite case: the generator
  /// answers null when the native library is absent, and the screen then shows
  /// PLACEHOLDER words with a warning that they restore nothing.
  ///
  /// The test for that warning used to reach it by the library being missing —
  /// true in CI and false in production, so it asserted a state it could not
  /// choose. A path this important is worth being able to ask for.
  final String? Function() generatePhrase;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int _step = 0;
  List<String> _phrase = const [];
  bool _phraseConfirmed = false;

  /// The user chose to join an existing device group rather than own an
  /// identity. Reset by BOTH other paths: a user who backs out of the link
  /// step and picks create/restore instead must not silently finish as a
  /// device waiting to be adopted.
  bool _joinExisting = false;
  StorageMode _mode = StorageMode.hiddenSpace;

  /// Whether this identity may reach the network through the project's shared
  /// seed nodes. Defaults to yes — the same answer every install made before
  /// there was a question — so someone who walks through without reading has
  /// the app that works, and only a deliberate tap takes it off the network.
  bool _useBundledSeeds = kBundledSeedsDefault;

  /// Whether the ceremony's certificate step actually put a copy on disk.
  ///
  /// Not "whether it was offered" and not "whether one was minted": the file
  /// is read back before this turns true. It decides one thing — whether the
  /// router still pushes the devices screen at the end to ask again. Someone
  /// who declined has just been asked and told where to go; asking twice in
  /// thirty seconds is nagging, and the standing reminder on that screen is
  /// what keeps the matter open for them.
  bool _certificateSaved = false;

  /// What the certificate step minted — the credential AND the pair that
  /// restores it.
  ///
  /// Kept on THIS screen rather than inside the step so that stepping back to
  /// the words and forward again reuses it. Minting twice would draw a second
  /// random Falcon half, rename the identity, and leave a certificate already
  /// written to disk naming an identity that will never exist.
  MintedRecovery? _minted;

  /// A recovery certificate the person handed in on the restore path, and the
  /// code that opens it.
  ///
  /// It has to be stored BEFORE the node boots: the node provisions from the
  /// credential the container holds, so a certificate that arrives afterwards
  /// is a certificate the identity was already decided without. That is the
  /// whole reason this lives here and not in a settings screen — and the code
  /// travels with it because an XVRC is opened by the code, never by the
  /// words.
  Uint8List? _restoreCertificate;
  String _restoreCode = '';

  /// The node config an archive carried, taken before this install has one.
  ///
  /// Stored by the ceremony before the node boots, exactly as a certificate
  /// is: the node provisions from what the container holds, so an identity
  /// that arrives afterwards is one the boot was already decided without.
  String? _restoreNodeConfig;
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _go(int step) => setState(() => _step = step);

  /// Whether [_phrase] is the REAL native master phrase (P2): the node
  /// identity derives from it and restore works. False only when the native
  /// generator is unavailable (loopback/test builds) — then the placeholder
  /// words are shown and the identity is minted randomly, as before.
  bool _realPhrase = false;

  /// The phrase came from the PERSON, not from us — this identity already
  /// exists somewhere. It decides whether this device takes the phrase's own
  /// keypair as its node key (the first device does) or mints one of its own
  /// (every later device must, or two devices of one identity are one node).
  bool _restoring = false;

  /// Set when this device could not produce a recovery phrase, so no identity
  /// was created. Shown on the choice step, where the person still is.
  String? _createRefusal;

  void _startCreate() {
    _restoring = false;
    final real = widget.generatePhrase();
    // FAIL CLOSED (report17, onboarding fallback).
    //
    // When the native generator has nothing to give, this used to hand over 24
    // words drawn from a list of 28 kept in this file, show a warning, and let
    // the person carry on. They wrote down something that looks exactly like a
    // recovery phrase, confirmed it, and got an identity those words restore
    // NOTHING of — the one failure a recovery phrase exists to prevent, made
    // to look like the ordinary path. The warning was in the same screen as
    // the words, so it competed with them.
    //
    // An identity is not created at all now. There is nothing useful to do
    // with a phraseless one, and the person can try again once whatever kept
    // the generator from answering is dealt with.
    if (real == null) {
      setState(() => _createRefusal = 'no-phrase');
      return;
    }
    _realPhrase = true;
    _phrase = real.split(' ');
    _phraseConfirmed = false;
    _joinExisting = false;
    _go(2);
  }

  /// Join an existing device group: no phrase is generated and none is asked
  /// for. The identity minted at the end is temporary — it carries this device
  /// onto the network so the existing device can approve it.
  void _startLink() {
    // Reset like the create path does. Reaching this after backing out of the
    // restore step would otherwise carry `_restoring` here, and a device that
    // links has no phrase at all — the flag is inert today only because the
    // derivation it steers sits behind a "phrase is not empty" guard.
    _restoring = false;
    _realPhrase = false;
    _phrase = const [];
    _phraseConfirmed = false;
    _joinExisting = true;
    _go(6);
  }

  /// The user typed a phrase that passed the native validator: it feeds the
  /// SAME deterministic first-boot derivation as the create path, so the
  /// node identity it produces is the one the phrase was written down for.
  void _restoreWith(String phrase) {
    _restoring = true;
    _phrase = phrase.split(' ');
    _realPhrase = true;
    _joinExisting = false;
    _restoreCertificate = null;
    _restoreCode = '';
    _go(3);
  }

  /// Pick an archive and read what it says about itself.
  ///
  /// The reading lives here rather than in the step for one reason: real file
  /// IO inside `testWidgets` does not fail, it HANGS — stream events are never
  /// delivered in fake time. The widget is handed what was read.
  Future<ArchivePreview?> _openArchive({required String? password}) async {
    final picked = await FilePicker.pickFiles(withReadStream: false);
    // `.single` THROWS on an empty list, and the step reads any throw from here
    // as "this file is damaged". A picker that answers with a result carrying
    // no files — which is how some platforms report a cancelled dialog — was
    // therefore indistinguishable from a ruined backup. Cancelling is not an
    // error and must never be reported as one.
    final files = picked?.files ?? const [];
    if (files.isEmpty) return null;
    final path = files.first.path;
    if (path == null) return null;
    final file = File(path);
    // NAMED IN THE FAILURE. Everything below can throw, and the one thing that
    // makes such a throw actionable is which file it was about: a sandboxed
    // build reaches the chosen file through the picker's grant, so "cannot
    // read /Users/…/x.xveilbk" and "this is not an archive" are different
    // defects that used to print the same sentence.
    if (!await file.exists()) {
      throw FileSystemException('the chosen file is not there', path);
    }
    final header = await DataImporter.inspect(file.openRead());
    final identity = header.includesIdentity
        ? await DataImporter.readIdentity(file.openRead(), password: password)
        : null;
    return ArchivePreview(
      nodeIdHex: header.nodeIdHex,
      createdMs: header.createdMs,
      includesIdentity: header.includesIdentity,
      sealed: header.seal != null,
      identityToml: identity,
    );
  }

  /// Take the identity an archive carries, and nothing else yet.
  ///
  /// The conversations cannot come with it: they are applied by the
  /// device-sync appliers, which the group service registers, which needs a
  /// signer, which needs the identity this step is still fetching. So the
  /// merge is the second half, from the same file, once there is something to
  /// merge into — and the finished app says so rather than leaving the person
  /// to wonder where their chats went.
  void _restoreFromArchive(String identityToml) {
    _restoring = true;
    _restoreNodeConfig = identityToml;
    _restoreCertificate = null;
    _restoreCode = '';
    _phrase = const [];
    _realPhrase = false;
    _joinExisting = false;
    _go(3);
  }

  /// The other way back, and the only one that returns the SAME address.
  ///
  /// The words restore a different identity — they fix the Ed25519 half of the
  /// hybrid master and the Falcon half was drawn at random — so a person who
  /// has their certificate should never be sent down the phrase path.
  void _restoreWithCertificate(Uint8List certificate, String code) {
    _restoring = true;
    _restoreCertificate = certificate;
    _restoreCode = code;
    // No words on this path: the credential carries the master key, and the
    // secret that opens it is the code. `_realPhrase` stays false so the
    // certificate ceremony step is skipped — there is nothing to mint for an
    // identity that already exists.
    _phrase = const [];
    _realPhrase = false;
    _joinExisting = false;
    _go(3);
  }

  /// Set when a password typed on the "open what is already here" step opened
  /// nothing. Deliberately the same message whether the container is absent or
  /// the password is wrong — telling those apart is telling someone whether
  /// this device has anything on it.
  String? _openError;

  /// Open the container this device already has, instead of making another.
  ///
  /// The path back from "Начать заново", which forgets that setup happened and
  /// leaves the container untouched — and, until this existed, left no way to
  /// reach it: the four other cards all end in a NEW identity.
  Future<void> _openExisting(String password) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _openError = null;
    });
    try {
      final opened = await ref
          .read(appControllerProvider.notifier)
          .reopenExistingContainer(password);
      if (!mounted) return;
      if (!opened) {
        setState(() => _openError = AppL10n.of(context).onboardOpenExistingFailed);
      }
      // Opened: the router follows the phase out of onboarding, exactly as it
      // does after an unlock.
    } catch (e) {
      devLog(() => 'xVeil[onboarding]: reopen failed: $e');
      if (mounted) {
        setState(() => _openError = AppL10n.of(context).onboardOpenExistingFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Set when the container could not be created. Kept on screen instead of a
  /// snackbar: this is the last step, the button is disabled while it runs, and
  /// a message that slides away leaves the user pressing a dead control.
  String? _finishError;

  Future<void> _finish() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _finishError = null;
    });
    try {
      // BEFORE the container and the node exist, deliberately — which is also
      // why this one write goes to the PREFERENCE and not to a space: there is
      // no space yet. The container created by `completeOnboarding` adopts this
      // answer the first time its node is composed
      // ([bundledSeedsAllowedFor]) and owns it from then on. Writing it
      // afterwards would boot the first node on the previous answer and hand
      // the shared seeds to someone who had just declined them. The provider is
      // set in the same breath because the boot config was assembled back in
      // `main`, before the question was asked (see
      // [bundledSeedsChoiceProvider]).
      final saved = await setBundledSeedsAllowed(_useBundledSeeds);
      ref.read(bundledSeedsChoiceProvider.notifier).state = _useBundledSeeds;
      if (!saved && mounted) {
        // Say so rather than show a choice that did not stick. Not fatal: the
        // session that follows still runs on the answer just given.
        setState(() => _finishError = AppL10n.of(context).seedsSaveFailed);
      }
      await ref
          .read(appControllerProvider.notifier)
          .completeOnboarding(
            // No identity is minted here any more. This screen used to hand
            // `completeOnboarding` an Identity carrying a RANDOM node id, which
            // went into the space before any node existed and disagreed with
            // the real one forever after (audit XV-06). The node id is the
            // node's to produce.
            password: _passwordCtrl.text,
            mode: _mode,
            // WHICHEVER SECRET OPENS WHAT THIS DEVICE WILL HOLD. For a phrase
            // identity that is the words; for a certificate restore it is the
            // certificate's own code, because an XVRC is re-wrapped under a
            // high-entropy code exactly so the exported file is not openable
            // by the words. Handing the phrase to a certificate does not
            // provision a different identity — it fails, and the boot then
            // falls through to no sovereign document at all.
            identityPhrase: _restoreCertificate != null
                ? _restoreCode
                : (_realPhrase ? _phrase.join(' ') : null),
            // A RESTORE, not a first mint: this device gets a node key of its
            // own under the phrase's identity.
            restoringIdentity: _restoring,
            joinExisting: _joinExisting,
            // The ceremony already put this question to them, with the phrase
            // in hand and nothing to retype. Whatever they answered, the
            // end-of-onboarding push has nothing left to add.
            recoveryCertificateOffered: _realPhrase && _step >= 3,
            recoveryCertificateSaved: _certificateSaved,
            // THE credential, not A credential. The phrase fixes only the
            // ed25519 half of the hybrid master; the Falcon half is drawn at
            // random inside `create_hybrid512`. So whichever credential is
            // KEPT is the identity, and the certificate the person just saved
            // certifies this one. Letting the app mint its own later would
            // rename them behind a file they believe restores them.
            // The certificate a restore brought in, or the credential the
            // ceremony minted — never both, and either way it is stored before
            // the node boots so the node provisions as the identity it names.
            sovereignCredential: _restoreCertificate ?? _minted?.credential,
            // The identity an archive carried. Written before the node boots,
            // for the same reason the credential is.
            nodeConfigToml: _restoreNodeConfig,
          );
      // Router redirect takes over once phase flips to ready.
    } catch (e) {
      // Creating the container runs Argon2 and touches the filesystem; a full
      // disk or a native fault threw straight through the old code and left
      // `_busy` true forever, so the Done button never came back and the only
      // way on was to kill the app.
      devLog(() => 'xVeil[onboarding]: completeOnboarding failed: $e');
      if (mounted) {
        // One failure here is not a failure at all: the password opened a
        // container that already holds an identity, and setup declined to
        // write over it. Saying "setup failed" would send that person back to
        // try harder at the exact thing that must not succeed.
        final l = AppL10n.of(context);
        setState(
          () => _finishError = e is ContainerAlreadyHasAnIdentity
              ? l.onboardContainerInUse
              : l.onboardSetupFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _step == 0
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => _go(switch (_step) {
                  4 => 7,
                  7 => 3,
                  3 => _realPhrase ? 8 : 2,
                  8 => 2,
                  // Every step reached FROM the choice goes back to it. The
                  // archive step used to land on the welcome screen instead,
                  // which is a step backwards out of the decision rather than
                  // back into it.
                  2 || 5 || 6 || 9 || 10 => 1,
                  _ => 0,
                }),
              ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: switch (_step) {
            0 => _Welcome(onNext: () => _go(1)),
            1 => _ChoosePath(
              onCreate: _startCreate,
              onRestore: () => _go(5),
              onLink: _startLink,
              onArchive: () => _go(9),
              onOpenExisting: () => setState(() {
                _openError = null;
                _step = 10;
              }),
              refused: _createRefusal != null,
            ),
            10 => _OpenExistingStep(
              busy: _busy,
              error: _openError,
              onSubmit: _openExisting,
            ),
            9 => ArchiveRestoreStep(
              open: _openArchive,
              onIdentity: _restoreFromArchive,
            ),
            5 => _RestoreStep(
              validate: widget.validatePhrase,
              onSubmit: _restoreWith,
              onCertificate: _restoreWithCertificate,
            ),
            6 => _LinkStep(onNext: () => _go(3)),
            2 => _Recovery(
              phrase: _phrase,
              real: _realPhrase,
              confirmed: _phraseConfirmed,
              onConfirmedChanged: (v) => setState(() => _phraseConfirmed = v),
              // The certificate comes NEXT, while these words are still on
              // screen — the whole reason it can be made without asking for
              // them back. A placeholder phrase (loopback/test builds with no
              // native library) mints nothing, so that path keeps the old
              // route straight to storage.
              onNext: () => _go(_realPhrase ? 8 : 3),
            ),
            8 => RecoveryCertificateStep(
              phrase: _phrase.join(' '),
              already: _minted,
              onDone: ({required bool saved, Uint8List? credential}) {
                _certificateSaved = saved;
                _go(3);
              },
              onMinted: (minted) => _minted = minted,
            ),
            3 => _StorageChoice(
              mode: _mode,
              onChanged: (m) => setState(() => _mode = m),
              onNext: () => _go(7),
            ),
            7 => BundledSeedsChoiceStep(
              useBundledSeeds: _useBundledSeeds,
              onChanged: (v) => setState(() => _useBundledSeeds = v),
              onNext: () => _go(4),
            ),
            _ => _PasswordStep(
              passwordCtrl: _passwordCtrl,
              confirmCtrl: _confirmCtrl,
              busy: _busy,
              onFinish: _finish,
              setupError: _finishError,
            ),
          },
        ),
      ),
    );
  }

  // FALLBACK-ONLY placeholder (loopback/test builds without the native
  // library): production builds show the REAL native phrase from
  // veilGeneratePhrase() and derive the identity from it (_realPhrase).
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onNext});
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Spacer(),
        Icon(Icons.shield_moon_outlined, size: 64, color: scheme.primary),
        const SizedBox(height: 24),
        Text(
          l.onboardWelcomeTitle,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 16),
        Text(
          l.onboardWelcomeBody,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const Spacer(),
        FilledButton(onPressed: onNext, child: Text(l.actionContinue)),
      ],
    );
  }
}

class _ChoosePath extends StatelessWidget {
  const _ChoosePath({
    required this.onCreate,
    required this.onRestore,
    required this.onLink,
    required this.onArchive,
    required this.onOpenExisting,
    this.refused = false,
  });
  final VoidCallback onCreate;
  final VoidCallback onRestore;
  final VoidCallback onLink;

  /// The way back for someone who kept a transfer archive rather than — or as
  /// well as — a certificate. It is last of the four because it is the least
  /// common, not because it is a lesser answer: an archive that carries the
  /// identity restores the conversations with it.
  final VoidCallback onArchive;

  /// The door back into a container this device already holds — the one
  /// "Начать заново" quietly closes. It offers to TRY a password; it says
  /// nothing about whether there is anything here to open.
  final VoidCallback onOpenExisting;

  /// This device could not produce a recovery phrase, so nothing was created.
  final bool refused;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l.onboardChooseTitle,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 24),
          if (refused) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_outlined,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.onboardNoRecoveryPhrase,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          _OptionCard(
            icon: Icons.add_circle_outline,
            title: l.onboardCreateIdentity,
            subtitle: l.onboardCreateIdentitySub,
            onTap: onCreate,
          ),
          _OptionCard(
            icon: Icons.restore,
            title: l.onboardRestoreIdentity,
            subtitle: l.onboardRestoreIdentitySub,
            onTap: onRestore,
          ),
          _OptionCard(
            icon: Icons.add_link,
            title: l.onboardLinkDevice,
            subtitle: l.onboardLinkDeviceSub,
            onTap: onLink,
          ),
          _OptionCard(
            icon: Icons.unarchive_outlined,
            title: l.onboardRestoreFromArchive,
            subtitle: l.onboardRestoreFromArchiveSub,
            onTap: onArchive,
          ),
          // LAST, and present unconditionally. Showing it only when a
          // container exists would be the leak — the card itself has to say
          // nothing about what is on this device, which is why it is worded as
          // an offer to try a password rather than as a fact about one.
          _OptionCard(
            icon: Icons.lock_open,
            title: l.onboardOpenExisting,
            subtitle: l.onboardOpenExistingSub,
            onTap: onOpenExisting,
          ),
        ],
      ),
    );
  }
}

/// What the link path is about to do, said before the password step rather
/// than after it: the user picked "link" expecting no setup, and a container
/// password arriving unexplained reads like the wrong path was taken.
class _LinkStep extends StatelessWidget {
  const _LinkStep({required this.onNext});
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.onboardLinkDevice,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(
            child: Text(
              l.onboardLinkDeviceBody,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
        FilledButton(onPressed: onNext, child: Text(l.actionContinue)),
      ],
    );
  }
}

/// Two ways back, and they do not return the same thing.
///
/// The certificate is offered FIRST and on equal footing, because it is the
/// one that restores this identity. The words restore a different one — they
/// fix the Ed25519 half of the hybrid master and the Falcon half was drawn at
/// random — and a screen that offers only them tells someone holding their
/// certificate that there is nowhere to put it.
class _RestoreStep extends StatefulWidget {
  const _RestoreStep({
    required this.validate,
    required this.onSubmit,
    required this.onCertificate,
  });
  final bool Function(String phrase) validate;
  final ValueChanged<String> onSubmit;
  final void Function(Uint8List certificate, String code) onCertificate;

  @override
  State<_RestoreStep> createState() => _RestoreStepState();
}

class _RestoreStepState extends State<_RestoreStep> {
  /// Which way this person is taking. The certificate is the default: someone
  /// who has one should not have to find it behind a toggle, and someone who
  /// does not loses one tap.
  bool _byCertificate = true;

  @override
  Widget build(BuildContext context) {
    final validate = widget.validate;
    final onSubmit = widget.onSubmit;
    final l = AppL10n.of(context);
    // Typing the phrase in puts it on screen exactly as showing it does — the
    // field is not obscured, deliberately, because a mistyped word here costs
    // the identity. Guarded for the same reason the display step is.
    return SecureScreenGuard(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l.onboardRestoreIdentity,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              l.onboardRestoreBody,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: true,
                  label: Text(l.onboardRestoreWithCertificate),
                ),
                ButtonSegment(
                  value: false,
                  label: Text(l.onboardRestoreWithPhrase),
                ),
              ],
              selected: {_byCertificate},
              onSelectionChanged: (v) =>
                  setState(() => _byCertificate = v.first),
            ),
            const SizedBox(height: 16),
            if (_byCertificate)
              CertificateRestoreInput(onSubmit: widget.onCertificate)
            else
              RecoveryPhraseInput(
                validate: validate,
                onSubmit: onSubmit,
                submitLabel: l.onboardRestoreSubmit,
              ),
          ],
        ),
      ),
    );
  }
}

/// Take a password and try it against whatever is already on this device.
///
/// No file is looked for and nothing is reported about what is here. The
/// answer to "is there a container" and the answer to "is that the password"
/// are deliberately the same answer, because the first one is the one that
/// must never be given.
class _OpenExistingStep extends StatefulWidget {
  const _OpenExistingStep({
    required this.busy,
    required this.error,
    required this.onSubmit,
  });

  final bool busy;
  final String? error;
  final Future<void> Function(String password) onSubmit;

  @override
  State<_OpenExistingStep> createState() => _OpenExistingStepState();
}

class _OpenExistingStepState extends State<_OpenExistingStep> {
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l.onboardOpenExisting,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text(l.onboardOpenExistingBody),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() {}),
            onSubmitted: widget.busy || _password.text.isEmpty
                ? null
                : (value) => widget.onSubmit(value),
            decoration: InputDecoration(labelText: l.lockPasswordHint),
          ),
          if (widget.error != null) ...[
            const SizedBox(height: 8),
            Text(widget.error!, style: TextStyle(color: scheme.error)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: widget.busy || _password.text.isEmpty
                ? null
                : () => widget.onSubmit(_password.text),
            child: Text(l.onboardOpenExistingSubmit),
          ),
          if (widget.busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        onTap: onTap,
      ),
    );
  }
}

/// Finds the row carrying word [index] (0-based) of the recovery phrase.
///
/// The words repeat — the placeholder generator draws WITH replacement, and a
/// real BIP-39 phrase may repeat too — so a test cannot find word 24 by its
/// text. It has to ask for the twenty-fourth ROW, which is exactly what the
/// layout gate needs: the defect was widgets that existed and were off-screen.
Key recoveryWordKey(int index) => ValueKey('recovery-word-$index');

class _Recovery extends StatefulWidget {
  const _Recovery({
    required this.phrase,
    required this.real,
    required this.confirmed,
    required this.onConfirmedChanged,
    required this.onNext,
  });
  final List<String> phrase;

  /// False when the native generator was unavailable and [phrase] is the
  /// placeholder. `veilGeneratePhrase()` returns null precisely so callers can
  /// degrade HONESTLY; showing these words with the ordinary "write them down"
  /// copy told the user to back up 24 words that restore nothing, while the
  /// identity was minted at random.
  final bool real;
  final bool confirmed;
  final ValueChanged<bool> onConfirmedChanged;
  final VoidCallback onNext;

  @override
  State<_Recovery> createState() => _RecoveryState();
}

/// The 24 words, laid out so that a person can copy ALL of them.
///
/// What was here before was a `Wrap` of chips inside its own
/// `Expanded(SingleChildScrollView(...))`, with the confirm checkbox and the
/// Continue button pinned OUTSIDE that scroll. On an iPhone 17 Pro (402x874)
/// ten of the twenty-four chips were fully on screen and the rest were below
/// the fold; the inner scroll clipped flush with the chip above it, so there
/// was no partial row and no cue that anything followed. Worse, the confirm
/// checkbox — the control that says "I have written them down" — was reachable
/// without the later words ever having been rendered on screen. At 360x640 the
/// column overflowed outright and NOT ONE word was on screen. Someone who
/// copied what they saw lost the identity, and found out the first time they
/// tried to restore it, which may be years later.
///
/// Three things changed, and the order matters:
///
///  1. Chips are gone. A chip is a pill sized to its own text, so 24 of them
///     wrap into a ragged block whose height depends on the words that were
///     drawn — the layout could not be reasoned about, let alone asserted.
///     They are a fixed TWO-COLUMN numbered list now, 1–12 beside 13–24, which
///     is the shape of a paper backup sheet and costs a predictable twelve
///     rows regardless of which words came up — roughly 310 logical pixels at
///     the default text size, which leaves the prose and the confirmation
///     room to share an 874 pt screen instead of competing with it.
///  2. The step scrolls as ONE page, and the checkbox and button live inside
///     that scroll, below word 24. So when the words do not fit — large system
///     text, a shorter screen — the person cannot reach the control that
///     confirms the backup without word 24 having passed under their finger,
///     and an always-visible scrollbar says there is more.
///  3. The count is stated in words as well as in geometry
///     ([AppL10n.recoveryNumbered]), and the checkbox names the number it is
///     confirming.
///
/// Copying all 24 words IS offered here, and this note used to say the
/// opposite — it was considered and rejected once, on grounds that still
/// stand: the clipboard is system-wide, survives the lock screen, and on both
/// Apple and Windows syncs to machines the container knows nothing about.
/// Bounding it to 30 seconds (clipboard_secret.dart) makes that exposure
/// smaller; it does not make the clipboard a good place for a master seed.
///
/// The owner of this project asked for it anyway (2026-09-08), and the reason
/// is the one the old note did not weigh: a person who cannot get the words
/// off the device by ANY means writes them down wrong, or photographs the
/// screen with a second phone, and the failure that actually loses identities
/// is a phrase transcribed with one word missing — not a clipboard read by a
/// hostile app. So the button exists, and the interface says what it costs, in
/// the same breath as the copy rather than in a settings note nobody reads.
///
/// Two things it does NOT do: it never offers to copy the placeholder words
/// (copying twenty-four words that restore nothing is worse than not copying),
/// and it does not weaken [SecureScreenGuard] — screenshots of this step stay
/// blocked, because a screenshot is silent and permanent while this copy
/// announces itself and expires.
class _RecoveryState extends State<_Recovery> {
  final _scroll = ScrollController();

  /// Whether the words were put on the clipboard during this visit — shown so
  /// the person knows the 45-second window has started.
  bool _copied = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Put the phrase on the clipboard and arm its removal.
  ///
  /// The words are joined with single spaces, which is the form
  /// `validatePhrase` and the restore step accept — a copy that has to be
  /// reformatted before it can be pasted back is not a backup.
  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.phrase.join(' ')));
    // Not awaited: it resolves 30 seconds from now, and it must happen even if
    // the person leaves this screen — which is exactly when they will not
    // clear it themselves.
    unawaited(clearClipboardLater(after: kRecoveryPhraseClipboardLifetime));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final theme = Theme.of(context);
    // The one screen in the app that shows, in plain words, everything needed
    // to become this person. A screenshot of it — taken by the user for
    // convenience, by a recording app, or by whatever is on the device — is the
    // identity itself (audit X-11). Scoped to this step so screen sharing keeps
    // working everywhere else.
    return SecureScreenGuard(
      child: Scrollbar(
        controller: _scroll,
        // Not "when scrolling": a cue that appears only once the person has
        // already scrolled cannot tell them that scrolling is needed. This is
        // the affordance the old layout had none of.
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _scroll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.recoveryTitle, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              Text(l.recoveryBody, style: theme.textTheme.bodyMedium),
              if (!widget.real) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_outlined,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l.recoveryPlaceholderWarning,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                l.recoveryNumbered,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              _PhraseGrid(phrase: widget.phrase),
              // Only for REAL words: the placeholder branch above already says
              // these restore nothing, and a copy button under that warning
              // would be an invitation to save them anyway.
              if (widget.real) ...[
                const SizedBox(height: 12),
                Text(
                  l.recoveryCopyCaution,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _copy,
                      icon: const Icon(Icons.copy_outlined),
                      label: Text(l.recoveryCopy),
                    ),
                    if (_copied) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          l.recoveryCopied,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: widget.confirmed,
                onChanged: (v) => widget.onConfirmedChanged(v ?? false),
                title: Text(l.recoveryConfirm),
              ),
              FilledButton(
                onPressed: widget.confirmed ? widget.onNext : null,
                child: Text(l.actionContinue),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Twelve rows of two numbered words, the way a backup sheet is printed.
///
/// Down the left column then down the right, so the numbers a person reads
/// while writing run 1…12, 13…24 without jumping across the page. The number
/// gutter is a fixed width so the words line up in a column of their own —
/// with a ragged left edge, "did I already write that one?" has no answer.
class _PhraseGrid extends StatelessWidget {
  const _PhraseGrid({required this.phrase});

  final List<String> phrase;

  @override
  Widget build(BuildContext context) {
    final half = (phrase.length + 1) ~/ 2;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _column(context, 0, half)),
        const SizedBox(width: 16),
        Expanded(child: _column(context, half, phrase.length)),
      ],
    );
  }

  Widget _column(BuildContext context, int from, int to) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = from; i < to; i++)
          Padding(
            key: recoveryWordKey(i),
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                SizedBox(
                  width: 22,
                  child: Text(
                    '${i + 1}',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    phrase[i],
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StorageChoice extends StatelessWidget {
  const _StorageChoice({
    required this.mode,
    required this.onChanged,
    required this.onNext,
  });
  final StorageMode mode;
  final ValueChanged<StorageMode> onChanged;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.storageTitle, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 20),
        _StorageOption(
          selected: mode == StorageMode.hiddenSpace,
          icon: Icons.lock_outline,
          title: l.storageHiddenTitle,
          body: l.storageHiddenBody,
          onTap: () => onChanged(StorageMode.hiddenSpace),
        ),
        const SizedBox(height: 12),
        _StorageOption(
          selected: mode == StorageMode.plain,
          icon: Icons.folder_open_outlined,
          title: l.storagePlainTitle,
          body: l.storagePlainBody,
          onTap: () => onChanged(StorageMode.plain),
        ),
        if (mode == StorageMode.plain) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: scheme.error, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.storagePlainWarning,
                  style: TextStyle(color: scheme.error),
                ),
              ),
            ],
          ),
        ],
        const Spacer(),
        FilledButton(onPressed: onNext, child: Text(l.actionContinue)),
      ],
    );
  }
}

class _StorageOption extends StatelessWidget {
  const _StorageOption({
    required this.selected,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });
  final bool selected;
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: selected ? scheme.primary : null),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(body, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PasswordStep extends StatefulWidget {
  const _PasswordStep({
    required this.passwordCtrl,
    required this.confirmCtrl,
    required this.busy,
    required this.onFinish,
    this.setupError,
  });
  final TextEditingController passwordCtrl;
  final TextEditingController confirmCtrl;
  final bool busy;
  final VoidCallback onFinish;

  /// Set when creating the container itself failed, as opposed to the two
  /// local validation errors this step raises on its own.
  final String? setupError;

  @override
  State<_PasswordStep> createState() => _PasswordStepState();
}

class _PasswordStepState extends State<_PasswordStep> {
  String? _error;

  void _submit() {
    final l = AppL10n.of(context);
    final pw = widget.passwordCtrl.text;
    if (pw.length < 6) {
      setState(() => _error = l.onboardPasswordTooShort);
      return;
    }
    if (pw != widget.confirmCtrl.text) {
      setState(() => _error = l.onboardPasswordMismatch);
      return;
    }
    setState(() => _error = null);
    widget.onFinish();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.onboardPasswordTitle,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          l.onboardPasswordSubtitle,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: widget.passwordCtrl,
          obscureText: true,
          autofillHints: const [],
          inputFormatters: [LengthLimitingTextInputFormatter(128)],
          decoration: InputDecoration(labelText: l.lockPasswordHint),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: widget.confirmCtrl,
          obscureText: true,
          decoration: InputDecoration(labelText: l.onboardRepeatPassword),
          onSubmitted: (_) => _submit(),
        ),
        if (_error != null || widget.setupError != null) ...[
          const SizedBox(height: 12),
          Text(
            _error ?? widget.setupError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const Spacer(),
        FilledButton(
          onPressed: widget.busy ? null : _submit,
          child: widget.busy
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l.actionDone),
        ),
      ],
    );
  }
}
