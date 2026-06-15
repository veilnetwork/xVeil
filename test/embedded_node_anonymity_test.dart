import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';

void main() {
  const base = '[[listen]]\nid = "0x00000001"\ntransport = "tcp://127.0.0.1:9000"\n';

  test('withAnonymity(false) leaves the config unchanged', () {
    expect(EmbeddedNode.withAnonymity(base, false), base);
  });

  test('withAnonymity(true) appends a location-anonymous [anonymity] table', () {
    final out = EmbeddedNode.withAnonymity(base, true);
    expect(out, startsWith(base));
    expect(out, contains('[anonymity]'));
    expect(out, contains('onion_service = true'));
    expect(out, contains('receive_anonymous = true'));
  });

  test('withAnonymity is idempotent — never adds a second [anonymity] table',
      () {
    final once = EmbeddedNode.withAnonymity(base, true);
    final twice = EmbeddedNode.withAnonymity(once, true);
    expect(twice, once);
    expect('[anonymity]'.allMatches(twice).length, 1);
  });
}
