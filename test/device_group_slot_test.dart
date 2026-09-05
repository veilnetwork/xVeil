import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/state/cloud_capability_service.dart'
    show cloudProviderSlotFor, kCloudProviderSlotLimit;
import 'package:xveil/state/device_group_reader.dart';

import 'support/fake_setting_storage.dart';

/// Two devices of one identity must not register as one provider.
///
/// Every device of an identity derives the SAME member host seed and alias —
/// both come from the document id and the epoch key — so the slot is the only
/// thing that tells two of them apart. It was a constant 0 for every identity
/// but the active one, because the device list could only be read through that
/// identity's live GroupService (report20 XV20-M9).
void main() {
  NodeId id(int n) => NodeId.fromHex(n.toRadixString(16).padLeft(2, '0') * 32);

  group('the slot is an index among this identity own devices', () {
    test('a lone device is the only one, and takes the first slot', () {
      expect(cloudProviderSlotFor(id(1), const []), 0);
    });

    test('two devices never share a slot, whichever asks', () {
      final a = id(1), b = id(2);
      final slotA = cloudProviderSlotFor(a, [b]);
      final slotB = cloudProviderSlotFor(b, [a]);
      expect(
        slotA,
        isNot(slotB),
        reason:
            'both devices registered as the same provider — the folder is then '
            'unreachable from one of them',
      );
    });

    test('both devices agree on the whole assignment', () {
      // Not merely different: the SAME index for the same device, whoever is
      // asking. They compute it independently and never compare notes.
      final devices = [id(1), id(2), id(3)];
      for (final self in devices) {
        final others = [
          for (final d in devices)
            if (d != self) d,
        ];
        expect(
          cloudProviderSlotFor(self, others),
          cloudProviderSlotFor(self, devices),
          reason: 'the slot depends on who is asking, not on the device set',
        );
      }
    });

    test('past the limit it fails closed rather than colliding', () {
      final many = [for (var i = 1; i <= kCloudProviderSlotLimit + 1; i++) id(i)];
      expect(
        () => cloudProviderSlotFor(id(200), many),
        throwsStateError,
        reason:
            'beyond the limit two registrations could not be told apart, and '
            'silently colliding is the failure this guards',
      );
    });
  });

  group('a device list nobody can read is not a slot of zero', () {
    test('the service leaves hosting alone rather than guessing', () {
      // The skip is a `continue` deep inside member hosting, which needs a
      // live onion network to reach behaviourally. What must not come back is
      // a substituted slot: `?? 0` there is exactly the collision this change
      // removes, and it is one character to reintroduce.
      final src = File(
        'lib/state/cloud_document_replication_service.dart',
      ).readAsStringSync();
      expect(
        src,
        contains('if (providerSlot == null) continue;'),
        reason: 'an unknown slot no longer skips hosting',
      );
      expect(
        src,
        isNot(contains('providerSlot ?? 0')),
        reason: 'an unknown slot is being substituted with the first one',
      );
      expect(
        src,
        isNot(contains('memberProviderSlot?.call() ?? Future.value(0)')),
        reason: 'the old "unknown means zero" resolver call is back',
      );
    });

    test('no node config means unknown, not the first slot', () async {
      // Unknown has to stay unknown all the way up: a device that guesses 0
      // collides with the sibling that legitimately holds it, and the folder
      // becomes unreachable from one of them.
      final storage = FakeSettingStorage();
      expect(await deviceMembersOf(storage: storage, selfId: id(1)), isNull);
    });
  });
}
