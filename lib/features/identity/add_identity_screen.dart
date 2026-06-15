import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';

/// Form to add a new identity. On the FIRST add (single-identity mode) it also
/// converts the current space into a master, so it asks for a master password
/// and a label for the existing identity. Thereafter it just appends.
class AddIdentityScreen extends ConsumerStatefulWidget {
  const AddIdentityScreen({super.key});

  @override
  ConsumerState<AddIdentityScreen> createState() => _AddIdentityScreenState();
}

class _AddIdentityScreenState extends ConsumerState<AddIdentityScreen> {
  final _newName = TextEditingController();
  final _newPassword = TextEditingController();
  final _masterPassword = TextEditingController();
  final _currentName = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _newName.dispose();
    _newPassword.dispose();
    _masterPassword.dispose();
    _currentName.dispose();
    super.dispose();
  }

  Future<void> _submit(bool converting) async {
    final l = AppL10n.of(context);
    if (_busy) return;
    if (_newName.text.trim().isEmpty ||
        _newPassword.text.isEmpty ||
        _masterPassword.text.isEmpty) {
      setState(() => _error = l.addIdentityIncomplete);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await ref.read(appControllerProvider.notifier).addIdentity(
          masterPassword: _masterPassword.text,
          label: _newName.text.trim(),
          password: _newPassword.text,
          existingLabel: converting && _currentName.text.trim().isNotEmpty
              ? _currentName.text.trim()
              : 'Identity 1',
        );
    if (!mounted) return;
    if (ok) {
      // Now in the new identity's session — go home (the phase is already
      // ready/preparing; go() keeps the router consistent vs a manual pop).
      context.go('/home');
    } else {
      setState(() {
        _busy = false;
        _error = l.addIdentityClash;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final converting = !ref.watch(appControllerProvider).isMaster;

    return Scaffold(
      appBar: AppBar(title: Text(l.addIdentityTitle)),
      body: Stack(
        children: [
          SafeArea(
            child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(l.addIdentitySubtitle,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 20),
            if (converting) ...[
              TextField(
                controller: _currentName,
                decoration: InputDecoration(
                  labelText: l.addIdentityCurrentName,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _newName,
              decoration: InputDecoration(
                labelText: l.addIdentityNewName,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _newPassword,
              obscureText: true,
              decoration: InputDecoration(
                labelText: l.addIdentityNewPassword,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _masterPassword,
              obscureText: true,
              decoration: InputDecoration(
                labelText: l.addIdentityMasterPassword,
                helperText: l.addIdentityMasterHint,
                helperMaxLines: 3,
                border: const OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : () => _submit(converting),
              child: Text(l.addIdentityCreate),
            ),
          ],
            ),
          ),
          // Argon2 container opens block the platform thread for a moment; show
          // an intentional "working" overlay so it doesn't read as a freeze.
          if (_busy)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(l.addIdentityWorking, textAlign: TextAlign.center),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
