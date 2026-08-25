import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/runtime_dir_sweep.dart';
import 'package:xveil/data/veil_stack.dart';

/// On a platform where process liveness cannot be asked for — Windows — the
/// sweep falls back to recency. It measured that as the newest mtime anywhere
/// under the tree, which is exactly what a live but IDLE sibling never moves:
/// it does no I/O, so after a day of quiet its runtime directory was reclaimed
/// out from under it (report12 X-M11).
///
/// The owner now says so itself, on a timer. What the sweep reads is that
/// statement, and an owner that crashed stops making it.
void main() {
  late Directory base;

  setUp(() => base = Directory.systemTemp.createTempSync('xveil-lease'));
  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  test('a heartbeat moves the marker an idle owner never would', () async {
    final lease = await RuntimeDirLease.acquire(base.path);
    addTearDown(lease.release);
    final marker = File('${lease.path}/$kRuntimeDirMarker');

    // Where an idle owner would sit forever: the marker as written at
    // creation, and no I/O of its own to move anything else under the tree.
    final stale = DateTime.now().subtract(const Duration(hours: 30));
    marker.setLastModifiedSync(stale);
    expect(
      (await newestMtimeUnder(Directory(lease.path)))
          .isBefore(DateTime.now().subtract(const Duration(hours: 24))),
      isFalse,
      reason:
          'the directory itself is fresh here, so this fixture pins the '
          'MARKER moving and the sweep test pins what that is worth',
    );

    lease.touchLease();
    expect(
      marker.lastModifiedSync().isAfter(
        DateTime.now().subtract(const Duration(minutes: 1)),
      ),
      isTrue,
      reason:
          'the heartbeat is the only thing an idle owner has to say it is '
          'still there',
    );
  });

  test('a sweep leaves an idle owner alone and takes a crashed one', () async {
    final lease = await RuntimeDirLease.acquire(base.path);
    addTearDown(lease.release);

    // A directory named for another pid whose liveness cannot be answered —
    // the Windows case. The clock is moved forward rather than the files back,
    // the way the rest of the sweep's tests do it.
    final other = Directory('${base.path}/xveil-rt-999999')..createSync();
    await markRuntimeDirOwned(other.path);
    final marker = File('${other.path}/$kRuntimeDirMarker');
    final future = DateTime.now().add(const Duration(hours: 30));

    Future<int> sweep() => sweepStaleRuntimeDirs(
      base.path,
      pidAlive: (_) async => null, // the Windows answer: unknown
      now: () => future,
    );

    // Idle for thirty hours, but still beating.
    marker.setLastModifiedSync(future.subtract(const Duration(minutes: 5)));
    expect(
      await sweep(),
      0,
      reason: 'a fresh heartbeat means somebody is still in there',
    );
    expect(other.existsSync(), isTrue);

    // Stopped beating, and nothing else touched the tree either.
    marker.setLastModifiedSync(DateTime.now());
    expect(
      await sweep(),
      1,
      reason: 'a marker that stopped moving is an owner that stopped running',
    );
    expect(other.existsSync(), isFalse);
  });
}
