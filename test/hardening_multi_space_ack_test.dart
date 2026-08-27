import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/multi_space_store.dart';

import 'support/fake_multi_space.dart';

/// A container open for several spaces at once must answer about its hardening
/// like any other.
///
/// `MultiSpaceHandle` had no `stats` on the FFI surface, so this backing
/// answered `null` for the record and did NOTHING for the acknowledgement
/// while returning normally. Both halves were wrong in the same direction:
/// `null` is read one layer up as "there was no warning", and an
/// acknowledgement that returns tells its caller to clear the app's copy — so
/// a kept warning was cleared with nothing on the native side agreeing
/// (report16 XV-08).
///
/// The FFI has both now. What is pinned here is the CONTRACT the storage layer
/// keeps over whatever the backing answers: both copies or neither. The wire
/// path itself is driven through the real library in the plugin's own suite,
/// and the Rust side proves a real record crosses.

/// A backing whose acknowledgement fails, the way the native one does when the
/// container refuses.
class _RefusingBacking extends FakeMultiSpaceBacking {
  int acks = 0;

  @override
  void acknowledgeHardeningWarning(int id) {
    acks++;
    throw hv.HvException('Io', 'the container refused the acknowledgement');
  }
}

/// A backing that reports a record and clears it when acknowledged — what the
/// native one now does.
class _ReportingBacking extends FakeMultiSpaceBacking {
  String? staged = 'sync: writes are not on the platter';
  int acks = 0;

  @override
  String? hardeningWarning(int id) => staged;

  @override
  void acknowledgeHardeningWarning(int id) {
    acks++;
    staged = null;
  }
}

void main() {
  test('a record the container reports reaches the app and is kept', () async {
    // The whole chain with no native code in it: a multi-space backing that
    // reports, the per-space store over it, and the storage that keeps a copy
    // of what it was shown. This answered `null` before the FFI existed, and
    // `null` one layer up means "nothing wrong".
    final backing = _ReportingBacking();
    final id = backing.openSpace(Uint8List(64));
    final storage = HiddenVolumeStorage(
      ({required password, required bool create}) =>
          MultiSpaceKvLogStore(backing, id),
    );
    await storage.open(password: 'pw', createIfMissing: true);

    expect(
      await storage.retainHardeningWarning(),
      'sync: writes are not on the platter',
      reason: 'the container reported it and the app must take it',
    );

    // The container forgets at close; the app must not.
    backing.staged = null;
    expect(
      await storage.retainHardeningWarning(),
      'sync: writes are not on the platter',
    );
  });

  test('acknowledging clears BOTH copies', () async {
    final backing = _ReportingBacking();
    final id = backing.openSpace(Uint8List(64));
    final storage = HiddenVolumeStorage(
      ({required password, required bool create}) =>
          MultiSpaceKvLogStore(backing, id),
    );
    await storage.open(password: 'pw', createIfMissing: true);
    expect(
      await storage.retainHardeningWarning(),
      isNotNull,
      reason: 'premise',
    );

    await storage.acknowledgeHardeningWarning();

    expect(backing.acks, 1, reason: "the container's own record must go too");
    expect(await storage.retainHardeningWarning(), isNull);
  });

  test('and a refused acknowledgement clears NEITHER', () async {
    // The contract the multi-space no-op used to break from the other end: it
    // returned normally having done nothing, so the app's copy went and the
    // container's stayed.
    final backing = _RefusingBacking();
    final id = backing.openSpace(Uint8List(64));
    final storage = HiddenVolumeStorage(
      ({required password, required bool create}) =>
          MultiSpaceKvLogStore(backing, id),
    );
    await storage.open(password: 'pw', createIfMissing: true);
    await storage.putSetting(
      'container_hardening_warning',
      'sync: not flushed',
    );

    await expectLater(
      storage.acknowledgeHardeningWarning(),
      throwsA(isA<hv.HvException>()),
      reason:
          'an acknowledgement the container refused must not report success',
    );
    expect(backing.acks, 1, reason: 'premise: the store was asked');

    expect(
      await storage.retainHardeningWarning(),
      'sync: not flushed',
      reason: 'the app copy was cleared with nothing agreeing to it',
    );
  });

  test('and the backing routes to the multi-space FFI, not to nothing', () {
    // Read from the source: `HvMultiSpaceBacking` needs an open native
    // container to construct, and a test that skips without the dynamic
    // library asserts nothing. What can rot is which call each override makes,
    // and that is a fact about the file. The searched file is not this one, so
    // the assertions cannot match their own text.
    final source = File(
      'lib/data/storage/hv_kv_log_store.dart',
    ).readAsStringSync();
    final start = source.indexOf('class HvMultiSpaceBacking');
    expect(start, isNot(-1), reason: 'the class was renamed');
    final body = source.substring(start);

    expect(
      body,
      contains('_multi.acknowledgeHardeningError(id)'),
      reason:
          'an acknowledgement that reaches nothing tells its caller to clear '
          'the app copy with nothing agreeing',
    );
    expect(
      body,
      contains('_multi.stats(id).hardeningFailure'),
      reason: 'a flat null here reads as "there was no warning" one layer up',
    );
    expect(
      body,
      isNot(
        contains(
          'return null;\n  }\n\n  @override\n  String? hardeningWarning',
        ),
      ),
      reason: 'the utilization is answered again without asking',
    );
  });
}
