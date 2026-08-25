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
}
