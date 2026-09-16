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
    //
    // AFTER the first frame, because this reaches localisations on its way to
    // the error it will not show, and a dependency lookup before `initState`
    // has finished is an assertion — which is where it fired, throwing out of
    // `initState` and skipping the one password this dialog must never lose.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _accept(widget.currentPassword, silent: true);
    });
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
    final probe = await ref
        .read(appControllerProvider.notifier)
        .probeCompactionIdentity(password);
    if (!mounted) return;
    if (!probe.opened) {
      setState(() {
        _busy = false;
        // Read where it is USED. The silent first pass has no message to show,
        // and going looking for one is what used to break it.
        if (!silent) _error = AppL10n.of(context).compactOfferUnknown;
      });
      return;
    }
    final name = probe.username ?? probe.displayName ?? '—';
    // What a master knows: every identity under it, by the keys that name its
    // space. Recorded BEFORE the password is added, so the checklist exists
    // even if this same password turns out to be a repeat.
    _roster.expectSpaces(probe.children);
    // Keyed by the password's own bytes: two labels can name one space, and
    // handing compact_known the same password twice asks it to keep the same
    // space twice.
    final added = _roster.addUnlocked(
      '$name#${_found.length}',
      passwordBytes: password.codeUnits,
      // The space this password opened — what ticks it off a master's list.
      spaceKeys: probe.spaceKeys,
    );
    setState(() {
      _busy = false;
      if (added) {
        _found.add((name: name, subordinates: probe.subordinates.length));
        _password.clear();
      } else if (!silent) {
        _error = AppL10n.of(context).compactOfferAlready;
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
    // Identities this container is known to hold that nothing typed here opens.
    final missing = _roster.uncovered;
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
                  // A master is NOT its children. Each of them is a separate
                  // space with its own password, and this one keeps none of
                  // them — which is the opposite of what this line used to
                  // say ("with N more under it", printed under "Will be
                  // kept").
                  subtitle: f.subordinates > 0
                      ? Text(l.compactOfferMasterOnly(f.subordinates))
                      : null,
                ),
            ],
            if (missing.isNotEmpty) ...[
              const Divider(),
              // The list nobody has to remember: a master names every identity
              // under it, so the app can say which ones are still missing
              // instead of asking the person to be sure.
              Text(
                l.compactOfferStillNeeded,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              for (final label in missing)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.lock_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(label),
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
          // Not "some passwords were typed" — every identity the app can see
          // has to be on the list, or the button is not a compaction.
          onPressed: _busy || _roster.length == 0 || missing.isNotEmpty
              ? null
              : _run,
          child: Text(l.compactOfferRun),
        ),
      ],
    );
  }
}
