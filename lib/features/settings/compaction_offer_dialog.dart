import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/storage_compaction_policy.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import 'storage_settings_screen.dart' show fmtBytes;

/// Collects one password per identity, then compacts keeping all of them.
///
/// `compact_known` keeps exactly the spaces whose passwords it is given and
/// drops every other one, so this list is not a convenience — it is the
/// difference between maintenance and deletion. That is why the hint says
/// EVERY identity, and why the dialog cannot be dismissed into a compaction: it
/// either runs with the list the person built, or it puts everything back.
///
/// It opens the collection window on the way in (session down, node stopped,
/// container closed — the only state where a password can be checked) and
/// guarantees the way out: every exit path reopens.
///
/// Returns the reclaimed byte pair when it compacted, null when it did not.
Future<({int before, int after})?> showCompactionOffer(
  BuildContext context,
  WidgetRef ref, {
  required CompactionEstimate estimate,
  required String currentPassword,
}) async {
  final ctrl = ref.read(appControllerProvider.notifier);
  await ctrl.noteCompactionOffered();
  final opened = await ctrl.beginCompactionCollection();
  if (!context.mounted) {
    // Nothing can report to a gone screen, but the container still has to come
    // back — this is the path that would otherwise strand it closed.
    await ctrl.cancelCompactionCollection(currentPassword);
    return null;
  }
  if (!opened) {
    await ctrl.cancelCompactionCollection(currentPassword);
    return null;
  }
  final result = await showDialog<({int before, int after})>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CompactionOfferDialog(
      estimate: estimate,
      currentPassword: currentPassword,
    ),
  );
  return result;
}

class _CompactionOfferDialog extends ConsumerStatefulWidget {
  const _CompactionOfferDialog({
    required this.estimate,
    required this.currentPassword,
  });

  final CompactionEstimate estimate;
  final String currentPassword;

  @override
  ConsumerState<_CompactionOfferDialog> createState() => _OfferState();
}

class _OfferState extends ConsumerState<_CompactionOfferDialog> {
  final _password = TextEditingController();
  final _roster = CompactionRoster();

  /// What each accepted password unlocked, in the order it was typed — the list
  /// the person is building, shown back to them so "every identity" is
  /// something they can check rather than trust.
  final _found = <({String name, int subordinates})>[];
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // The password already in hand belongs to the identity being used, and
    // losing THAT one would be the worst outcome of all.
    _accept(widget.currentPassword, silent: true);
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _accept(String password, {bool silent = false}) async {
    if (password.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final l = AppL10n.of(context);
    final probe = await ref
        .read(appControllerProvider.notifier)
        .probeCompactionIdentity(password);
    if (!mounted) return;
    if (!probe.opened) {
      setState(() {
        _busy = false;
        if (!silent) _error = l.compactOfferUnknown;
      });
      return;
    }
    final name = probe.username ?? probe.displayName ?? '—';
    // Keyed by the password's own bytes: two labels can name one space, and
    // handing compact_known the same password twice asks it to keep the same
    // space twice.
    final added = _roster.addUnlocked(
      '$name#${_found.length}',
      passwordBytes: password.codeUnits,
    );
    setState(() {
      _busy = false;
      if (added) {
        _found.add((name: name, subordinates: probe.subordinates.length));
        _password.clear();
      } else if (!silent) {
        _error = l.compactOfferAlready;
      }
    });
  }

  Future<void> _run() async {
    setState(() => _busy = true);
    final sizes = await ref
        .read(appControllerProvider.notifier)
        .compactStorageKeeping(
          roster: _roster,
          reopenWith: widget.currentPassword,
        );
    if (mounted) Navigator.of(context).pop(sizes);
  }

  Future<void> _cancel() async {
    setState(() => _busy = true);
    await ref
        .read(appControllerProvider.notifier)
        .cancelCompactionCollection(widget.currentPassword);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final e = widget.estimate;
    return AlertDialog(
      title: Text(l.compactOfferTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.compactOfferBody(fmtBytes(e.fileBytes), fmtBytes(e.liveBytes)),
            ),
            if (!e.isExact) ...[
              const SizedBox(height: 6),
              Text(
                l.compactOfferApprox,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            Text(
              l.compactOfferPasswordsHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              autofocus: true,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: l.compactOfferPassword,
                errorText: _error,
              ),
              onSubmitted: _busy ? null : (v) => _accept(v.trim()),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _busy ? null : () => _accept(_password.text.trim()),
                child: Text(l.compactOfferAdd),
              ),
            ),
            if (_found.isNotEmpty) ...[
              const Divider(),
              Text(
                l.compactOfferKeeping,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              for (final f in _found)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.lock_open, size: 18),
                  title: Text(f.name),
                  subtitle: f.subordinates > 0
                      ? Text(l.compactOfferWithMaster(f.subordinates))
                      : null,
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _cancel,
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: _busy || _roster.length == 0 ? null : _run,
          child: Text(l.compactOfferRun),
        ),
      ],
    );
  }
}
