import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/exit_allowlist.dart';

/// Admitting a contact to your exit used to mean editing TOML on the server by
/// hand. This is the edit, as a function over the whole config, so the existing
/// transactional read/write pair can carry it there.
///
/// Everything below is about not damaging a file the operator owns: keys in
/// other tables, keys in this table nobody asked about, and the difference
/// between "no exit here" and "an exit that admits nobody".
void main() {
  final a = 'aa' * 32;
  final b = 'bb' * 32;
  final c = 'cc' * 32;

  const full = '''
[global]
log_level = "info"

[proxy.socks5]
enabled = true
allow_all = true

[proxy.exit]
enabled = true
allow_private = false
allowed_node_ids = ["OLD"]
allow_all = false

[metrics]
listen = "tcp://0.0.0.0:19999"
''';

  group('reading', () {
    test('an exit with a list is read back whole', () {
      final read = readExitAllowlist(
        full.replaceAll('"OLD"', '"$a", "$b"'),
      )!;

      expect(read.enabled, isTrue);
      expect(read.allowAll, isFalse);
      expect(read.allowedNodeIds, [a, b]);
      expect(read.admits(a), isTrue);
      expect(read.admits(c), isFalse);
    });

    test('no exit table at all is null, not "admits nobody"', () {
      // Different answers: one says this node has no exit, the other says it
      // has one that refuses everyone. Only the second is worth pointing at.
      expect(readExitAllowlist('[global]\nlog_level = "info"\n'), isNull);
    });

    test('an exit that admits nobody says so', () {
      final read = readExitAllowlist(
        '[proxy.exit]\nenabled = true\n',
      )!;

      expect(read.admitsNobody, isTrue);
    });

    test('an open exit admits anyone and is not "nobody"', () {
      final read = readExitAllowlist(
        '[proxy.exit]\nenabled = true\nallow_all = true\n',
      )!;

      expect(read.admitsNobody, isFalse);
      expect(read.admits(c), isTrue);
    });

    test('keys from another table are not read as the exit’s', () {
      // `[proxy.socks5]` above carries `allow_all = true`. Reading it as the
      // exit's would report an open proxy on a node that admits one id.
      final read = readExitAllowlist(full)!;
      expect(read.allowAll, isFalse);
    });
  });

  group('writing', () {
    test('the list is replaced and nothing else moves', () {
      final out = withExitAllowlist(full, allowedNodeIds: [a, b],
          allowAll: false);

      expect(readExitAllowlist(out)!.allowedNodeIds, [a, b]);
      // Everything the operator wrote is still there, in its own table.
      expect(out, contains('log_level = "info"'));
      expect(out, contains('allow_private = false'));
      expect(out, contains('listen = "tcp://0.0.0.0:19999"'));
      expect(out, contains('[proxy.socks5]'));
      // socks5's own allow_all is untouched.
      expect(readExitAllowlist(out)!.allowAll, isFalse);
      expect(out.contains('allow_all = true'), isTrue,
          reason: "socks5's line must survive");
    });

    test('the exit switch itself is never flipped by an admission change', () {
      // Adding someone to a list is not a decision to start serving traffic.
      expect(readExitAllowlist(
        withExitAllowlist(full, allowedNodeIds: [a], allowAll: false),
      )!.enabled, isTrue);
    });

    test('an absent exit table is created, and created OFF', () {
      final out = withExitAllowlist(
        '[global]\nlog_level = "info"\n',
        allowedNodeIds: [a],
        allowAll: false,
      );
      final read = readExitAllowlist(out)!;

      expect(read.allowedNodeIds, [a]);
      expect(read.enabled, isFalse,
          reason: 'writing a list is not asking to run an exit');
    });

    test('an id that is not 64 hex is dropped, not written', () {
      // veil drops it too when it parses the list, so writing it would put a
      // line in the operator's file that looks like an admission and is not.
      final out = withExitAllowlist(
        full,
        allowedNodeIds: ['nonsense', a, 'AA' * 31, ''],
        allowAll: false,
      );

      expect(readExitAllowlist(out)!.allowedNodeIds, [a]);
      expect(out, isNot(contains('nonsense')));
    });

    test('ids are lowercased and de-duplicated, order kept', () {
      final out = withExitAllowlist(
        full,
        allowedNodeIds: [b, ('AA' * 32), a, b],
        allowAll: false,
      );

      expect(readExitAllowlist(out)!.allowedNodeIds, [b, a]);
    });

    test('emptying the list is allowed and means nobody', () {
      final out = withExitAllowlist(full, allowedNodeIds: [], allowAll: false);

      expect(readExitAllowlist(out)!.allowedNodeIds, isEmpty);
      expect(readExitAllowlist(out)!.admitsNobody, isTrue);
    });

    test('opening the exit is written where a reader will find it', () {
      final out = withExitAllowlist(full, allowedNodeIds: [], allowAll: true);

      expect(readExitAllowlist(out)!.allowAll, isTrue);
      expect(readExitAllowlist(out)!.admitsNobody, isFalse);
    });

    test('a missing key is added INSIDE the exit table, not after it', () {
      // The exit table here has no `allow_all`; appending it after the next
      // header would silently set it on `[metrics]`.
      const noAllowAll = '''
[proxy.exit]
enabled = true

[metrics]
listen = "tcp://0.0.0.0:19999"
''';
      final out = withExitAllowlist(noAllowAll, allowedNodeIds: [a],
          allowAll: true);

      final exitBlock = out.substring(
        out.indexOf('[proxy.exit]'),
        out.indexOf('[metrics]'),
      );
      expect(exitBlock, contains('allow_all = true'));
      expect(exitBlock, contains('allowed_node_ids'));
    });

    test('writing twice changes nothing the second time', () {
      final once = withExitAllowlist(full, allowedNodeIds: [a, b],
          allowAll: false);
      final twice = withExitAllowlist(once, allowedNodeIds: [a, b],
          allowAll: false);

      expect(twice, once);
    });

    test('the exit table stays the LAST thing when it already is', () {
      const trailing = '[global]\nx = 1\n\n[proxy.exit]\nenabled = true\n';
      final out = withExitAllowlist(trailing, allowedNodeIds: [a],
          allowAll: false);

      expect(readExitAllowlist(out)!.allowedNodeIds, [a]);
      expect(readExitAllowlist(out)!.enabled, isTrue);
    });
  });
}
