// A file swapped across the open must not be sent (audit X-01).
//
// The API edge authorizes a NAME: `resolveSendableFile` checks that the path a
// token asked for resolves inside a folder that token was granted, and hands
// back the resolved name. Between that check and the open, the name is still
// just a name — a `rename` of a directory component points it somewhere else
// without touching anything inside the granted folder, and the send then reads
// a file the token was never allowed to name.
//
// Dart cannot close that window (no `openat`, no `O_NOFOLLOW`). It can bracket
// it: stamp the name's identity immediately before and immediately after the
// open, and refuse when they differ. What the old code did instead was take
// its FIRST stamp after the open and compare only once the send had finished —
// so a swap before the open was in both stamps, and a swap after it was
// reported to the caller after the peer already had the content.
//
// The swap here happens INSIDE the opener, which is the only moment that
// matters: between the two stamps. A test that swapped the file before calling
// would be testing `File.open`, not the bracket.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/serve_source.dart';

void main() {
  late Directory dir;
  late File granted;
  late File secret;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xveil_pin_');
    granted = File('${dir.path}/granted.bin')
      ..writeAsBytesSync(Uint8List.fromList(List.filled(64, 1)));
    secret = File('${dir.path}/secret.bin')
      ..writeAsBytesSync(Uint8List.fromList(List.filled(64, 2)));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  /// Replace the file at [path] with a DIFFERENT object of the same length.
  ///
  /// Same length on purpose: size is the half of the stamp that a careless
  /// attacker moves, and this test must fail for the identity half or not at
  /// all. `rename` gives the name a new inode, which is what the check reads.
  void swapUnderTheName(String path) {
    secret.renameSync(path);
  }

  test('a name swapped across the open is refused, and nothing is opened', () {
    return () async {
      var opened = 0;
      final result = await veilOpenPinnedSource(
        granted.path,
        opener: (p) async {
          opened++;
          swapUnderTheName(p);
          return veilOpenSourceForSend(p);
        },
      );
      expect(opened, 1, reason: 'the seam never ran');
      expect(
        result.source,
        isNull,
        reason:
            'the open returned a source for a name that changed identity '
            'under it — the send would offer a file this token never named',
      );
      expect(result.refusal, isNotNull);
      expect(result.stamp, isNull);
    }();
  });

  test('an untouched file opens, and carries the stamp it was opened at', () {
    // The other half. A bracket that refused everything would pass the test
    // above and make every send fail.
    return () async {
      final result = await veilOpenPinnedSource(granted.path);
      expect(
        result.refusal,
        isNull,
        reason: 'an unchanged file must still be sendable',
      );
      expect(result.source, isNotNull);
      expect(result.source!.size, 64);
      final stamp = result.stamp;
      expect(stamp, isNotNull, reason: 'a real file has an identity to stamp');
      expect(
        stamp,
        await veilSourceStamp(granted.path),
        reason: 'the stamp handed back must be the one the open happened at',
      );
      await result.source!.close();
    }();
  });

  test('the identity half is what fires, not size or mtime', () {
    // Non-vacuity for the assertion above: if this fixture's swap were visible
    // through size or mtime alone, the test would pass on a stamp that reads
    // neither device nor inode — which is exactly the degraded Windows shape.
    // Here both files are the same length, and the mtime is copied over.
    return () async {
      // Both stamped at the SAME explicit second. `setLastModified` rounds to
      // whole seconds, so copying the live mtime across leaves a sub-second
      // difference that would make this fixture pass for the wrong reason.
      final pinned = DateTime.fromMillisecondsSinceEpoch(1600000000000);
      granted.setLastModifiedSync(pinned);
      secret.setLastModifiedSync(pinned);
      final before = await veilSourceStamp(granted.path);
      secret.renameSync(granted.path);
      final after = await veilSourceStamp(granted.path);
      expect(before, isNotNull);
      expect(after, isNotNull);
      expect(
        after!.size,
        before!.size,
        reason: 'the fixture did not keep the size equal',
      );
      expect(
        after.mtimeMs,
        before.mtimeMs,
        reason: 'the fixture did not keep the mtime equal',
      );
      if (before.inode == 0 && before.deviceId == 0) {
        // A platform whose stat layout `posixLstat` does not know. The check
        // degrades to size + mtime there and this fixture is invisible to it —
        // documented on `veilOpenPinnedSource`, and not a failure here.
        return;
      }
      expect(
        after.inode == before.inode && after.deviceId == before.deviceId,
        isFalse,
        reason:
            'the swap left identity untouched, so the refusal in the first '
            'test could not have come from it',
      );
    }();
  });
}
