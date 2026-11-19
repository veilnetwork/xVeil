// Build this Flutter-free entrypoint with `dart build cli` (a temporary bin/
// forwarding entrypoint is sufficient), retaining the ordinary SQLite assets.
// Bundle reviewed Veil and hidden-volume libraries in lib/. The Windows helper
// creates a stable but read-shared disposable parent independently of our code.
import 'dart:convert';
import 'dart:io';

import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_fs_windows.dart' as windows;
import 'package:xveil/data/storage/profile_preferences_file.dart';

const _first = '{"fixture":"synthetic preferences first"}';
const _second = '{"fixture":"synthetic preferences second"}';

Future<void> main(List<String> args) async {
  final adminOwner = args.length == 3 && args.last == 'administrators';
  if ((!adminOwner && args.length != 2) ||
      !['exercise', 'verify'].contains(args.first)) {
    throw ArgumentError('expected exercise/verify and a disposable profile');
  }
  final profile = Directory(args[1]);
  final report = <String, Object?>{};
  ManagedProfilePreferencesFile? owner;
  const fs = ManagedFsPlatform();
  void check(String name, bool value) {
    report[name] = value;
    if (!value) throw StateError('preference probe check failed');
  }

  try {
    final base = fs.inspect(profile.path);
    check('base_read_shared', !base.ownerOnly);
    check('base_safe', base.safeAncestor);
    check(
      'base_owner_expected',
      adminOwner
          ? base.ownedByWindowsAdministrators && !base.ownedByCurrentUser
          : base.ownedByCurrentUser,
    );
    final path = '${profile.path}/xveil.prefs.json';
    owner = await ManagedProfilePreferencesFile.open(path);
    if (args.first == 'verify') {
      check('cold_read_equal', await owner.read() == _second);
      check('cold_file_private', fs.inspect(path).ownerOnly);
    } else {
      check('initially_absent', await owner.read() == null);
      check('write_accepted', await owner.write(_first));
      check('file_private', fs.inspect(path).ownerOnly);
      check('first_read_equal', await owner.read() == _first);
      await owner.close();
      owner = await ManagedProfilePreferencesFile.open(path);
      check('reopened_read_equal', await owner.read() == _first);
      // A reader admitted while a stale temporary had inherited read rights
      // keeps its handle after a DACL change. Reusing that object would expose
      // the NEXT payload through an already-open handle, despite a private
      // final DACL. A fresh private staging object must replace it instead.
      const stalePayload = 'stale synthetic preferences';
      final stale = File('$path.tmp')..writeAsStringSync(stalePayload);
      final staleOwnedByUser = fs.inspect(stale.path).ownedByCurrentUser;
      final oldReader = stale.openSync();
      var acceptedWithOldReader = false;
      try {
        acceptedWithOldReader = await owner.write(_second);
        report['write_with_old_reader_accepted'] = acceptedWithOldReader;
        check(
          'old_reader_unchanged',
          utf8.decode(oldReader.readSync(4096)) == stalePayload,
        );
      } finally {
        oldReader.closeSync();
      }
      if (!staleOwnedByUser) {
        // On an elevated run the OS can assign the Administrators group as
        // the default owner. The production writer must leave that leaf alone.
        check(
          'foreign_stale_refused',
          !acceptedWithOldReader && !await owner.write(_second),
        );
        check('foreign_stale_unchanged', stale.readAsStringSync() == stalePayload);
        stale.deleteSync(); // This probe created this exact synthetic fixture.
      }
      // Windows may deny removing a file held without delete sharing. Such
      // refusal must not expose bytes; a retry after release must still work.
      check(
        'replacement_accepted',
        acceptedWithOldReader || await owner.write(_second),
      );
      check('replacement_read_equal', await owner.read() == _second);
      check('replacement_private', fs.inspect(path).ownerOnly);

      // Exercise both production writers independently of managed admission.
      final sync = File('${profile.path}/sync.preferences.json');
      check('sync_written', writePrivateFileAtomicallySync(sync, _first));
      check('sync_private', fs.inspect(sync.path).ownerOnly);
      check('sync_read_equal', sync.readAsStringSync() == _first);
      final async = File('${profile.path}/async.preferences.json');
      check('async_written', await writePrivateFileAtomically(async, _first));
      check('async_private', fs.inspect(async.path).ownerOnly);
      check('async_read_equal', await async.readAsString() == _first);
      if (Platform.isWindows) {
        check('directory_refused', !windows.createPrivateFile(profile.path));
        final reservation = File('${profile.path}/reserved-empty');
        check(
          'reservation_created',
          windows.createPrivateFile(reservation.path),
        );
        final reserved = fs.inspect(reservation.path);
        check(
          'reservation_private',
          reserved.ownerOnly && reserved.ownedByCurrentUser,
        );
        check(
          'existing_file_refused',
          !windows.createPrivateFile(reservation.path),
        );
        check(
          'reservation_unchanged',
          reserved.sameObject(fs.inspect(reservation.path)) &&
              reservation.lengthSync() == 0,
        );
      }
    }
    final after = fs.inspect(profile.path);
    check(
      'parent_unchanged',
      base.sameObject(after) && !after.ownerOnly && after.safeAncestor,
    );
    report['ok'] = true;
  } catch (error) {
    report['ok'] = false;
    report['error_type'] = error.runtimeType.toString();
    if (error is ManagedWorkerFailure) report['failure_kind'] = error.kind.name;
  } finally {
    if (owner != null) await owner.close();
  }
  stdout.writeln(jsonEncode(report));
  if (report['ok'] != true) exitCode = 1;
}
