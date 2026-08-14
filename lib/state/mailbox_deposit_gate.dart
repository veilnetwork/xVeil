/// Whether a sent message still needs a copy left on a relay.
///
/// Every send used to leave one, whether or not it had already arrived — a
/// second delivery of something already on the recipient's disk, costing relay
/// traffic, a sealed blob per device of that recipient, and a drain that fetches
/// what the peer has had for seconds.
///
/// Skipping it is safe because of WHEN the ack is sent. The inbound path stores
/// the message and only then acks, so an ack is the recipient saying "it is on
/// my disk", not "the frame reached me". And a recipient's devices mirror a
/// received message among themselves, deduplicating by message id, so reaching
/// ONE device of an identity is reaching the identity.
///
/// Kept out of the messaging part-file so the decision can be tested on its
/// own: it is one boolean guarding the difference between a message that is
/// safe and a message nobody has.
library;

/// The ids a recipient has confirmed storing.
///
/// Bounded, and deliberately small: it answers one question, once, inside a
/// grace window measured in seconds. Unbounded it would grow for the life of
/// the process on a busy conversation.
class MailboxDepositGate {
  static const cap = 512;

  final _acked = <String>{};

  int get size => _acked.length;

  void noteAcknowledged(String id) {
    if (_acked.length >= cap) _acked.remove(_acked.first);
    _acked.add(id);
  }

  bool acknowledged(String id) => _acked.contains(id);
}

/// Call lifecycle control — an offer, answer or cancel whose only value is
/// inside the ring window.
bool isCallSignalId(String id) =>
    id.startsWith('call:') || id.startsWith('gcall:');

/// The decision itself.
///
/// Call control is exempt and always deposited: being late is worse for it than
/// being duplicated. Measured on the stand, an offer that waited was deposited
/// 170 ms after the call had already given up, so the callee rang for a call
/// that no longer existed.
bool shouldDeposit({
  required String id,
  required bool acknowledged,
  required bool isCallSignal,
}) {
  if (isCallSignal) return true;
  return !acknowledged;
}
