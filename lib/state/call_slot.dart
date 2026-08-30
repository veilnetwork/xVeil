import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The device owns exactly one microphone/camera call stack at a time.
///
/// Direct and group calls have independent signaling state machines, so the
/// exclusion lives one layer above both of them. Acquisition is synchronous:
/// two simultaneous inbound offers cannot both ring and later race for native
/// media resources.
enum CallSlotOwner { direct, group }

/// One claim on the slot, and the only thing that can give it up.
///
/// The slot used to hold a bare [CallSlotOwner], and `release` compared that
/// enum — so a claim was indistinguishable from any other claim of the same
/// KIND. Two teardowns of one old direct call were enough: the first released,
/// a new direct call acquired, and the second — arriving late, holding nothing
/// but the word `direct` — cleared the new call's lease. The slot then read as
/// free while a call was running on it, and a group call could take it and
/// start a second microphone and camera stack on the same physical devices
/// (report19 XV19-H4).
///
/// A lease is identity, not kind. `release` acts only on the exact one it is
/// given, so a stale holder releases nothing.
class CallSlotLease {
  const CallSlotLease._(this.owner, this._serial);

  /// Which state machine holds it. For diagnostics and [CallSlot.owner]; it is
  /// deliberately NOT what release compares.
  final CallSlotOwner owner;

  final int _serial;

  @override
  String toString() => 'CallSlotLease(${owner.name}#$_serial)';
}

class CallSlot {
  CallSlotLease? _lease;
  int _issued = 0;

  CallSlotOwner? get owner => _lease?.owner;

  /// The lease, or null when the slot is taken.
  ///
  /// Not re-entrant, even for the same FSM: after a call ends the slot stays
  /// occupied until native teardown completes. Letting a second same-kind call
  /// through would allow the first teardown to release its successor's
  /// microphone/camera lease — which is the same failure the lease exists to
  /// make impossible, one step earlier.
  CallSlotLease? acquire(CallSlotOwner owner) {
    if (_lease != null) return null;
    final lease = CallSlotLease._(owner, ++_issued);
    _lease = lease;
    return lease;
  }

  /// Give up [lease], if it is still the one that holds the slot.
  ///
  /// Null and stale leases are no-ops on purpose: teardown paths run more than
  /// once and from more than one direction, and the safe answer to "release
  /// something I may no longer hold" is to do nothing.
  void release(CallSlotLease? lease) {
    if (lease != null && identical(_lease, lease)) _lease = null;
  }

  bool occupiedByOther(CallSlotOwner owner) =>
      _lease != null && _lease!.owner != owner;
}

final callSlotProvider = Provider<CallSlot>((_) => CallSlot());
