import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/identity/veil_identity.dart';
import '../../domain/identity.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import 'recovery_phrase_input.dart';

/// First-launch wizard. Steps:
///   0 welcome → 1 choose path → 2 recovery phrase → 3 storage mode → 4 password
///   restore:             1 → 5 phrase entry → 3 storage mode → 4 password
///
/// Create and restore both drive the deterministic first-boot identity
/// derivation from the phrase (P2/P3). A file-based backup action is
/// intentionally absent: there is no matching secure export format, and
/// writing identity documents to disk would violate the deniable canon.
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
  StorageMode _mode = StorageMode.hiddenSpace;
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
    _go(2);
  }

  /// The user typed a phrase that passed the native validator: it feeds the
  /// SAME deterministic first-boot derivation as the create path, so the
  /// node identity it produces is the one the phrase was written down for.
  void _restoreWith(String phrase) {
    _phrase = phrase.split(' ');
    _realPhrase = true;
    _go(3);
  }

  Future<void> _finish() async {
    if (_busy) return;
    setState(() => _busy = true);
    final identity = AppController.generateIdentity();
    await ref
        .read(appControllerProvider.notifier)
        .completeOnboarding(
          identity: identity,
          password: _passwordCtrl.text,
          mode: _mode,
          // The REAL phrase drives the deterministic identity derivation on
          // the first node boot; the placeholder never leaves this screen.
          identityPhrase: _realPhrase ? _phrase.join(' ') : null,
        );
    // Router redirect takes over once phase flips to ready.
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
                  4 => 3,
                  2 || 5 => 1,
                  _ => 0,
                }),
              ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: switch (_step) {
            0 => _Welcome(onNext: () => _go(1)),
            1 => _ChoosePath(onCreate: _startCreate, onRestore: () => _go(5)),
            5 => _RestoreStep(
              validate: widget.validatePhrase,
              onSubmit: _restoreWith,
            ),
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
              onNext: () => _go(4),
            ),
            _ => _PasswordStep(
              passwordCtrl: _passwordCtrl,
              confirmCtrl: _confirmCtrl,
              busy: _busy,
              onFinish: _finish,
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
  const _ChoosePath({required this.onCreate, required this.onRestore});
  final VoidCallback onCreate;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
    return SingleChildScrollView(
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

class _Recovery extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.recoveryTitle, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        Text(l.recoveryBody, style: Theme.of(context).textTheme.bodyMedium),
        if (!real) ...[
          const SizedBox(height: 12),
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
                    l.recoveryPlaceholderWarning,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < phrase.length; i++)
                  Chip(label: Text('${i + 1}. ${phrase[i]}')),
              ],
            ),
          ),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: confirmed,
          onChanged: (v) => onConfirmedChanged(v ?? false),
          title: Text(l.recoveryConfirm),
        ),
        FilledButton(
          onPressed: confirmed ? onNext : null,
          child: Text(l.actionContinue),
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
  });
  final TextEditingController passwordCtrl;
  final TextEditingController confirmCtrl;
  final bool busy;
  final VoidCallback onFinish;

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
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
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
