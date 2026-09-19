import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/call_signal.dart';

/// The wire encodes a signal's TYPE as its enum index (`'k': type.index`), so
/// the position of every encodable value is protocol, not source order.
///
/// Appending above `unknown` is safe and is what the enum's own comment asks
/// for: an older peer decodes the new index as its own `unknown` and ignores
/// it. INSERTING one, anywhere earlier, silently renumbers everything after it
/// — an older peer would then read a newer peer's `end` as `renegotiate`, with
/// no error anywhere. Nothing else in the tree would notice.
void main() {
  test('every encodable signal type keeps its wire index', () {
    // Pinned 2026-09-20 when askVideoOff was appended. Add new entries at the
    // END of this map only; changing an existing number is a wire break and
    // needs both sides shipped together.
    const pinned = <CallSignalType, int>{
      CallSignalType.offer: 0,
      CallSignalType.answer: 1,
      CallSignalType.reject: 2,
      CallSignalType.cancel: 3,
      CallSignalType.busy: 4,
      CallSignalType.end: 5,
      CallSignalType.renegotiate: 6,
      CallSignalType.transportInfo: 7,
      CallSignalType.health: 8,
      CallSignalType.askVideoOff: 9,
    };
    pinned.forEach((type, index) {
      expect(type.index, index, reason: '${type.name} moved on the wire');
    });
    // …and the decode-only sentinel stays last, so a FUTURE peer's additions
    // land on it rather than on a real type.
    expect(
      CallSignalType.unknown.index,
      CallSignalType.values.length - 1,
      reason: 'unknown must remain last for forward compatibility',
    );
    expect(
      CallSignalType.values.length,
      pinned.length + 1,
      reason: 'a type was added without pinning its index here',
    );
  });

  test('askVideoOff survives a round trip', () {
    final sig = CallSignal(
      callId: 'c1',
      type: CallSignalType.askVideoOff,
      protocolVersion: kCallSignalProtocolVersion,
    );
    final back = CallSignal.tryDecode(sig.encode())!;
    expect(back.type, CallSignalType.askVideoOff);
    expect(back.callId, 'c1');
  });

  test('a peer that predates askVideoOff reads it as unknown', () {
    // What an older build does with index 9: its own `unknown` sat there, and
    // its dispatch does nothing for `unknown`. That is the whole compatibility
    // argument, stated as a test rather than as a comment.
    final older = <String>['offer', 'answer', 'reject', 'cancel', 'busy',
        'end', 'renegotiate', 'transportInfo', 'health', 'unknown'];
    expect(older.length, 10);
    expect(older[CallSignalType.askVideoOff.index], 'unknown');
  });
}
