import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';

void main() {
  test('embedded client role is explicitly leaf', () {
    const base =
        '[Identity]\n'
        'public_key = "pk"\n'
        '\n'
        '[global]\n'
        'runtime_flavor = "multi_thread"\n';

    final out = EmbeddedNode.withClientNodeRole(base);

    expect(out, contains('[Identity]\nrole = "leaf"\npublic_key = "pk"'));
    expect(out.indexOf('role = "leaf"'), lessThan(out.indexOf('[global]')));
  });

  test('embedded client role replaces a stale explicit core role', () {
    const base =
        '[identity]\n'
        'public_key = "pk"\n'
        'role = "core"\n'
        'private_key = "sk"\n';

    final out = EmbeddedNode.withClientNodeRole(base);

    expect(out, isNot(contains('role = "core"')));
    expect(
      RegExp(r'^role = "leaf"$', multiLine: true).allMatches(out),
      hasLength(1),
    );
  });

  test('role helper leaves non-identity input for native validation', () {
    const base = '[global]\nruntime_flavor = "multi_thread"\n';

    expect(EmbeddedNode.withClientNodeRole(base), base);
  });
}
