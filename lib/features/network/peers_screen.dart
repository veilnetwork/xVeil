import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/transport/veil_transport.dart';
import '../../l10n/app_localizations.dart';
import '../../state/providers.dart';

/// The peers detail screen, reached by tapping the peer count on the network
/// tab. Lists the node's peers split into Active / Inactive, each with a
/// human "last active" line, and a tap-through to full per-peer details.
///
/// HONESTY: every value shown comes straight from [peersProvider] (which wraps
/// veil's `veil_peers_list`). "Last active" is the moment THIS device observed
/// the peer active — there is no node-side timestamp — so the detail view says
/// so explicitly. Nothing here is fabricated.
class PeersScreen extends ConsumerWidget {
  const PeersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final peersAsync = ref.watch(peersProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l.peersTitle)),
      body: peersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _Empty(message: '$e'),
        data: (peers) {
          if (peers.isEmpty) {
            return _Empty(message: l.peersEmpty, hint: l.peersEmptyHint);
          }
          final active = peers.where((p) => p.isActive).toList();
          final inactive = peers.where((p) => !p.isActive).toList();
          return ListView(
            children: [
              if (active.isNotEmpty) ...[
                _SectionHeader(
                    label: l.peersSectionActive, count: active.length),
                ...active.map((p) => _PeerTile(peer: p)),
              ],
              if (inactive.isNotEmpty) ...[
                _SectionHeader(
                    label: l.peersSectionInactive, count: inactive.length),
                ...inactive.map((p) => _PeerTile(peer: p)),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.count});
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        '$label · $count',
        style: Theme.of(context)
            .textTheme
            .labelLarge
            ?.copyWith(color: scheme.primary),
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer});
  final PeerInfo peer;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (dotColor, _) = _stateVisual(peer.state, scheme);
    final subtitle = peer.isActive
        ? l.peerActiveNow
        : (peer.lastSeen == null
            ? l.peerNeverSeen
            : '${l.peerLastSeenLabel} · ${relativeTime(context, peer.lastSeen!)}');
    return ListTile(
      leading: Icon(Icons.circle, size: 12, color: dotColor),
      title: Text(
        '${peer.nodeId.short}…',
        style: const TextStyle(fontFamily: 'monospace'),
      ),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => _PeerDetailSheet(peer: peer),
      ),
    );
  }
}

class _PeerDetailSheet extends StatelessWidget {
  const _PeerDetailSheet({required this.peer});
  final PeerInfo peer;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final lastSeen = peer.isActive
        ? l.peerActiveNow
        : (peer.lastSeen == null
            ? l.peerNeverSeen
            : relativeTime(context, peer.lastSeen!));
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 0, 24, 24 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.peerDetailsTitle,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          _field(context, l.peerFieldNodeId, peer.nodeId.hex, copyable: true),
          _field(context, l.peerFieldState, _stateLabel(context, peer.state)),
          _field(context, l.peerFieldDirection,
              _dirLabel(context, peer.direction)),
          if (peer.transport.isNotEmpty)
            _field(context, l.peerFieldTransport, peer.transport,
                copyable: true),
          _field(context, l.peerFieldLastSeen, lastSeen),
        ],
      ),
    );
  }

  Widget _field(BuildContext context, String label, String value,
      {bool copyable = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
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
                      const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              if (copyable)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy, size: 16),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: value));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text(AppL10n.of(context).inviteCopied)),
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

class _Empty extends StatelessWidget {
  const _Empty({required this.message, this.hint});
  final String message;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hub_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: 16),
            Text(message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
            if (hint != null) ...[
              const SizedBox(height: 8),
              Text(hint!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: scheme.outline)),
            ],
          ],
        ),
      ),
    );
  }
}

(Color, IconData) _stateVisual(PeerState s, ColorScheme scheme) =>
    switch (s) {
      PeerState.active => (Colors.green, Icons.check_circle),
      PeerState.connecting => (scheme.tertiary, Icons.sync),
      PeerState.closed => (scheme.outline, Icons.cloud_off),
      PeerState.unknown => (scheme.outline, Icons.help_outline),
    };

String _stateLabel(BuildContext context, PeerState s) {
  final l = AppL10n.of(context);
  return switch (s) {
    PeerState.active => l.peerStateActive,
    PeerState.connecting => l.peerStateConnecting,
    PeerState.closed => l.peerStateClosed,
    PeerState.unknown => l.peerStateUnknown,
  };
}

String _dirLabel(BuildContext context, PeerDirection d) {
  final l = AppL10n.of(context);
  return switch (d) {
    PeerDirection.inbound => l.peerDirInbound,
    PeerDirection.outbound => l.peerDirOutbound,
    PeerDirection.unknown => l.peerDirUnknown,
  };
}

/// Coarse, localized "time ago" for a last-seen stamp. Deliberately low
/// resolution (just-now / minutes / hours / days) — the stamp is itself
/// approximate (poll-driven), so finer precision would be false confidence.
String relativeTime(BuildContext context, DateTime when) {
  final l = AppL10n.of(context);
  final d = DateTime.now().difference(when);
  if (d.inMinutes < 1) return l.timeJustNow;
  if (d.inMinutes < 60) return l.timeMinutesAgo(d.inMinutes);
  if (d.inHours < 24) return l.timeHoursAgo(d.inHours);
  return l.timeDaysAgo(d.inDays);
}
