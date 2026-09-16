import 'dart:async';

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    this.mintIdentity = mintSovereignIdentity,
    this.saveCertificate,
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

  /// Mints the identity on the create path. Injectable for the same reason as
  /// the two above: it runs two Argon2 passes through the native library,
  /// which the test host does not load.
  final MintedRecovery Function() mintIdentity;

  /// Writes the certificate out. Injectable because the real one opens a file
  /// dialog and touches the disk; null means the real one.
  final Future<bool> Function(String certificate, String suggestedName)?
  saveCertificate;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int _step = 0;
  List<String> _phrase = const [];

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
    // NO WORDS ON THIS PATH ANY MORE.
    //
    // They were never a backup of this identity: the phrase fixes the Ed25519
    // half of the hybrid master and the Falcon half is drawn at random, so the
    // words restore a DIFFERENT identity at an address nobody holds. Asked
    // from the field once the app finally said so: "зачем теперь 24 слова
    // записывать при создании личности?" — and there was no good answer.
    // Writing down a secret that cannot restore anything is worse than writing
    // down nothing, because it is a backup someone believes in.
    //
    // The identity is minted on the certificate step instead, and the code it
    // hands over is the ONLY secret it will ever have — for restoring, for
    // linking a device, for claiming a nickname, for reissuing the
    // certificate. One secret, one file, and no question about which of two
    // things is the backup.
    _realPhrase = false;
    _phrase = const [];
    _joinExisting = false;
    _go(8);
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
    _joinExisting = true;
    _go(6);
  }

  /// Pick an archive and read what it says about itself.
  ///
  /// The reading lives here rather than in the step for one reason: real file
  /// IO inside `testWidgets` does not fail, it HANGS — stream events are never
  /// delivered in fake time. The widget is handed what was read.
  /// The archive chosen last, so a sealed one can be re-read with its password
  /// without sending the person back through the file dialog.
  String? _lastArchivePath;

  Future<ArchivePreview?> _openArchive({
    required String? password,
    bool reuseLast = false,
  }) async {
    if (reuseLast) {
      final again = _lastArchivePath;
      if (again == null) return null;
      return _readArchive(File(again), password);
    }
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
    _lastArchivePath = path;
    // NAMED IN THE FAILURE. Everything below can throw, and the one thing that
    // makes such a throw actionable is which file it was about: a sandboxed
    // build reaches the chosen file through the picker's grant, so "cannot
    // read /Users/…/x.xveilbk" and "this is not an archive" are different
    // defects that used to print the same sentence.
    if (!await file.exists()) {
      throw FileSystemException('the chosen file is not there', path);
    }
    return _readArchive(file, password);
  }

  Future<ArchivePreview?> _readArchive(File file, String? password) async {
    final header = await DataImporter.inspect(file.openRead());
    final identity = header.includesIdentity
        ? await DataImporter.readIdentity(file.openRead(), password: password)
        : null;
    // BOTH KEYS, because they are two different things. The config above is
    // what this device speaks on the wire; the credential is what the identity
    // is NAMED by, and an archive written before the exporter carried one
    // answers null — those restore the transport key alone, which is the
    // half-restore the field measured as "другой node_id".
    final credential = header.includesIdentity
        ? await DataImporter.readCredential(file.openRead(), password: password)
        : null;
    return ArchivePreview(
      nodeIdHex: header.nodeIdHex,
      createdMs: header.createdMs,
      includesIdentity: header.includesIdentity,
      sealed: header.seal != null,
      identityToml: identity,
      credential: credential,
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
  void _restoreFromArchive(
    String identityToml,
    Uint8List? credential,
    String secret,
  ) {
    _restoring = true;
    _restoreNodeConfig = identityToml;
    // THE CREDENTIAL TRAVELS WITH THE CONFIG, or the restore is a half of one.
    //
    // The node config is the transport key; the credential is the hybrid
    // master the identity is NAMED by. An archive written before the exporter
    // carried the credential hands over null here, and that restore lands on
    // the transport key alone — a working install at an address the person's
    // contacts do not hold. Measured in the field before this existed.
    //
    // The secret rides along because the credential is encrypted and the boot
    // needs to open it: the words for an XVSB, the code for an XVRC. It was
    // already proved against this credential on the step that collected it.
    _restoreCertificate = credential;
    _restoreCode = secret;
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
            // WHICHEVER SECRET OPENS WHAT THIS CONTAINER WILL HOLD. A restore
            // brought its own credential and the secret that opens it; a
            // create just minted one, and an XVRC is opened by its code. Only
            // a phrase-born identity — a restore by words — uses the words.
            identityPhrase: _restoreCertificate != null
                ? _restoreCode
                : (_minted != null
                      ? _minted!.code
                      : (_realPhrase ? _phrase.join(' ') : null)),
            // A RESTORE, not a first mint: this device gets a node key of its
            // own under the phrase's identity.
            restoringIdentity: _restoring,
            joinExisting: _joinExisting,
            // The ceremony already put this question to them, with the phrase
            // in hand and nothing to retype. Whatever they answered, the
            // end-of-onboarding push has nothing left to add.
            // Offered AND taken: the create path cannot leave that step
            // without the file on disk, so there is nothing left to push.
            recoveryCertificateOffered: _minted != null,
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
                  3 => 8,
                  // Back from the certificate goes to the choice: on the
                  // create path there is no words step behind it any more.
                  8 => _realPhrase ? 2 : 1,
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
            5 => _RestoreStep(onCertificate: _restoreWithCertificate),
            6 => _LinkStep(onNext: () => _go(3)),
            8 => RecoveryCertificateStep(
              mintFresh: widget.mintIdentity,
              save: widget.saveCertificate,
              // Empty on the create path, which is now every create: the step
              // mints the identity itself and its code is the only secret.
              phrase: _realPhrase ? _phrase.join(' ') : '',
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
/// The certificate, and only the certificate.
///
/// The words used to stand beside it as a second way back. They are not one:
/// they fix the Ed25519 half of the hybrid master and the Falcon half was
/// drawn at random, so restoring from them produces a DIFFERENT identity at an
/// address nobody holds. Offering that as an alternative made it look like a
/// choice between two routes to the same place, which is the shape of a trap
/// rather than of a second chance. Owner's call, after the measurement:
/// "личность в любом случае не восстановим из-за отсутствия falcon512 части, а
/// значит бесполезно и равносильно созданию новой личности".
///
/// What this costs, said plainly: an identity old enough to have no sovereign
/// credential at all IS restored exactly by its words, and those people lose
/// this door. Every identity this app has created for months is hybrid.
class _RestoreStep extends StatelessWidget {
  const _RestoreStep({required this.onCertificate});

  final void Function(Uint8List certificate, String code) onCertificate;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    // Guarded like every screen that puts a recovery capability on it: what is
    // typed here is half of one.
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
            CertificateRestoreInput(onSubmit: onCertificate),
          ],
        ),
      ),
    );
  }
}

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
