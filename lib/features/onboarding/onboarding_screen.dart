import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/identity.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';

/// First-launch wizard. Steps:
///   0 welcome → 1 choose path → 2 recovery phrase → 3 storage mode → 4 password
///
/// Only the "create new identity" path is fully implemented for this
/// milestone; restore/import surface a placeholder and return to the chooser.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

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

  void _startCreate() {
    _phrase = _generatePhrase();
    _phraseConfirmed = false;
    _go(2);
  }

  Future<void> _finish() async {
    if (_busy) return;
    setState(() => _busy = true);
    final identity = AppController.generateIdentity();
    await ref.read(appControllerProvider.notifier).completeOnboarding(
          identity: identity,
          password: _passwordCtrl.text,
          mode: _mode,
        );
    // Router redirect takes over once phase flips to ready.
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: _step == 0
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => _go(_step == 4 ? 3 : (_step == 2 ? 1 : 0)),
              ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: switch (_step) {
            0 => _Welcome(onNext: () => _go(1)),
            1 => _ChoosePath(
                onCreate: _startCreate,
                onRestore: () => _showSoon(context, l.onboardRestoreIdentity),
                onImport: () => _showSoon(context, l.onboardImportBackup),
              ),
            2 => _Recovery(
                phrase: _phrase,
                confirmed: _phraseConfirmed,
                onConfirmedChanged: (v) =>
                    setState(() => _phraseConfirmed = v),
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

  void _showSoon(BuildContext context, String label) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppL10n.of(context).onboardComingSoon(label))),
    );
  }

  // Placeholder phrase for the create flow. The real 24-word BIP-39 phrase is
  // produced by veil_flutter identity derivation once the native layer lands.
  static const _sampleWords = [
    'anchor', 'borrow', 'cliff', 'dawn', 'ember', 'forest', 'glide', 'harbor',
    'island', 'jungle', 'kernel', 'lantern', 'meadow', 'noble', 'orbit',
    'pebble', 'quartz', 'ripple', 'shadow', 'timber', 'umbra', 'velvet',
    'willow', 'zenith', 'cedar', 'mirror', 'signal', 'cobalt',
  ];

  static List<String> _generatePhrase() {
    final rnd = Random.secure();
    return List.generate(24, (_) => _sampleWords[rnd.nextInt(_sampleWords.length)]);
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
        Text(l.onboardWelcomeTitle,
            style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 16),
        Text(l.onboardWelcomeBody,
            style: Theme.of(context).textTheme.bodyLarge),
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
    required this.onImport,
  });
  final VoidCallback onCreate;
  final VoidCallback onRestore;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.onboardChooseTitle,
            style: Theme.of(context).textTheme.headlineSmall),
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
          icon: Icons.file_open_outlined,
          title: l.onboardImportBackup,
          subtitle: l.onboardImportBackupSub,
          onTap: onImport,
        ),
      ],
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
    required this.confirmed,
    required this.onConfirmedChanged,
    required this.onNext,
  });
  final List<String> phrase;
  final bool confirmed;
  final ValueChanged<bool> onConfirmedChanged;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.recoveryTitle,
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        Text(l.recoveryBody, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < phrase.length; i++)
                  Chip(
                    label: Text('${i + 1}. ${phrase[i]}'),
                  ),
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
                  Text(title,
                      style: Theme.of(context).textTheme.titleMedium),
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
        Text(l.lockTitle, style: Theme.of(context).textTheme.headlineSmall),
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
          Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const Spacer(),
        FilledButton(
          onPressed: widget.busy ? null : _submit,
          child: widget.busy
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(l.actionDone),
        ),
      ],
    );
  }
}
