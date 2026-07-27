import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/network/network_screen.dart';

void main() {
  group('what a node failure is allowed to say on screen', () {
    // The node's message is a raw native error, shown in a snackbar. Two
    // things have to be true at once and they pull against each other: a
    // person hitting a firewall needs to see WHY, and a snackbar is visible to
    // whoever is standing there and ends up in photographs.

    test('the cause survives — otherwise the notice is useless', () {
      for (final (raw, keep) in [
        ('io error: address already in use', 'address already in use'),
        ('obfs4-tcp transport requires obfs4_psk', 'obfs4_psk'),
        ('spawn failed: No such file or directory', 'No such file'),
        ('dns resolution failed', 'dns resolution failed'),
      ]) {
        expect(nodeFailureDetail(raw), contains(keep), reason: raw);
      }
    });

    test('a store path does not', () {
      final out = nodeFailureDetail(
        'io error opening /Users/someone/Library/Application Support/x.store',
      );
      expect(out, isNot(contains('/Users/')));
      expect(out, isNot(contains('someone')));
      expect(out, contains('io error'), reason: 'the cause still shows');
    });

    test('a node id does not', () {
      final out = nodeFailureDetail(
        'no route to 7084a345b55ef17031b793b96a9edca2cb1836151490c3a67d1ceab906f2a8a2',
      );
      expect(out, isNot(contains('7084a345')));
      expect(out, contains('no route to'));
    });

    test('nothing at all produces nothing at all', () {
      // A snackbar reading "Offline\n" with a blank second line looks broken.
      expect(nodeFailureDetail(null), isEmpty);
      expect(nodeFailureDetail(''), isEmpty);
      expect(nodeFailureDetail('   '), isEmpty);
    });

    test('a long error is capped — a snackbar is not a log viewer', () {
      final out = nodeFailureDetail(List.filled(200, 'why').join(' '));
      expect(out.length, lessThan(200));
    });
  });
}
