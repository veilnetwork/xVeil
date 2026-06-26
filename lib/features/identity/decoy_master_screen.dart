import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';

/// Configure a DECOY (duress) master: a separate password that, under coercion,
/// opens a believable set of identities while the real master and any sensitive
/// identity stay hidden. The shared identities are exposed in FULL — the screen
/// warns about this prominently.
class DecoyMasterScreen extends ConsumerStatefulWidget {
  const DecoyMasterScreen({super.key});

  @override
  ConsumerState<DecoyMasterScreen> createState() => _DecoyMasterScreenState();
}

class _DecoyMasterScreenState extends ConsumerState<DecoyMasterScreen> {
  final _password = TextEditingController();
  final _selected = <String>{};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l = AppL10n.of(context);
    if (_busy) return;
    if (_password.text.isEmpty) {
      setState(() => _error = l.addIdentityIncomplete);
      return;
    }
    if (_selected.isEmpty) {
      setState(() => _error = l.decoyPickOne);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    bool ok = false;
    try {
      ok = await ref
          .read(appControllerProvider.notifier)
          .createDecoyMaster(
            duressPassword: _password.text,
            includeLabels: _selected.toList(),
          );
    } catch (_) {
      // Never wedge the form on the busy spinner if the FFI op throws.
      ok = false;
    }
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.decoyCreated)));
      Navigator.of(context).maybePop();
    } else {
      setState(() {
        _busy = false;
        _error = l.decoyClash;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final identities = ref.watch(appControllerProvider).identities;

    return Scaffold(
      appBar: AppBar(title: Text(l.decoyTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              l.decoySubtitle,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Card(
              color: scheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_outlined,
                      color: scheme.onErrorContainer,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l.decoyWarning,
                        style: TextStyle(color: scheme.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: InputDecoration(
                labelText: l.decoyPassword,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            Text(l.decoyInclude, style: Theme.of(context).textTheme.labelLarge),
            for (final label in identities)
              CheckboxListTile(
                value: _selected.contains(label),
                title: Text(label),
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                        if (v == true) {
                          _selected.add(label);
                        } else {
                          _selected.remove(label);
                        }
                      }),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l.decoyCreate),
            ),
          ],
        ),
      ),
    );
  }
}
