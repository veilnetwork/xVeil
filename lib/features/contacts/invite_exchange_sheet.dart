import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/transport/bootstrap_invite.dart';
import '../../data/transport/peers_invite.dart';
import '../../l10n/app_localizations.dart';
import 'qr_scan_screen.dart';

/// Contact-add UX over veil bootstrap invites. Shows THIS device's invite as a
/// QR to share, and accepts a peer's invite (pasted; camera scan plugs in
/// later). Both directions are needed: each device shares its invite and
/// redeems the other's, which forms the bidirectional session veil requires.
///
/// Deliberately decoupled from the node: [myInvite] is supplied by the caller
/// and [onAddContact] fires with the parsed peer invite — so the whole flow is
/// widget-testable without a running node.
class InviteExchangeSheet extends StatefulWidget {
  const InviteExchangeSheet({
    super.key,
    required this.myInvite,
    required this.onAddContact,
    this.onImportPeers,
  });

  /// This device's `veil:bootstrap?…` URI, or null while the node is starting.
  final String? myInvite;

  final void Function(BootstrapInvite invite) onAddContact;

  /// Optional: handle a pasted/scanned `veil:peers?…` entry-node share — adds
  /// the bootstrap peers WITHOUT creating a contact. Null ⇒ the sheet treats a
  /// peers-share as an invalid invite (the contact-only callers).
  final void Function(List<BootstrapInvite> peers)? onImportPeers;

  @override
  State<InviteExchangeSheet> createState() => _InviteExchangeSheetState();
}

class _InviteExchangeSheetState extends State<InviteExchangeSheet> {
  final _paste = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  void _add() {
    final text = _paste.text.trim();
    // A peers-share (entry nodes, no identity) is a distinct token — import it
    // as bootstrap peers when the caller supports that, never as a contact.
    if (SharedPeers.looksLikeSharedPeers(text) && widget.onImportPeers != null) {
      try {
        final shared = SharedPeers.parse(text);
        setState(() => _error = null);
        widget.onImportPeers!(shared.peers);
        return;
      } on FormatException {
        setState(() => _error = AppL10n.of(context).inviteInvalid);
        return;
      }
    }
    try {
      final invite = BootstrapInvite.parse(text);
      setState(() => _error = null);
      widget.onAddContact(invite);
    } on FormatException {
      setState(() => _error = AppL10n.of(context).inviteInvalid);
    }
  }

  Future<void> _scan() async {
    final uri = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (uri == null || !mounted) return;
    // Drop the scanned URI into the paste field (so it's visible/editable) then
    // run the same validation+add path as a manual paste.
    _paste.text = uri;
    _add();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.inviteAddContact,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          if (widget.myInvite != null) ...[
            Text(l.inviteShowToContact,
                style: Theme.of(context).textTheme.labelMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: widget.myInvite!,
                  size: 180,
                  // Errors (e.g. data too long) render inline, never throw.
                  errorStateBuilder: (_, _) => SizedBox(
                    width: 180,
                    height: 180,
                    child: Center(child: Text(l.inviteTooLarge)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // The raw link, so it works on desktop (no camera) — selectable +
            // copyable.
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                widget.myInvite!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: widget.myInvite!));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l.inviteCopied)),
                    );
                  }
                },
                icon: const Icon(Icons.copy, size: 18),
                label: Text(l.inviteCopyMine),
              ),
            ),
            // Identity details — your node_id (what others address you by; it is
            // the BLAKE3 of the public key the invite already encodes), plus the
            // raw public key / nonce / algorithm, readable + copyable.
            Builder(builder: (context) {
              BootstrapInvite? id;
              try {
                id = BootstrapInvite.parse(widget.myInvite!);
              } catch (_) {}
              if (id == null) return const SizedBox.shrink();
              return Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  title: Text(l.identityDetails,
                      style: Theme.of(context).textTheme.labelLarge),
                  children: [
                    _idRow(context, 'node_id', id.nodeId.hex),
                    _idRow(context, l.identityPublicKey,
                        base64.encode(id.publicKey)),
                    _idRow(context, 'nonce', base64.encode(id.nonce)),
                    _idRow(context, l.identityAlgo, id.algo),
                  ],
                ),
              );
            }),
            const Divider(height: 32),
          ],
          Text(l.invitePasteTheirs,
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _paste,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: 'veil:bootstrap?…',
              errorText: _error,
              suffixIcon: IconButton(
                icon: const Icon(Icons.qr_code_scanner),
                tooltip: l.inviteScanTooltip,
                onPressed: _scan,
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _add,
            style: FilledButton.styleFrom(backgroundColor: scheme.primary),
            child: Text(l.inviteAddButton),
          ),
        ],
        ),
      ),
    );
  }

  /// One labelled, monospace, copyable identity field (node_id / key / nonce).
  Widget _idRow(BuildContext context, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.outline)),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  value,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: value));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(AppL10n.of(context).inviteCopied)),
                    );
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
