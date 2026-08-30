import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_slot.dart';

/// The device has one microphone and one camera, and the slot is what says so.
void main() {
  test('a stale release does not take the successor\'s lease', () {
    // The slot used to hold a bare owner enum, so a claim was
    // indistinguishable from any other claim of the same KIND. Two teardowns
    // of one old direct call were enough: the first released, a new direct
    // call acquired, and the second — arriving late, holding nothing but the
    // word `direct` — cleared the NEW call's lease. The slot then read as free
    // while a call was running on it (report19 XV19-H4).
    final slot = CallSlot();

    final first = slot.acquire(CallSlotOwner.direct);
    expect(first, isNotNull, reason: 'premise: the first call takes the slot');
    slot.release(first);

    final second = slot.acquire(CallSlotOwner.direct);
    expect(second, isNotNull, reason: 'premise: a new call takes it after');

    // The old call's OTHER teardown path, arriving now. Teardown runs from
    // more than one direction — `_end` and `dispose` both reach it — so this
    // is ordinary, not exotic.
    slot.release(first);

    expect(
      slot.owner,
      CallSlotOwner.direct,
      reason: "a stale release freed the running call's slot",
    );
    expect(
      slot.acquire(CallSlotOwner.group),
      isNull,
      reason:
          'a group call took the slot from a live direct call — two media '
          'stacks on one microphone',
    );

    slot.release(second);
    expect(slot.owner, isNull, reason: 'the live call could not give it up');
  });

  test('a lease is not transferable between kinds', () {
    final slot = CallSlot();
    final direct = slot.acquire(CallSlotOwner.direct);
    expect(direct, isNotNull);
    expect(slot.acquire(CallSlotOwner.group), isNull);
    expect(slot.occupiedByOther(CallSlotOwner.group), isTrue);
    expect(slot.occupiedByOther(CallSlotOwner.direct), isFalse);
    slot.release(direct);
    expect(slot.acquire(CallSlotOwner.group), isNotNull);
  });

  test('releasing nothing is a no-op, not a free', () {
    // Teardown paths call this without knowing whether they still hold it.
    final slot = CallSlot();
    final held = slot.acquire(CallSlotOwner.direct);
    slot.release(null);
    expect(slot.owner, CallSlotOwner.direct, reason: 'null released the slot');
    slot.release(held);
    expect(slot.owner, isNull);
  });
}
