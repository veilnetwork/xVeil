import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';

/// The container's post-commit hardening steps can fail without downgrading
/// the commit: it is durable either way. What is no longer true is quieter —
/// the commit's SIZE is readable to a multi-snapshot adversary, or the slots
/// it reused stand alone in a snapshot diff.
///
/// The container keeps that record in MEMORY only, so a warning nobody read
/// before the app closed is gone at the next open (report12 HV-L4). The app
/// keeps its own copy, which is what survives the restart.
void main() {
  test('a warning seen once survives the container being reopened', () async {
    final backing = FakeKvLogStore()
      ..stagedHardeningWarning = 'padding: could not extend the file';
    HiddenVolumeStorage open() => HiddenVolumeStorage(
      ({required password, required bool create}) => backing,
    );

    final first = open();
    await first.open(password: 'pw', createIfMissing: true);
    expect(
      await first.retainHardeningWarning(),
      'padding: could not extend the file',
      reason: 'the container reported it and the app must take it',
    );

    // The container forgets at close. The app must not.
    backing.stagedHardeningWarning = null;
    final second = open();
    await second.open(password: 'pw', createIfMissing: false);
    expect(
      await second.retainHardeningWarning(),
      'padding: could not extend the file',
      reason:
          'the reopened handle starts clean, so a warning kept only there is '
          'a warning the person never gets',
    );
  });

  test('the FIRST warning is kept, not the latest', () async {
    final backing = FakeKvLogStore()..stagedHardeningWarning = 'padding: first';
    final storage = HiddenVolumeStorage(
      ({required password, required bool create}) => backing,
    );
    await storage.open(password: 'pw', createIfMissing: true);
    expect(await storage.retainHardeningWarning(), 'padding: first');

    // A later, different failure must not overwrite the one nobody has seen —
    // the container keeps the first for the same reason.
    backing.stagedHardeningWarning = 'churn: second';
    expect(
      await storage.retainHardeningWarning(),
      'padding: first',
      reason: 'overwriting is the earlier warning gone',
    );
  });

  test('acknowledging clears BOTH copies and it does not come back', () async {
    final backing = FakeKvLogStore()
      ..stagedHardeningWarning = 'padding: could not extend the file';
    HiddenVolumeStorage open() => HiddenVolumeStorage(
      ({required password, required bool create}) => backing,
    );

    final first = open();
    await first.open(password: 'pw', createIfMissing: true);
    expect(await first.retainHardeningWarning(), isNotNull);

    await first.acknowledgeHardeningWarning();
    expect(
      backing.hardeningAcknowledgements,
      1,
      reason: "the container's own sticky record must be cleared too",
    );
    expect(await first.retainHardeningWarning(), isNull);

    // And a reopen does not resurrect it. An empty kept value has to mean
    // "acknowledged" rather than "never seen", or the next read takes the
    // container's record again and puts the warning back.
    final second = open();
    await second.open(password: 'pw', createIfMissing: false);
    expect(await second.retainHardeningWarning(), isNull);
  });

  /// Dismissing one warning must not switch the reporting OFF.
  ///
  /// The kept copy was cleared by writing an EMPTY value, and the read treated
  /// empty as "acknowledged — do not ask the container again". So the first
  /// dismissal in a container's life silenced every hardening failure that
  /// followed it, on a store whose entire job here is to say when a commit
  /// stopped being as deniable as the policy asked for (report14 X14-M6).
  test(
    'a LATER failure is reported after an earlier one was dismissed',
    () async {
      final backing = FakeKvLogStore()
        ..stagedHardeningWarning = 'padding: first';
      final storage = HiddenVolumeStorage(
        ({required password, required bool create}) => backing,
      );
      await storage.open(password: 'pw', createIfMissing: true);
      expect(await storage.retainHardeningWarning(), 'padding: first');
      await storage.acknowledgeHardeningWarning();
      expect(await storage.retainHardeningWarning(), isNull);

      // Next week, a different step fails.
      backing.stagedHardeningWarning = 'sync: writes are not on the platter';
      expect(
        await storage.retainHardeningWarning(),
        'sync: writes are not on the platter',
        reason:
            'dismissing one notice must not be a permanent opt-out from '
            'every notice this container will ever have',
      );
    },
  );

  /// An acknowledgement the container refused is not an acknowledgement.
  ///
  /// The app used to write its own copy off FIRST and then try the container
  /// best-effort. When the container's half failed its record stayed — rightly,
  /// nobody acknowledged it — while the app side was already clear, so the
  /// warning was invisible from then on.
  test('a refused acknowledgement leaves the warning standing', () async {
    final backing = FakeKvLogStore()
      ..stagedHardeningWarning = 'padding: could not extend the file'
      ..hardeningAcknowledgeThrows = true;
    HiddenVolumeStorage open() => HiddenVolumeStorage(
      ({required password, required bool create}) => backing,
    );

    final storage = open();
    await storage.open(password: 'pw', createIfMissing: true);
    expect(await storage.retainHardeningWarning(), isNotNull);

    await expectLater(
      storage.acknowledgeHardeningWarning(),
      throwsA(isA<StateError>()),
      reason: 'the caller has to be able to tell that nothing was dismissed',
    );
    expect(
      await storage.retainHardeningWarning(),
      'padding: could not extend the file',
      reason:
          'the container still holds this record, so the person still has '
          'not been told anything they can act on',
    );

    // And it survives a restart, because the app copy was never cleared.
    backing.stagedHardeningWarning = null;
    final second = open();
    await second.open(password: 'pw', createIfMissing: false);
    expect(
      await second.retainHardeningWarning(),
      'padding: could not extend the file',
    );
  });

  test('a container with nothing to say records nothing', () async {
    final backing = FakeKvLogStore();
    final storage = HiddenVolumeStorage(
      ({required password, required bool create}) => backing,
    );
    await storage.open(password: 'pw', createIfMissing: true);
    expect(await storage.retainHardeningWarning(), isNull);
  });

  test('a container that REFUSES the acknowledgement keeps both copies', () async {
    // "I have shown this to the person" clears the app's copy and the
    // container's record. It must clear both or neither: the container's
    // record is the one that survives a restart, and the app's copy is the one
    // the screen reads, so a half-done acknowledgement leaves the warning
    // filed as dismissed and still true.
    //
    // The adapter under this used to log the refusal and return, so the
    // deletion below it ran every time.
    final backing = FakeKvLogStore()
      ..stagedHardeningWarning = 'sync: masking writes not on disk'
      ..hardeningAcknowledgeThrows = true;
    final storage = HiddenVolumeStorage(
      ({required password, required bool create}) => backing,
    );
    await storage.open(password: 'pw', createIfMissing: true);
    expect(await storage.retainHardeningWarning(), isNotNull);

    await expectLater(
      storage.acknowledgeHardeningWarning(),
      throwsA(anything),
      reason: 'a refusal that reads as success is the defect',
    );

    // Still there, on the side the person reads it from.
    backing.stagedHardeningWarning = null;
    expect(
      await storage.retainHardeningWarning(),
      'sync: masking writes not on disk',
      reason: 'the kept copy was erased for an acknowledgement that failed',
    );
  });

  test('and one that ACCEPTS it clears them', () async {
    // Vacuity guard: an acknowledgement that never clears anything satisfies
    // the test above and makes the warning permanent.
    final backing = FakeKvLogStore()
      ..stagedHardeningWarning = 'sync: masking writes not on disk';
    final storage = HiddenVolumeStorage(
      ({required password, required bool create}) => backing,
    );
    await storage.open(password: 'pw', createIfMissing: true);
    expect(await storage.retainHardeningWarning(), isNotNull);

    await storage.acknowledgeHardeningWarning();
    expect(backing.hardeningAcknowledgements, 1);

    backing.stagedHardeningWarning = null;
    expect(await storage.retainHardeningWarning(), isNull);
  });

  test('the native adapter does not swallow the refusal either', () {
    // Structural, and this is why: the layer that talks to the container is
    // `HvKvLogStore`, whose `_space` is a live FFI handle. A unit test cannot
    // reach it, so the test above exercises the ORDERING in the layer over it
    // with a fake — and the ordering is exactly what a swallow below defeats.
    // With the refusal caught and logged, `store.acknowledgeHardeningWarning()`
    // returns normally and the delete under it runs every time.
    //
    // The reader beside it stays best-effort on purpose: it feeds a readout
    // and may degrade to "unknown". This one changes the container.
    final source = File(
      'lib/data/storage/hv_kv_log_store.dart',
    ).readAsStringSync();
    final at = source.indexOf('void acknowledgeHardeningWarning() {');
    expect(at, isNot(-1), reason: 'the adapter moved');
    final body = source.substring(at, source.indexOf('\n  }', at));

    expect(
      body,
      isNot(contains('catch')),
      reason:
          'a refusal caught here reads as success one layer up, which erases '
          'the copy the person would have seen',
    );
    expect(
      body,
      contains('acknowledgeHardeningError()'),
      reason: 'it stopped acknowledging anything at all',
    );
  });
}
