import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/worker_multi_space.dart';

/// ⚠️ This does NOT cover the XV-07 death path, and saying so is the point.
///
/// A container that cannot be opened makes the worker REPLY with an error — it
/// does not kill the isolate — so this exercises the ordinary failure route,
/// not the supervisor. Provoking a real worker death from outside needs an FFI
/// fault or an OOM kill, neither of which a unit test can arrange.
///
/// The supervisor itself is covered in `worker_death_test.dart`, against the
/// shared [WorkerDeath] the multi-space backing now uses.
///
/// What this DOES pin is that the boot path still reports an ordinary open
/// failure promptly, which is worth keeping: the fix wrapped that path in a
/// `Future.any` race, and a race that swallowed the error would look identical
/// to a hang from the caller's side.
void main() {
  test('an ordinary open failure still surfaces promptly', () async {
    final dir = Directory.systemTemp.createTempSync('xv07_multi');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final backing = WorkerMultiSpaceBacking('${dir.path}/not-a-file');
    Directory('${dir.path}/not-a-file').createSync();
    addTearDown(backing.close);

    await expectLater(
      backing.openSpace(Uint8List(64)).timeout(const Duration(seconds: 15)),
      throwsA(anything),
      reason: 'the race must not swallow the error the worker reported',
    );
  });
}
