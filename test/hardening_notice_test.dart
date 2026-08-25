import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/settings/hardening_sync_notice.dart';

/// Three hardening steps can fail after a commit and only one of them leaves
/// anything to do. `padding` and `churn` describe a commit already past —
/// nothing anyone does now un-leaks it — so they wait on the storage screen.
/// `sync` says the masking writes have not reached the platter YET, and "do
/// not pull the power" is a real answer, so that one interrupts.
///
/// A notice the reader cannot act on teaches them to dismiss notices, which is
/// the failure this split exists to avoid.
void main() {
  test('only the sync step is worth interrupting for', () {
    expect(
      hardeningWarningIsUrgent('sync: fsync failed on the container'),
      isTrue,
    );
    expect(
      hardeningWarningIsUrgent('padding: could not extend the file'),
      isFalse,
      reason: 'that commit is past; the next one re-pads and this one cannot '
          'be un-leaked',
    );
    expect(
      hardeningWarningIsUrgent('churn: no decoy moved beside the reuse'),
      isFalse,
    );
    expect(hardeningWarningIsUrgent(null), isFalse);
    expect(
      hardeningWarningIsUrgent(''),
      isFalse,
      reason: 'an empty record is an acknowledged one, not an urgent one',
    );
  });
}
