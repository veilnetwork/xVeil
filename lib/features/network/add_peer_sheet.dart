import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../common/shown_cause.dart';
import '../../data/transport/bootstrap_invite.dart';
import '../../l10n/app_localizations.dart';
import '../../state/providers.dart';

/// Add one peer by hand from its `veil:bootstrap?…` link.
///
/// Until this existed the only way to gain a peer was to be given one: the
/// invite exchange on the contacts tab, a shared entry-node list, or a
/// deployment that saved one for you. Someone holding a link and looking at an
/// empty peer list had nowhere to put it.
///
/// The clipboard is read on open and the field is prefilled when it holds a
/// valid invite, because pasting is what everyone was going to do anyway.
class AddPeerSheet extends ConsumerStatefulWidget {
  const AddPeerSheet({super.key});

  @override
  ConsumerState<AddPeerSheet> createState() => _AddPeerSheetState();
}

class _AddPeerSheetState extends ConsumerState<AddPeerSheet> {
  final _uri = TextEditingController();
  BootstrapInvite? _parsed;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _uri.addListener(_validate);
    _prefillFromClipboard();
  }

  @override
  void dispose() {
    _uri.dispose();
    super.dispose();
  }

  Future<void> _prefillFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty || !mounted) return;
    try {
      BootstrapInvite.parse(text);
    } catch (_) {
      return; // the clipboard holds something else — leave the field alone
    }
    _uri.text = text;
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) _uri.text = text;
  }

  void _validate() {
    final text = _uri.text.trim();
    if (text.isEmpty) {
      setState(() {
        _parsed = null;
        _error = null;
      });
      return;
    }
    final l = AppL10n.of(context);
    try {
      final invite = BootstrapInvite.parse(text);
      // An identity-only invite parses cleanly and adds nothing: addContact
      // returns early when there is no transport, because there would be no
      // address to dial. Saying so here beats a success message and an
      // unchanged list.
      setState(() {
        _parsed = invite.transport == null ? null : invite;
        _error = invite.transport == null ? l.peersAddNoTransport : null;
      });
    } on FormatException catch (e) {
      setState(() {
        _parsed = null;
        _error = l.peersAddInvalid(e.message);
      });
    }
  }

  Future<void> _add() async {
    final invite = _parsed;
    if (invite == null) return;
    final l = AppL10n.of(context);
    setState(() => _busy = true);
    try {
      final stack = ref.read(realStackProvider);
      if (stack == null) throw StateError(l.peersAddNoNode);
      await stack.addContact(invite);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.peersAddDone)));
    } catch (e) {
      if (mounted) {
        setState(() => _error = l.peersAddFailed(shownCause(e, kind: 'peer')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final invite = _parsed;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.peersAddTitle, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            l.peersAddHint,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _uri,
            minLines: 2,
            maxLines: 4,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: InputDecoration(
              labelText: l.peersAddFieldLabel,
              hintText: 'veil:bootstrap?pk=…',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: l.peersAddPaste,
                icon: const Icon(Icons.content_paste),
                onPressed: _paste,
              ),
            ),
          ),
          if (invite != null) ...[
            const SizedBox(height: 12),
            // Show what the link resolved to before it is acted on: the node
            // id is what the peer will appear as, and the transport is the
            // address that has to be reachable for any of this to work.
            Text(
              l.peersAddResolved(
                invite.nodeId.hex.substring(0, 16),
                invite.transport ?? '',
              ),
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: scheme.error, fontSize: 13)),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: (invite == null || _busy) ? null : _add,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.person_add_alt),
            label: Text(l.peersAddAction),
          ),
        ],
      ),
    );
  }
}
