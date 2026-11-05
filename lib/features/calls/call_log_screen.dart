// Call journal screen (calls epic remainder / multi-device brick 4 polish).
// Renders the persistent CallLogStore — which already converges across my
// devices — newest first: direction+outcome icon, contact alias, time, talk
// duration. Tapping a row opens the 1:1 chat with that peer (where the call
// button lives), so the journal doubles as a redial surface.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/ids.dart';
import '../../domain/call_log.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/call_log.dart';
import '../../state/providers.dart';

class CallLogScreen extends ConsumerStatefulWidget {
  const CallLogScreen({super.key});

  @override
  ConsumerState<CallLogScreen> createState() => _CallLogScreenState();
}

class _CallLogScreenState extends ConsumerState<CallLogScreen> {
  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final store = ref.watch(callLogStoreProvider);
    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.navCalls),
      ),
      body: ValueListenableBuilder<int>(
        // FutureBuilder retains old data while its replacement is loading.
        // A different identity must start with a fresh private projection.
        key: ObjectKey(store),
        valueListenable: store.changes,
        builder: (context, _, _) => FutureBuilder<List<_Row>>(
          future: _load(ref, store),
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l.callLogLoadFailed, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => setState(() {}),
                      child: Text(l.lockWipeRetry),
                    ),
                  ],
                ),
              );
            }
            final rows = snap.data;
            if (rows == null) return const SizedBox.shrink();
            if (rows.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.call_outlined, size: 48),
                    const SizedBox(height: 12),
                    Text(
                      l.callLogEmpty,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        l.callLogEmptyHint,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              );
            }
            return ListView.builder(
              itemCount: rows.length,
              itemBuilder: (context, i) => _tile(context, l, rows[i]),
            );
          },
        ),
      ),
    );
  }

  Future<List<_Row>> _load(WidgetRef ref, CallLogStore store) async {
    // Capture both halves before yielding: a late old journal read must not
    // look up its peers in the newly selected identity's storage.
    final storage = ref.read(storageProvider);
    final entries = await store.list();
    final rows = <_Row>[];
    for (final e in entries) {
      String label = e.peerHex.length >= 8
          ? e.peerHex.substring(0, 8)
          : e.peerHex;
      try {
        final c = await storage.getContact(NodeId.fromHex(e.peerHex));
        if (c != null) label = c.label;
      } catch (_) {
        // malformed peer hex in a synced row — keep the raw prefix
      }
      rows.add(_Row(e, label));
    }
    return rows;
  }

  Widget _tile(BuildContext context, AppL10n l, _Row r) {
    final e = r.entry;
    final missedTint = Theme.of(context).colorScheme.error;
    final (icon, tint) = switch ((e.outgoing, e.outcome)) {
      (_, CallLogOutcome.missed) => (Icons.call_missed, missedTint),
      (true, _) => (Icons.call_made, null),
      (false, _) => (Icons.call_received, null),
    };
    final subtitle = e.provisional
        ? l.callOutcomeAnsweredElsewhere
        : switch (e.outcome) {
            CallLogOutcome.completed => _dur(e.durationSec),
            CallLogOutcome.missed => l.callOutcomeMissed,
            CallLogOutcome.declined => l.callOutcomeDeclined,
            CallLogOutcome.cancelled => l.callOutcomeCancelled,
            CallLogOutcome.busy => l.callOutcomeBusy,
            CallLogOutcome.failed => l.callOutcomeFailed,
          };
    return ListTile(
      leading: Icon(icon, color: tint),
      title: Text(r.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (e.video)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(Icons.videocam_outlined, size: 18),
            ),
          Text(
            formatDateTime(DateTime.fromMillisecondsSinceEpoch(e.atMs)),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      onTap: () => context.push('/chat/${e.peerHex}'),
    );
  }

  String _dur(int sec) {
    final m = sec ~/ 60, s = sec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

class _Row {
  const _Row(this.entry, this.label);
  final CallLogEntry entry;
  final String label;
}
