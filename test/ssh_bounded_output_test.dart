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

  test('a hang-up that throws does not take the result down', () {
    final sink = SshBoundedSink(() => throw StateError('close failed'));
    sink.add(chunk(kSshMaxStreamBytes + 1));
    expect(sink.truncated, isTrue);
    expect(sink.text().length, kSshMaxStreamBytes);
  });
}
