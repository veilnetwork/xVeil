import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The device owns exactly one microphone/camera call stack at a time.
///
/// Direct and group calls have independent signaling state machines, so the
/// exclusion lives one layer above both of them. Acquisition is synchronous:
/// two simultaneous inbound offers cannot both ring and later race for native
/// media resources.
enum CallSlotOwner { direct, group }

class CallSlot {
  CallSlotOwner? _owner;

  CallSlotOwner? get owner => _owner;

  bool acquire(CallSlotOwner owner) {
    // Not re-entrant, even for the same FSM: after a call ends the slot stays
    // occupied until native teardown completes. Letting a second same-kind
    // call through would allow the first teardown to release its successor's
    // microphone/camera lease.
    if (_owner != null) return false;
    _owner = owner;
    return true;
  }

  void release(CallSlotOwner owner) {
    if (_owner == owner) _owner = null;
  }

  bool occupiedByOther(CallSlotOwner owner) =>
      _owner != null && _owner != owner;
}

final callSlotProvider = Provider<CallSlot>((_) => CallSlot());
