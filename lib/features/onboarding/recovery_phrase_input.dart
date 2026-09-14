import 'package:flutter/material.dart';

import '../../domain/sovereign_secret.dart';
import '../../l10n/app_localizations.dart';

/// Recovery-phrase entry with live validity feedback. The validator is
/// injected (production passes veil_flutter's `validateBip39Phrase`, which is
/// FFI; tests pass a fake), so the widget's logic is unit-testable without the
/// native library.
class RecoveryPhraseInput extends StatefulWidget {
  const RecoveryPhraseInput({
    super.key,
    required this.validate,
    required this.onSubmit,
    this.wordCount = 24,
    this.submitLabel = 'Restore',
  });

  final bool Function(String phrase) validate;
  final void Function(String phrase) onSubmit;
  final int wordCount;
  final String submitLabel;

  @override
  State<RecoveryPhraseInput> createState() => _RecoveryPhraseInputState();
}

class _RecoveryPhraseInputState extends State<RecoveryPhraseInput> {
  final _ctrl = TextEditingController();

  /// Collapse whitespace + lowercase so paste/extra spaces don't break it.
  ///
  /// The rule itself lives in `normalizeSovereignSecret`, because this widget
  /// was the only one of four entry points that had it. The other three
  /// trimmed the ends and handed the rest straight to a KDF that normalizes
  /// nothing — so the same pasted phrase worked here and was refused there.
  String get _normalized =>
      normalizeSovereignSecret(_ctrl.text, isRecoveryCode: false);

  int get _words => sovereignPhraseWordCount(_ctrl.text);

  bool get _valid => _words == widget.wordCount && widget.validate(_normalized);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _ctrl,
          minLines: 3,
          maxLines: 5,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(hintText: l.recoveryPhraseHint),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              _valid ? Icons.check_circle : Icons.circle_outlined,
              size: 18,
              color: _valid ? Colors.green : scheme.outline,
            ),
            const SizedBox(width: 6),
            Text(
              '$_words / ${widget.wordCount} words',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _valid ? () => widget.onSubmit(_normalized) : null,
          child: Text(widget.submitLabel),
        ),
      ],
    );
  }
}
