import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_journal.dart';
import '../../domain/storage_compaction_policy.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import 'storage_settings_screen.dart' show fmtBytes;

typedef _CompactionResult = ({int before, int after});

void _closeCompactionRoute(Route<dynamic>? route, Object? result) {
  final navigator = route?.navigator;
  if (route == null || navigator == null || !route.isActive) return;
  if (route.isCurrent) {
    navigator.pop(result);
  } else {
    // A permission offer can now be above us. Never pop somebody else's route.
    navigator.removeRoute(route, result);
  }
}

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
  // THE NAVIGATOR, TAKEN BEFORE THE TEARDOWN.
  //
  // `beginCompactionCollection` moves the app to `preparingNode`, and the
  // router sends `/home` and the settings routes to `/preparing` when it sees
  // that. The screen this was called from is one of those, so it can be
  // unmounted while the teardown below is still awaiting — and the old code
  // then found `context.mounted` false, cancelled the collection it had just
  // opened, and returned null. The person asked to compact and was handed back
  // nothing, having never been shown the one dialog that collects the
  // passwords (report27 X28).
  //
  // Capture the root navigator before the settings page is replaced. A later
  // redirect back to home can still remove its pageless dialog; the operation
  // itself must be awaited independently below.
  final navigator = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final failure = AppL10n.of(context).settingsStorageCompactFailed;
  final ctrl = ref.read(appControllerProvider.notifier);
  final lease = ctrl.leaseIdentity();
  final bool opened;
  try {
    await ctrl.noteCompactionOffered();
    if (!navigator.mounted || !ctrl.holdsIdentity(lease)) return null;
    opened = await ctrl.beginCompactionCollection();
  } catch (_, stack) {
    errorJournal.record(
      kind: 'storage-compaction-entry',
      error: StateError('could not begin compaction collection'),
      stack: stack,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (navigator.mounted &&
        messenger != null &&
        messenger.mounted &&
        ctrl.holdsIdentity(lease)) {
      messenger.showSnackBar(SnackBar(content: Text(failure)));
    }
    // No collection was acquired. In particular, a rejected second caller
    // must not recover/unlock the first caller's still active collection.
    return null;
  }
  if (!opened || !navigator.mounted || !ctrl.holdsIdentity(lease)) {
    await ctrl.recoverCompactionCollection(
      lease: lease,
      reopenWith: currentPassword,
    );
    return null;
  }
  // A fast teardown can finish before GoRouter has rendered /preparing. A
  // dialog pushed now would belong to the old settings/home page and vanish
  // with it, leaving the session closed without ever asking for passwords.
  await WidgetsBinding.instance.endOfFrame;
  if (!navigator.mounted || !ctrl.holdsIdentity(lease)) {
    await ctrl.recoverCompactionCollection(
      lease: lease,
      reopenWith: currentPassword,
    );
    return null;
  }
  Future<_CompactionResult?>? operation;
  _CompactionResult? result;
  try {
    await showDialog<_CompactionResult>(
      context: navigator.context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: _CompactionOfferDialog(
          lease: lease,
          estimate: estimate,
          currentPassword: currentPassword,
          onOperationStarted: (future) {
            // The dialog reports failures itself. Keep a handled future even
            // if its route disappears before rewriting/reopening has finished.
            operation = future.then<_CompactionResult?>(
              (value) => value,
              onError: (Object _, StackTrace _) => null,
            );
          },
        ),
      ),
    );
  } finally {
    final pending = operation;
    if (pending == null) {
      await ctrl.recoverCompactionCollection(
        lease: lease,
        reopenWith: currentPassword,
      );
    } else {
      result = await pending;
    }
  }
  return result;
}

class _CompactionOfferDialog extends ConsumerStatefulWidget {
  const _CompactionOfferDialog({
    required this.lease,
    required this.estimate,
    required this.currentPassword,
    required this.onOperationStarted,
  });

  final CompactionEstimate estimate;
  final IdentityLease lease;
  final String currentPassword;
  final ValueChanged<Future<_CompactionResult?>> onOperationStarted;

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
  bool _failedRun = false;
  bool get _current =>
      mounted &&
      ref.read(appControllerProvider.notifier).holdsIdentity(widget.lease);

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

  Future<bool> _accept(String password, {bool silent = false}) async {
    if (password.isEmpty || _busy || !_current) return false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final probe = await ref
          .read(appControllerProvider.notifier)
          .probeCompactionIdentity(password);
      if (!_current) return false;
      if (!probe.opened) {
        setState(() {
          _busy = false;
          // Read where it is USED. The silent first pass has no message to show,
          // and going looking for one is what used to break it.
          if (!silent) _error = AppL10n.of(context).compactOfferUnknown;
        });
        return false;
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
        // UTF-8, the same boundary `probeCompactionIdentity` just opened the
        // space through. `codeUnits` is UTF-16, which is only the same thing
        // for ASCII: a Cyrillic character is one code unit above 255, and the
        // `Uint8List.fromList` these bytes pass through on the way to
        // `compact_known` TRUNCATES it. So a non-ASCII password that opened the
        // space at the probe reached the repack as different bytes — normally
        // AuthFailed before the rename, with the source container intact, but
        // the roster had already ticked that identity off as covered
        // (report27 X29).
        passwordBytes: utf8.encode(password),
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
      return added;
    } catch (_, stack) {
      errorJournal.record(
        kind: 'storage-compaction-probe',
        error: StateError('compaction password probe failed'),
        stack: stack,
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
      if (_current) {
        setState(
          () => _error = AppL10n.of(context).settingsStorageCompactFailed,
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run() async {
    if (_busy || _failedRun || !_current) return;
    // A typed password is an instruction to keep that space, even if the
    // separate Add button was obscured by the mobile keyboard. Never silently
    // discard it and compact only the already collected spaces.
    if (_password.text.isNotEmpty && !await _accept(_password.text)) return;
    if (!mounted || !_current || _roster.length == 0 || !_roster.isComplete) {
      return;
    }
    final route = ModalRoute.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l = AppL10n.of(context);
    setState(() => _busy = true);
    try {
      final operation = ref
          .read(appControllerProvider.notifier)
          .compactStorageKeeping(
            roster: _roster,
            reopenWith: widget.currentPassword,
          );
      widget.onOperationStarted(operation);
      final sizes = await operation;
      _closeCompactionRoute(route, sizes);
    } catch (error, stack) {
      final incomplete = error is CompactionRosterRepairIncomplete;
      final failure = incomplete
          ? l.settingsStorageCompactRepairIncomplete
          : l.settingsStorageCompactFailed;
      // The controller has already attempted to reopen the session in finally.
      // Do not probe or retry against that open handle. Close this offer and
      // start a new collection if the person wants another attempt.
      errorJournal.record(
        kind: 'storage-compaction',
        error: incomplete ? error : StateError('compaction failed'),
        stack: stack,
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
      if (mounted && (route?.isActive ?? false)) {
        setState(() {
          _failedRun = true;
          _error = failure;
        });
      } else if (messenger?.mounted ?? false) {
        messenger!.showSnackBar(SnackBar(content: Text(failure)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final route = ModalRoute.of(context);
    if (!_current) {
      _closeCompactionRoute(route, null);
      return;
    }
    setState(() => _busy = true);
    final operation = _failedRun
        ? Future<_CompactionResult?>.value(null)
        : ref
              .read(appControllerProvider.notifier)
              .cancelCompactionCollection(widget.currentPassword)
              .then<_CompactionResult?>((_) => null);
    widget.onOperationStarted(operation);
    await operation;
    _closeCompactionRoute(route, null);
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
              enabled: !_busy && !_failedRun && _current,
              decoration: InputDecoration(
                labelText: l.compactOfferPassword,
                errorText: _failedRun ? null : _error,
              ),
              onSubmitted: _busy || _failedRun || !_current ? null : _accept,
            ),
            if (_failedRun && _error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _busy || _failedRun || !_current
                    ? null
                    : () => _accept(_password.text),
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
          onPressed:
              _busy ||
                  _failedRun ||
                  !_current ||
                  _roster.length == 0 ||
                  missing.isNotEmpty
              ? null
              : _run,
          child: Text(l.compactOfferRun),
        ),
      ],
    );
  }
}
