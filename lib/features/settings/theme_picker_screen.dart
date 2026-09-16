// Choosing a look, making one, and passing one on.
//
// Everything a theme can say is a colour and a brightness, and the screen says
// so once, at the top, because a person about to paste something a stranger
// sent deserves to know what they are agreeing to before they paste it rather
// than after. What it buys is the property that makes sharing safe at all:
// every other colour is derived, so no theme can decide what a warning looks
// like on somebody else's screen.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/theme_spec.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/theme_controller.dart';

class ThemePickerScreen extends ConsumerStatefulWidget {
  const ThemePickerScreen({super.key});

  @override
  ConsumerState<ThemePickerScreen> createState() => _ThemePickerScreenState();
}

class _ThemePickerScreenState extends ConsumerState<ThemePickerScreen> {
  bool _importBad = false;

  Future<void> _import(AppL10n l) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _PasteThemeDialog(l: l),
    );
    if (text == null || !mounted) return;
    final spec = ThemeSpec.parse(text);
    if (spec == null) {
      setState(() => _importBad = true);
      return;
    }
    setState(() => _importBad = false);
    await ref.read(themeProvider.notifier).addCustom(spec);
  }

  Future<void> _make(AppL10n l) async {
    final spec = await showDialog<ThemeSpec>(
      context: context,
      builder: (_) => _MakeThemeDialog(l: l),
    );
    if (spec == null || !mounted) return;
    await ref.read(themeProvider.notifier).addCustom(spec);
  }

  Future<void> _share(ThemeSpec spec, AppL10n l) async {
    await Clipboard.setData(ClipboardData(text: spec.toText()));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.themeShared)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final choices = ref.watch(themeProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        // Declared rather than inherited: the invariant test walks every
        // routed screen for it, because a screen that relies on the default
        // has no way back on the platforms that draw none.
        leading: const RootedBackButton(),
        title: Text(l.themeTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          Text(l.themeSubtitle, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          // Said BEFORE anything is pasted. A promise about what a stranger's
          // file can and cannot do is only useful while there is still a
          // decision to make.
          Text(
            l.themeSafety,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          _Heading(l.themeBuiltIn),
          for (final spec in kBuiltInThemes)
            _ThemeRow(
              spec: spec,
              chosen: spec.id == choices.chosen.id,
              onTap: () => ref.read(themeProvider.notifier).choose(spec),
              onShare: () => _share(spec, l),
              shareLabel: l.themeShare,
            ),
          if (choices.custom.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Heading(l.themeYours),
            for (final spec in choices.custom)
              _ThemeRow(
                spec: spec,
                chosen: spec.id == choices.chosen.id,
                onTap: () => ref.read(themeProvider.notifier).choose(spec),
                onShare: () => _share(spec, l),
                shareLabel: l.themeShare,
                onRemove: () =>
                    ref.read(themeProvider.notifier).removeCustom(spec.id),
                removeLabel: l.themeRemove,
              ),
          ],
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => _make(l),
            icon: const Icon(Icons.palette_outlined),
            label: Text(l.themeMake),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _import(l),
            icon: const Icon(Icons.content_paste),
            label: Text(l.themeImport),
          ),
          if (_importBad) ...[
            const SizedBox(height: 8),
            Text(l.themeImportBad, style: TextStyle(color: scheme.error)),
          ],
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

/// One look, shown in its own colours rather than described in words.
class _ThemeRow extends StatelessWidget {
  const _ThemeRow({
    required this.spec,
    required this.chosen,
    required this.onTap,
    required this.onShare,
    required this.shareLabel,
    this.onRemove,
    this.removeLabel,
  });

  final ThemeSpec spec;
  final bool chosen;
  final VoidCallback onTap;
  final VoidCallback onShare;
  final String shareLabel;
  final VoidCallback? onRemove;
  final String? removeLabel;

  @override
  Widget build(BuildContext context) {
    // The swatch is built the same way the app would build the whole theme, so
    // what the row shows is what choosing it does — not an approximation that
    // can drift from it.
    final preview = ColorScheme.fromSeed(
      seedColor: spec.seed,
      brightness: spec.dark ? Brightness.dark : Brightness.light,
    );
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: preview.surface,
          shape: BoxShape.circle,
          border: Border.all(color: preview.primary, width: 3),
        ),
        // A dot in the error colour, because that is the colour this app puts
        // its warnings in and the one a person is entitled to see before
        // choosing.
        child: Center(
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: preview.error,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
      title: Text(spec.name),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (chosen)
            Icon(Icons.check, color: Theme.of(context).colorScheme.primary),
          IconButton(
            tooltip: shareLabel,
            onPressed: onShare,
            icon: const Icon(Icons.copy, size: 18),
          ),
          if (onRemove != null)
            IconButton(
              tooltip: removeLabel,
              onPressed: onRemove,
              icon: const Icon(Icons.delete_outline, size: 18),
            ),
        ],
      ),
    );
  }
}

class _PasteThemeDialog extends StatefulWidget {
  const _PasteThemeDialog({required this.l});
  final AppL10n l;

  @override
  State<_PasteThemeDialog> createState() => _PasteThemeDialogState();
}

class _PasteThemeDialogState extends State<_PasteThemeDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.l;
    return AlertDialog(
      title: Text(l.themeImport),
      content: TextField(
        controller: _text,
        minLines: 2,
        maxLines: 4,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(helperText: l.themeImportHint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_text.text),
          child: Text(l.actionContinue),
        ),
      ],
    );
  }
}

class _MakeThemeDialog extends StatefulWidget {
  const _MakeThemeDialog({required this.l});
  final AppL10n l;

  @override
  State<_MakeThemeDialog> createState() => _MakeThemeDialogState();
}

class _MakeThemeDialogState extends State<_MakeThemeDialog> {
  final _name = TextEditingController();
  bool _dark = true;

  /// A handful of seeds rather than a colour wheel: what matters is the
  /// character of the result, and every one of these produces a scheme
  /// Material has already checked for contrast.
  static const _seeds = [
    Color(0xFF1E8A7B),
    Color(0xFF7B4A8A),
    Color(0xFF8A6A1E),
    Color(0xFF2A3A6A),
    Color(0xFF4A7A3A),
    Color(0xFF8A3A3A),
    Color(0xFF4A5A6A),
    Color(0xFF6A3A7A),
  ];
  Color _seed = _seeds.first;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.l;
    return AlertDialog(
      title: Text(l.themeMake),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              maxLength: kMaxThemeNameChars,
              decoration: InputDecoration(labelText: l.themeMakeName),
            ),
            const SizedBox(height: 8),
            Text(l.themeMakeColour),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final seed in _seeds)
                  GestureDetector(
                    onTap: () => setState(() => _seed = seed),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: seed,
                        shape: BoxShape.circle,
                        border: Border.all(
                          width: seed.toARGB32() == _seed.toARGB32() ? 3 : 1,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _dark,
              onChanged: (v) => setState(() => _dark = v),
              title: Text(l.themeMakeDark),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            Navigator.of(context).pop(
              ThemeSpec(
                // Unique per make, so saving a second theme does not silently
                // replace the first one that happened to share a name.
                id: 'custom-${DateTime.now().microsecondsSinceEpoch}',
                name: name.isEmpty ? l.themeMake : name,
                seed: _seed,
                dark: _dark,
              ),
            );
          },
          child: Text(l.themeMakeSave),
        ),
      ],
    );
  }
}
