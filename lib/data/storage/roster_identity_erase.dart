import 'dart:typed_data';

import '../../domain/pending_identity_erase.dart';
import '../../domain/roster.dart';
import '../../domain/storage_locator.dart';
import 'storage.dart';

/// Runs only after the parent has authenticated and all hosted children have
/// stopped. Every await is fenced by the caller's lifecycle. The parent port
/// remains immutable; erasing a legacy child may close/reopen it through the
/// erase callback, but must return the SAME parent open before publication.
abstract final class RosterIdentityErase {
  static void _keepsIdentity(
    List<RosterEntry> roster,
    PendingIdentityErase intent,
  ) {
    final matches = roster.where(intent.matches).length;
    if (matches > 1) {
      throw const IdentityEraseFailure(IdentityEraseFailureKind.conflict);
    }
    if (roster.length - matches < 1) {
      throw const IdentityEraseFailure(IdentityEraseFailureKind.lastIdentity);
    }
  }

  static Future<List<RosterEntry>> start({
    required Storage master,
    required IdentityStorageLocator root,
    required Uint8List masterKeys,
    required List<RosterEntry> roster,
    required RosterEntry target,
    required void Function() check,
    required Future<void> Function(RosterEntry target) erase,
    required void Function(List<RosterEntry>) retainRoster,
  }) async {
    check();
    final intent = PendingIdentityErase.authorized(
      root: root,
      masterKeys: masterKeys,
      target: target,
    );
    try {
      if (!roster.any(intent.matches)) {
        throw const IdentityEraseFailure(IdentityEraseFailureKind.conflict);
      }
      _keepsIdentity(roster, intent);
      final previous = await master.getSetting(kPendingIdentityErase);
      check();
      if (previous != null && previous.isNotEmpty) {
        final pending = PendingIdentityErase.decode(previous);
        try {
          pending.validate(root, masterKeys);
          if (!pending.sameTarget(intent)) {
            throw const IdentityEraseFailure(IdentityEraseFailureKind.conflict);
          }
        } finally {
          pending.destroy();
        }
      } else {
        // Durable authorization precedes the first destructive callback.
        await master.putSetting(kPendingIdentityErase, intent.encode());
        check();
      }
      return await resume(
        master: master,
        root: root,
        masterKeys: masterKeys,
        roster: roster,
        check: check,
        erase: erase,
        retainRoster: retainRoster,
      );
    } finally {
      intent.destroy();
    }
  }

  static Future<List<RosterEntry>> resume({
    required Storage master,
    required IdentityStorageLocator root,
    required Uint8List masterKeys,
    required List<RosterEntry> roster,
    required void Function() check,
    required Future<void> Function(RosterEntry target) erase,
    // Adopt newly read buffers BEFORE a cancellation check can throw.
    required void Function(List<RosterEntry>) retainRoster,
  }) async {
    check();
    final raw = await master.getSetting(kPendingIdentityErase);
    check();
    if (raw == null || raw.isEmpty) return roster;
    final intent = PendingIdentityErase.decode(raw);
    RosterEntry? target;
    try {
      intent.validate(root, masterKeys);
      _keepsIdentity(roster, intent);
      target = intent.copyTarget();
      await erase(target);
      check();
      // Reload after erasure: never replace the parent with an old full-list
      // snapshot. Exact locator+keys match survives label changes safely.
      final current = await master.loadRoster();
      if (current != null) retainRoster(current);
      check();
      if (current == null) {
        throw const IdentityEraseFailure(IdentityEraseFailureKind.invalid);
      }
      _keepsIdentity(current, intent);
      final updated = current.where((entry) => !intent.matches(entry)).toList();
      await master.saveRoster(updated);
      check();
      // Separate durable writes are intentional: a crash here repeats an
      // idempotent erase against the new roster before clearing the journal.
      await master.putSetting(kPendingIdentityErase, '');
      check();
      return updated;
    } finally {
      target?.spaceKeys.fillRange(0, target.spaceKeys.length, 0);
      intent.destroy();
    }
  }
}
