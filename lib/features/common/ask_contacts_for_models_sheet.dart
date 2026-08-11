// "Does anyone I know have this model?"
//
// The entry point for the whole contact exchange, and the reason it exists: a
// person whose network cannot reach the publisher can still get a model from
// someone they already talk to.
//
// It asks every accepted contact at once and fills in as answers arrive.
// There is no "no results" verdict, only "nobody has answered yet" — a contact
// who is offline, or who turned answering off, is indistinguishable from one
// who has nothing, and the sheet must not claim otherwise.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../domain/chat.dart' show Contact;
import '../../l10n/app_localizations.dart';
import '../../state/cloud_service.dart';
import '../../state/model_exchange_service.dart';

Future<void> showAskContactsForModels(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => const _AskContactsSheet(),
);

class _AskContactsSheet extends ConsumerStatefulWidget {
  const _AskContactsSheet();

  @override
  ConsumerState<_AskContactsSheet> createState() => _AskContactsSheetState();
}

class _AskContactsSheetState extends ConsumerState<_AskContactsSheet> {
  final _found = <String, PeerModelOffers>{};
  final _names = <String, String>{};
  StreamSubscription<PeerModelOffers>? _sub;
  bool _asking = true;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  Future<void> _ask() async {
    final service = ref.read(modelExchangeServiceProvider);
    // Subscribed BEFORE the questions go out. An answer from a contact on the
    // same LAN can beat the loop that is still sending, and a listener
    // attached afterwards would miss exactly the fastest peer.
    _sub = service.answers.listen((answer) {
      if (!mounted) return;
      setState(() => _found[answer.peer.hex] = answer);
    });

    final cloud = ref.read(cloudServiceProvider);
    final contacts = cloud == null
        ? const <Contact>[]
        : await cloud.acceptedContacts();
    for (final contact in contacts) {
      _names[contact.nodeId.hex] = contact.label;
    }
    await service.ask(contacts.map((c) => c.nodeId));
    if (mounted) setState(() => _asking = false);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final rows = _found.values.toList()
      ..sort((a, b) => _label(a.peer).compareTo(_label(b.peer)));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: const Icon(Icons.people_outline),
              title: Text(l.askContactsTitle),
              subtitle: Text(l.askContactsWaiting),
              trailing: _asking
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final row in rows)
                    for (final offer in row.offers)
                      ListTile(
                        dense: true,
                        title: Text(offer.label),
                        subtitle: Text(
                          '${_label(row.peer)} · '
                          '${(offer.bytes / (1024 * 1024)).round()} MB',
                        ),
                        // Opens the conversation rather than pulling the file
                        // down on its own. Sending a model is the other
                        // person's action and their bandwidth, and a tap here
                        // that silently started tens of megabytes on their
                        // device would be spending something that is not ours.
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).pop();
                          context.push('/chat/${row.peer.hex}');
                        },
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _label(NodeId peer) => _names[peer.hex] ?? peer.short;
}
