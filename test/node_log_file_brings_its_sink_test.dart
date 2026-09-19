import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';

void main() {
  test('a node log file always brings its sink with it', () {
    const toml = '[global]\npersist_enabled = true\n';
    final out = EmbeddedNode.withLogFile(toml, '/tmp/veil-node.log');
    expect(out, contains('log_file = "/tmp/veil-node.log"'));
    expect(out, contains('logs = "file"'),
        reason: 'log_file with logs=stderr is what the node rejects outright');
  });

  test('an already-rendered stderr sink is replaced, not duplicated', () {
    const toml = '[global]\nlogs = "stderr"\n';
    final out = EmbeddedNode.withLogFile(toml, '/tmp/a.log');
    expect('logs = '.allMatches(out).length, 1, reason: 'one sink, not two');
    expect(out, isNot(contains('"stderr"')));
  });

  test('no path means no change at all', () {
    const toml = '[global]\nlogs = "stderr"\n';
    expect(EmbeddedNode.withLogFile(toml, null), toml);
    expect(EmbeddedNode.withLogFile(toml, ''), toml);
  });
}
