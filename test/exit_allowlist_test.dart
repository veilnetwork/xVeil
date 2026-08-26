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
  /// The editor's answer, asserted to BE an answer.
  ///
  /// It returns null for a document whose shape it cannot rewrite safely, and
  /// every document below is one it understands — so a null here would mean
  /// the refusal fired on something it should have edited.
  String edit(
    String toml, {
    required List<String> allowedNodeIds,
    required bool allowAll,
  }) {
    final out = withExitAllowlist(
      toml,
      allowedNodeIds: allowedNodeIds,
      allowAll: allowAll,
    );
    expect(out, isNotNull, reason: 'refused a document it understands');
    return out!;
  }

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
      final out = edit(full, allowedNodeIds: [a, b],
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
        edit(full, allowedNodeIds: [a], allowAll: false),
      )!.enabled, isTrue);
    });

    test('an absent exit table is created, and created OFF', () {
      final out = edit(
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
      final out = edit(
        full,
        allowedNodeIds: ['nonsense', a, 'AA' * 31, ''],
        allowAll: false,
      );

      expect(readExitAllowlist(out)!.allowedNodeIds, [a]);
      expect(out, isNot(contains('nonsense')));
    });

    test('ids are lowercased and de-duplicated, order kept', () {
      final out = edit(
        full,
        allowedNodeIds: [b, ('AA' * 32), a, b],
        allowAll: false,
      );

      expect(readExitAllowlist(out)!.allowedNodeIds, [b, a]);
    });

    test('emptying the list is allowed and means nobody', () {
      final out = edit(full, allowedNodeIds: [], allowAll: false);

      expect(readExitAllowlist(out)!.allowedNodeIds, isEmpty);
      expect(readExitAllowlist(out)!.admitsNobody, isTrue);
    });

    test('opening the exit is written where a reader will find it', () {
      final out = edit(full, allowedNodeIds: [], allowAll: true);

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
      final out = edit(noAllowAll, allowedNodeIds: [a],
          allowAll: true);

      final exitBlock = out.substring(
        out.indexOf('[proxy.exit]'),
        out.indexOf('[metrics]'),
      );
      expect(exitBlock, contains('allow_all = true'));
      expect(exitBlock, contains('allowed_node_ids'));
    });

    test('writing twice changes nothing the second time', () {
      final once = edit(full, allowedNodeIds: [a, b],
          allowAll: false);
      final twice = edit(once, allowedNodeIds: [a, b],
          allowAll: false);

      expect(twice, once);
    });

    test('the exit table stays the LAST thing when it already is', () {
      const trailing = '[global]\nx = 1\n\n[proxy.exit]\nenabled = true\n';
      final out = edit(trailing, allowedNodeIds: [a],
          allowAll: false);

      expect(readExitAllowlist(out)!.allowedNodeIds, [a]);
      expect(readExitAllowlist(out)!.enabled, isTrue);
    });
  });

  group('documents this editor must not guess at', () {
    test('a header with a trailing comment ends the exit table', () {
      // `[transport] # notes` is valid TOML and did not match the header
      // pattern, so the reader stayed inside [proxy.exit] and read the NEXT
      // table's keys as the exit's own — an `allow_all = true` belonging to
      // something else read as an exit open to everybody.
      final read = readExitAllowlist('''
[proxy.exit]
enabled = true
allow_all = false

[transport] # notes
allow_all = true
''');

      expect(read!.allowAll, isFalse, reason: 'read another table as the exit');
      expect(read.unreadable, isFalse);
    });

    test('an array broken across lines is reported unread, not as empty', () {
      // The value on the key line is just `[`, which parses as an empty list —
      // and veil reads an empty list as ADMITS NOBODY. Saying that about a
      // server which admits people is a lie in the direction that locks users
      // out.
      final read = readExitAllowlist('''
[proxy.exit]
enabled = true
allowed_node_ids = [
  "$a",
]
''');

      expect(read!.unreadable, isTrue);
      expect(read.admitsNobody, isFalse, reason: 'claimed nobody may exit');
    });

    test('and rewriting it is REFUSED rather than attempted', () {
      // It used to write the new single-line array and leave the old
      // continuation lines under it. That is not valid TOML, so the node would
      // not have come back after the operator applied an admission change.
      final out = withExitAllowlist('''
[proxy.exit]
enabled = true
allowed_node_ids = [
  "$a",
]
''', allowedNodeIds: [b], allowAll: false);

      expect(out, isNull);
    });

    test('the table twice is unread: two answers is not one', () {
      final read = readExitAllowlist('''
[proxy.exit]
allow_all = true

[transport]
kind = "obfs4"

[proxy.exit]
allow_all = false
''');

      expect(read!.unreadable, isTrue);
      expect(
        withExitAllowlist(
          '''
[proxy.exit]
allow_all = true

[proxy.exit]
allow_all = false
''',
          allowedNodeIds: const [],
          allowAll: true,
        ),
        isNull,
      );
    });
  });
}
