import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/secure_screen.dart';
import '../../data/identity/veil_identity.dart';
import '../../data/node/bundled_seeds.dart';
import '../../domain/identity.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/providers.dart';
import 'bundled_seeds_choice.dart';
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
  const OnboardingScreen({super.key, this.validatePhrase = veilPhraseValid});

  /// Injectable so widget tests can drive the restore path without the
  /// native library; production uses the FFI-backed validator.
  final bool Function(String phrase) validatePhrase;

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

  void _startCreate() {
    final real = veilGeneratePhrase();
    _realPhrase = real != null;
    _phrase = real?.split(' ') ?? _generatePhrase();
    _phraseConfirmed = false;
    _joinExisting = false;
    _go(2);
  }

  /// Join an existing device group: no phrase is generated and none is asked
  /// for. The identity minted at the end is temporary — it carries this device
  /// onto the network so the existing device can approve it.
  void _startLink() {
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
    _phrase = phrase.split(' ');
    _realPhrase = true;
    _joinExisting = false;
    _go(3);
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
            // The REAL phrase drives the deterministic identity derivation on
            // the first node boot; the placeholder never leaves this screen.
            identityPhrase: _realPhrase ? _phrase.join(' ') : null,
            joinExisting: _joinExisting,
          );
      // Router redirect takes over once phase flips to ready.
    } catch (e) {
      // Creating the container runs Argon2 and touches the filesystem; a full
      // disk or a native fault threw straight through the old code and left
      // `_busy` true forever, so the Done button never came back and the only
      // way on was to kill the app.
      devLog(() => 'xVeil[onboarding]: completeOnboarding failed: $e');
      if (mounted) setState(() => _finishError = AppL10n.of(context).onboardSetupFailed);
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
                  2 || 5 || 6 => 1,
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
            ),
            5 => _RestoreStep(
              validate: widget.validatePhrase,
              onSubmit: _restoreWith,
            ),
            6 => _LinkStep(onNext: () => _go(3)),
            2 => _Recovery(
              phrase: _phrase,
              real: _realPhrase,
              confirmed: _phraseConfirmed,
              onConfirmedChanged: (v) => setState(() => _phraseConfirmed = v),
              onNext: () => _go(3),
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
  static const _sampleWords = [
    'anchor',
    'borrow',
    'cliff',
    'dawn',
    'ember',
    'forest',
    'glide',
    'harbor',
    'island',
    'jungle',
    'kernel',
    'lantern',
    'meadow',
    'noble',
    'orbit',
    'pebble',
    'quartz',
    'ripple',
    'shadow',
    'timber',
    'umbra',
    'velvet',
    'willow',
    'zenith',
    'cedar',
    'mirror',
    'signal',
    'cobalt',
  ];

  static List<String> _generatePhrase() {
    final rnd = Random.secure();
    return List.generate(
      24,
      (_) => _sampleWords[rnd.nextInt(_sampleWords.length)],
    );
  }
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
  });
  final VoidCallback onCreate;
  final VoidCallback onRestore;
  final VoidCallback onLink;

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

class _RestoreStep extends StatelessWidget {
  const _RestoreStep({required this.validate, required this.onSubmit});
  final bool Function(String phrase) validate;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) {
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
/// What deliberately did NOT change: there is still no "copy all 24 words"
/// button. It was considered, because [SecureScreenGuard] blocks screenshots
/// and the clipboard would be the only route off the device — and rejected.
/// The clipboard is system-wide, survives the lock screen, and on both Apple
/// and Windows syncs to other machines the container knows nothing about;
/// bounding it to 45 seconds (see clipboard_secret.dart) makes an exposure
/// that already exists smaller, it does not make the clipboard a place to put
/// a master seed. It would also contradict the canon this file already states
/// for a file-based backup: identity documents do not leave the container.
/// So the answer to "all 24 must be readable" is layout, not export.
class _RecoveryState extends State<_Recovery> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
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
