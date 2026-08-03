import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/ssh_client.dart';

/// The host key is pinned, but a pin says the box is the one we saw before —
/// not that it is still honest. `sshRun` used to `fold` stdout and stderr with
/// no ceiling, so a compromised box could stream for the whole 30-second
/// timeout and land all of it in the app's heap (audit XV-17).
void main() {
  List<int> chunk(int n) => List<int>.filled(n, 0x41);

  test('output past the cap is dropped and the session is hung up', () {
    var hungUp = 0;
    final sink = SshBoundedSink(() => hungUp++);

    // Well under the cap: kept whole, connection untouched.
    sink.add(chunk(1024));
    expect(sink.truncated, isFalse);
    expect(hungUp, 0);

    // Past it: the excess is dropped AND the peer is hung up, so it cannot
    // keep the connection busy being read and discarded.
    sink.add(chunk(kSshMaxStreamBytes));
    expect(sink.truncated, isTrue);
    expect(hungUp, 1, reason: 'dropping bytes while still reading is not a cap');
    expect(sink.text().length, kSshMaxStreamBytes);

    // Anything after is ignored without hanging up again.
    sink.add(chunk(4096));
    expect(hungUp, 1);
    expect(sink.text().length, 0, reason: 'text() drains the buffer once');
  });

  test('output that lands exactly on the cap is whole, not truncated', () {
    // Audit X-18. The comparison was `<`, so a chunk that filled the buffer to
    // the byte was treated as an overflow: nothing was lost (`sublist(0, room)`
    // takes all of it), but `truncated` went up and the session was hung up.
    // A command whose output happened to be exactly this size was reported as
    // a server flooding us, and its complete result was labelled partial.
    var hungUp = 0;
    final sink = SshBoundedSink(() => hungUp++);

    sink.add(chunk(kSshMaxStreamBytes));
    expect(sink.truncated, isFalse, reason: 'exactly the cap is within it');
    expect(hungUp, 0, reason: 'and an honest server must not be hung up on');
    expect(sink.text().length, kSshMaxStreamBytes);
  });

  test('one byte past the cap is truncated and hung up', () {
    // The other side of the same boundary, in its own sink so it cannot be
    // satisfied by state the case above left behind. Without this, widening
    // the comparison to `<=` could be widened to "always accept" and nothing
    // would notice.
    var hungUp = 0;
    final sink = SshBoundedSink(() => hungUp++);

    sink.add(chunk(kSshMaxStreamBytes + 1));
    expect(sink.truncated, isTrue);
    expect(hungUp, 1);
    expect(sink.text().length, kSshMaxStreamBytes);
  });

  test('a buffer filled to the cap still refuses the next byte', () {
    // Reaching the cap exactly must not leave the sink permanently willing:
    // once there is no room, the very next byte is the overflow. `<=` with a
    // room of zero says yes to an EMPTY chunk and no to anything else, which
    // is the behaviour wanted — an empty write is not an overflow.
    var hungUp = 0;
    final sink = SshBoundedSink(() => hungUp++);

    sink.add(chunk(kSshMaxStreamBytes));
    expect(sink.truncated, isFalse);

    sink.add(const <int>[]);
    expect(sink.truncated, isFalse, reason: 'an empty write is not an overflow');
    expect(hungUp, 0);

    sink.add(chunk(1));
    expect(sink.truncated, isTrue, reason: 'a full buffer has no room left');
    expect(hungUp, 1);
    expect(sink.text().length, kSshMaxStreamBytes);
  });

  test('a hang-up that throws does not take the result down', () {
    final sink = SshBoundedSink(() => throw StateError('close failed'));
    sink.add(chunk(kSshMaxStreamBytes + 1));
    expect(sink.truncated, isTrue);
    expect(sink.text().length, kSshMaxStreamBytes);
  });
}
