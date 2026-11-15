import 'dart:convert';
import 'dart:typed_data';
import '../../core/log.dart';
import '../../domain/roster.dart';
import '../../domain/storage_locator.dart';
import 'storage.dart';

typedef CompactionCredential = ({List<int> password, List<int> oldSpaceKeys});

Future<List<RosterEntry>?> _readRoster(Storage storage) {
  if (storage is! RosterMaintenanceReader) {
    throw StateError('strict roster inspection unavailable');
  }
  return (storage as RosterMaintenanceReader).loadRosterForMaintenance();
}

/// Shared by the controller and the full-profile worker. Mapping callbacks
/// borrow keys for this call only and must snapshot anything retained. Staged
/// handles must still be explicitly closed before native publication.
Future<List<String>> remapCompactionRosters(
  Storage storage,
  List<CompactionCredential> credentials, {
  required void Function() check,
  void Function(List<int> before, Uint8List after)? onMapped,
}) async {
  String hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  // old keys -> new keys, learned by opening each space with the password
  // that opened it before.
  final moved = <String, Uint8List>{};
  final rosterHolders = <List<int>>[];
  final failed = <String>[];
  try {
    for (final credential in credentials) {
      check();
      final password = utf8.decode(credential.password, allowMalformed: true);
      try {
        final opened = await storage.open(password: password);
        check();
        if (!opened) {
          failed.add('space');
          continue;
        }
        final keys = await storage.exportSpaceKeys();
        moved[hex(credential.oldSpaceKeys)] = keys;
        check();
        final roster = await _readRoster(storage);
        check();
        onMapped?.call(credential.oldSpaceKeys, keys);
        if (roster != null) {
          rosterHolders.add(credential.password);
        }
      } catch (e) {
        check();
        failed.add('space');
        devLog(() => 'xVeil[storage]: remap probe failed: $e');
      } finally {
        try {
          await storage.close();
        } catch (_) {}
      }
    }

    // A failed read says nothing about whether that space survived. Do not
    // publish a smaller roster from an incomplete old-to-new key map.
    check();
    if (failed.isNotEmpty) return failed;
    final currentKeys = moved.values.map(hex).toSet();
    for (final holder in rosterHolders) {
      check();
      final password = utf8.decode(holder, allowMalformed: true);
      try {
        final opened = await storage.open(password: password);
        check();
        if (!opened) {
          failed.add('roster');
          continue;
        }
        final roster = await _readRoster(storage);
        check();
        if (roster == null) {
          failed.add('roster');
          continue;
        }
        final repaired = <RosterEntry>[];
        var complete = true;
        var changed = false;
        for (final entry in roster) {
          // Only this shared container was rekeyed. A managed child keeps its
          // own keybox and outer keys, even if its bytes happen to match an
          // old/new key in this container. The locator is the authority.
          if (entry.storageLocator is ManagedStorageLocator) {
            repaired.add(entry);
            continue;
          }
          final old = hex(entry.spaceKeys);
          // Another holder may already have committed before a later write
          // failed. A retry must recognize that completed repair rather than
          // treating its current keys as a missing child.
          final next =
              moved[old] ??
              (currentKeys.contains(old) ? entry.spaceKeys : null);
          if (next == null) {
            failed.add('roster');
            complete = false;
            continue;
          }
          changed |= hex(next) != old;
          repaired.add(entry.copyWith(spaceKeys: next));
        }
        // Compaction is maintenance, not permission to delete an unresolved
        // entry. Keep this entire holder unchanged so a later repair can retry.
        if (!complete || !changed) continue;
        await storage.saveRoster(repaired);
        check();
        devLog(
          () =>
              'xVeil[storage]: roster remapped after compaction '
              '(${repaired.length} identities)',
        );
      } catch (e) {
        check();
        failed.add('roster');
        devLog(() => 'xVeil[storage]: roster remap failed: $e');
      } finally {
        try {
          await storage.close();
        } catch (_) {}
      }
    }
    check();
    return failed;
  } finally {
    for (final keys in moved.values) {
      keys.fillRange(0, keys.length, 0);
    }
  }
}
