import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/multi_space_store.dart';

import 'support/fake_multi_space.dart';

/// A container open for several spaces at once cannot acknowledge a hardening
/// record: `MultiSpaceHandle` has no `stats` on the FFI surface, so there is
/// nothing on the native side to clear.
///
/// It used to return normally anyway. The acknowledgement's contract is "both
/// copies or neither", and its caller writes the app's copy off the moment the
/// store's half returns — so on a multi-space container a kept warning was
/// cleared with nothing agreeing, which is the same silent dismissal the
/// ordering fix was written for (report16 XV-08).
///
/// Nothing is lost in the ordinary case: with no record to show, the button
/// that calls this is never on screen. It is reached only when a warning IS
/// kept — exactly where clearing it silently is wrong.

/// A backing that answers the way the native multi-space one does.
class _RefusingBacking extends FakeMultiSpaceBacking {
  int acks = 0;

  @override
  void acknowledgeHardeningWarning(int id) {
    acks++;
    throw multiSpaceCannotAcknowledgeHardening();
  }
}

void main() {
  test('the refusal is a refusal, not a bug report', () {
    final refusal = multiSpaceCannotAcknowledgeHardening();

    expect(
      refusal.kind,
      isNot('Internal'),
      reason:
          'that kind documents itself as a library bug; this is a surface '
          'that does not exist yet',
    );
    expect(refusal.message, contains('multi-space'));
  });

  test('and the multi-space backing throws it rather than returning', () {
    // Read from the source: `HvMultiSpaceBacking` needs an open native
    // container to construct, and a test that skips without the dynamic
    // library asserts nothing. What can rot is one line, and it is a fact
    // about the file. The searched file is not this one, so the assertion
    // cannot match its own text.
    final source = File(
      'lib/data/storage/hv_kv_log_store.dart',
    ).readAsStringSync();
    final start = source.indexOf('class HvMultiSpaceBacking');
    expect(start, isNot(-1), reason: 'the class was renamed');
    final body = source.substring(start);
    final ack = body.indexOf('void acknowledgeHardeningWarning(int id) {');
    expect(ack, isNot(-1), reason: 'the override was renamed or removed');
    // Enough to reach past the comment that explains it. Written at 900 first,
    // which stopped inside the comment and made the search look for the throw
    // in text that could not contain it.
    expect(body.length - ack, greaterThan(1600), reason: 'window truncated');

    expect(
      body.substring(ack, ack + 1600),
      contains('throw multiSpaceCannotAcknowledgeHardening()'),
      reason:
          'a multi-space acknowledgement that returns normally tells its '
          'caller to clear the app copy with nothing on the native side '
          'agreeing',
    );
  });

  test('a kept warning survives a multi-space session', () async {
    // The whole chain, with no native code in it: a multi-space backing that
    // refuses, the per-space store over it, and the storage that keeps the
    // app's copy.
    final backing = _RefusingBacking();
    final id = backing.openSpace(Uint8List(64));
    final store = MultiSpaceKvLogStore(backing, id);
    final storage = HiddenVolumeStorage(
      ({required password, required bool create}) => store,
    );
    await storage.open(password: 'pw', createIfMissing: true);

    // A warning from an earlier session, kept by the app. The container's own
    // record is gone — it lives in memory only — which is exactly why the
    // app's copy is the one that matters here.
    await storage.putSetting(
      'container_hardening_warning',
      'sync: not flushed',
    );
    expect(
      await storage.retainHardeningWarning(),
      'sync: not flushed',
      reason: 'premise',
    );

    await expectLater(
      storage.acknowledgeHardeningWarning(),
      throwsA(isA<hv.HvException>()),
      reason: 'an acknowledgement nothing can act on must not report success',
    );
    expect(backing.acks, 1, reason: 'premise: the store was asked');

    expect(
      await storage.retainHardeningWarning(),
      'sync: not flushed',
      reason: 'the app copy was cleared with nothing agreeing to it',
    );
  });

  test('CONTROL: a backing that CAN acknowledge still clears both', () async {
    // Vacuity guard. If every acknowledgement refused, the assertion above
    // would be satisfied by a store nobody can ever dismiss a warning on.
    final backing = FakeMultiSpaceBacking();
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

    await storage.acknowledgeHardeningWarning();

    expect(await storage.retainHardeningWarning(), isNull);
  });
}
