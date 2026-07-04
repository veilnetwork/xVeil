import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/messaging.dart';

/// Author-side host for opt-in signature requests. Listens to
/// [MessagingService.signatureAsks] (fired only under `SignaturePolicy.ask`) and
/// prompts the user to attest authorship of a specific message — showing the
/// exact text so they can review it before consenting. Mounted for the whole
/// authenticated session so a request prompts wherever the user is.
class SignatureAskHost extends ConsumerStatefulWidget {
  const SignatureAskHost({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<SignatureAskHost> createState() => _SignatureAskHostState();
}

class _SignatureAskHostState extends ConsumerState<SignatureAskHost> {
  StreamSubscription<SignatureAsk>? _sub;
  bool _showing = false;
  final _queue = <SignatureAsk>[];

  @override
  void initState() {
    super.initState();
    // Bind after the first frame so a Navigator/Overlay is available.
    WidgetsBinding.instance.addPostFrameCallback((_) => _bind());
  }

  void _bind() {
    final svc = ref.read(messagingServiceProvider);
    _sub = svc.signatureAsks.listen((ask) {
      _queue.add(ask);
      _drain();
    });
  }

  Future<void> _drain() async {
    if (_showing || _queue.isEmpty || !mounted) return;
    _showing = true;
    final ask = _queue.removeAt(0);
    try {
      final approve = await _prompt(ask);
      await ref
          .read(messagingServiceProvider)
          .resolveSignatureAsk(ask, approve: approve ?? false);
    } finally {
      _showing = false;
      if (mounted) unawaited(_drain()); // next queued request, if any
    }
  }

  Future<bool?> _prompt(SignatureAsk ask) {
    final l = AppL10n.of(context);
    // Resolve the requester's local label (their alias, or a short node id).
    final contact = ref.read(contactProvider(ask.peer.hex)).value;
    final who = contact?.name ?? ask.peer.short;
    return showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(l.signatureAskTitle(who)),
        content: ConstrainedBox(
          // Long messages must scroll, not overflow the dialog.
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(d).size.height * 0.5,
            maxWidth: 480,
          ),
          child: SingleChildScrollView(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(d).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(ask.body),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(d).pop(true),
            icon: const Icon(Icons.verified_user_outlined, size: 18),
            label: Text(l.signatureAskConfirm),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
