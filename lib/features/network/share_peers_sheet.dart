import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/transport/bootstrap_invite.dart';
import '../../data/transport/peers_invite.dart';
import '../../l10n/app_localizations.dart';
import '../../state/providers.dart';

/// Bottom sheet to share working network entry nodes WITHOUT sharing identity.
///
/// Source is [seedEntriesProvider] (the bundled public seed descriptors, which
/// carry the keys a redeemer needs — the live peer list does not). The user
/// ticks the nodes to share; "Generate" renders a `veil:peers?` QR + link that,
/// when redeemed, only adds bootstrap peers. Nodes currently connected are
/// badged "active" so the user can pick ones they know work right now.
class SharePeersSheet extends ConsumerStatefulWidget {
  const SharePeersSheet({super.key});

  @override
  ConsumerState<SharePeersSheet> createState() => _SharePeersSheetState();
}

class _SharePeersSheetState extends ConsumerState<SharePeersSheet> {
  // Selected node_id hexes (default: all). Null until seeds load.
  Set<String>? _selected;
  String? _generatedUri;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final seedsAsync = ref.watch(seedEntriesProvider);
    // node_ids of currently-active peers, for the "active" badge.
    final activeIds = ref
        .watch(peersProvider)
        .asData
        ?.value
        .where((p) => p.isActive)
        .map((p) => p.nodeId.hex)
        .toSet() ??
        const <String>{};

    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 0, 24, 24 + MediaQuery.of(context).viewInsets.bottom),
      child: seedsAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => _empty(context, '$e'),
        data: (seeds) {
          if (seeds.isEmpty) return _empty(context, l.peersShareNone);
          final selected = _selected ??= seeds.map((s) => s.nodeId.hex).toSet();
          if (_generatedUri != null) {
            return _result(context, _generatedUri!);
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.peersShareTitle,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(l.peersShareSubtitle,
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in seeds)
                      _seedTile(context, s, selected, activeIds),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: selected.isEmpty
                    ? null
                    : () {
                        final chosen = seeds
                            .where((s) => selected.contains(s.nodeId.hex))
                            .toList();
                        setState(
                            () => _generatedUri = SharedPeers(chosen).toUri());
                      },
                icon: const Icon(Icons.qr_code_2),
                label: Text(l.peersShareGenerate),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _seedTile(BuildContext context, BootstrapInvite s,
      Set<String> selected, Set<String> activeIds) {
    final l = AppL10n.of(context);
    final hex = s.nodeId.hex;
    final isActive = activeIds.contains(hex);
    return CheckboxListTile(
      value: selected.contains(hex),
      onChanged: (v) => setState(() {
        if (v ?? false) {
          selected.add(hex);
        } else {
          selected.remove(hex);
        }
      }),
      contentPadding: EdgeInsets.zero,
      title: Row(
        children: [
          Flexible(
            child: Text('${s.nodeId.short}…',
                style: const TextStyle(fontFamily: 'monospace')),
          ),
          if (isActive) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(l.peerActiveBadge,
                  style: const TextStyle(fontSize: 11, color: Colors.green)),
            ),
          ],
        ],
      ),
      subtitle: Text(s.transport ?? '',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
    );
  }

  Widget _result(BuildContext context, String uri) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.peersShareTitle,
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(l.peersShareScanHint,
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
              data: uri,
              size: 200,
              errorStateBuilder: (_, _) => SizedBox(
                width: 200,
                height: 200,
                child: Center(child: Text(AppL10n.of(context).inviteTooLarge)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(uri,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        ),
        const SizedBox(height: 4),
        Center(
          child: TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: uri));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(AppL10n.of(context).inviteCopied)),
                );
              }
            },
            icon: const Icon(Icons.copy, size: 18),
            label: Text(AppL10n.of(context).actionCopy),
          ),
        ),
      ],
    );
  }

  Widget _empty(BuildContext context, String message) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hub_outlined,
                size: 40, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      );
}
