import 'package:flutter/material.dart';

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
  String get _normalized =>
      _ctrl.text.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');

  int get _words => _normalized.isEmpty ? 0 : _normalized.split(' ').length;

  bool get _valid => _words == widget.wordCount && widget.validate(_normalized);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
          decoration: const InputDecoration(
            hintText: 'Enter your recovery phrase, words separated by spaces',
          ),
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
            Text('$_words / ${widget.wordCount} words',
                style: Theme.of(context).textTheme.bodySmall),
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
