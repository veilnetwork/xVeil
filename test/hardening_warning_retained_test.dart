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

  test('a container with nothing to say records nothing', () async {
    final backing = FakeKvLogStore();
    final storage = HiddenVolumeStorage(
      ({required password, required bool create}) => backing,
    );
    await storage.open(password: 'pw', createIfMissing: true);
    expect(await storage.retainHardeningWarning(), isNull);
  });
}
