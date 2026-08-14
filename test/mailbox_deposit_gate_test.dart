// When a message still needs a relay copy, and when it does not.
//
// Every send used to leave a copy in the mailbox, whether or not it had already
// arrived. That is a second delivery of something already on the recipient's
// disk: relay traffic, a sealed blob per device, and a drain that fetches what
// the peer has had for seconds.
//
// It is safe to skip because of WHEN the ack is sent. The inbound path stores
// the message and only then acks, so an ack is the recipient saying "it is on
// my disk" — not "the frame reached me". And a recipient's devices mirror a
// received message among themselves, deduplicating by message id, so reaching
// ONE device of an identity is reaching the identity.
//
// Call control is exempt on purpose: an offer's whole value is inside the ring
// window, and waiting out a grace period is the one thing it cannot afford —
// measured on the stand, an offer deposited 170 ms after the call had given up.

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/mailbox_deposit_gate.dart';

void main() {
  group('the acknowledgement ledger', () {
    test('remembers what the recipient confirmed storing', () {
      final d = MailboxDepositGate();
      expect(d.acknowledged('m1'), isFalse);
      d.noteAcknowledged('m1');
      expect(d.acknowledged('m1'), isTrue);
      expect(d.acknowledged('m2'), isFalse);
    });

    // It answers one question once, inside a grace window measured in seconds.
    // Unbounded, it would grow for the life of the process on a busy chat.
    test('stays bounded', () {
      final d = MailboxDepositGate();
      for (var i = 0; i < 1000; i++) {
        d.noteAcknowledged('m$i');
      }
      expect(d.size, lessThanOrEqualTo(MailboxDepositGate.cap));
      // The newest are the ones a pending deposit could still be waiting on.
      expect(d.acknowledged('m999'), isTrue);
    });
  });

  group('shouldDeposit', () {
    test('an unacknowledged message still needs the relay', () {
      expect(
        shouldDeposit(id: 'm1', acknowledged: false, isCallSignal: false),
        isTrue,
      );
    });

    // THE POINT. Already stored by the recipient — a relay copy is pure cost.
    test('an acknowledged message does not', () {
      expect(
        shouldDeposit(id: 'm1', acknowledged: true, isCallSignal: false),
        isFalse,
      );
    });

    // Call control never waits and never asks: being late is worse for it than
    // being duplicated.
    test('call control is deposited regardless', () {
      expect(
        shouldDeposit(id: 'call:1', acknowledged: true, isCallSignal: true),
        isTrue,
      );
      expect(
        shouldDeposit(id: 'gcall:1', acknowledged: false, isCallSignal: true),
        isTrue,
      );
    });
  });
}
