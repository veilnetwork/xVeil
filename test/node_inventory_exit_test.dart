import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/managed_node.dart';
import 'package:xveil/data/node/node_lifecycle.dart';
import 'package:xveil/data/node/proxy_routing.dart';
import 'package:xveil/data/node/node_provisioner.dart';

/// The inventory is the ONLY read-only way to re-attach a server whose records
/// the app has lost — an identity restored from a phrase, with no second device
/// to replicate from. It reported the node id and nothing about the exit, so a
/// re-attached server could not be routed through, and the only way to find out
/// whether it was even an exit was to run a deployment over a working machine.
///
/// The reading is done by an awk program embedded in the generated script, so
/// these run the REAL awk against real config fixtures rather than trusting the
/// string to mean what it looks like. `veil-cli config get proxy.exit.enabled`
/// is not an option: a live node answers `unknown config key`.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('xveil-inv'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// The awk program exactly as the generated script carries it.
  String awkProgram() {
    final script = buildNodeInventoryScript();
    const open = "sudo awk '";
    final start = script.indexOf(open);
    expect(start, isNot(-1), reason: 'the inventory must still read the exit');
    final end = script.indexOf("' /var/lib/veil/node.toml", start);
    expect(end, isNot(-1));
    return script.substring(start + open.length, end);
  }

  String run(String toml) {
    final file = File('${dir.path}/node.toml')..writeAsStringSync(toml);
    final result = Process.runSync('awk', [awkProgram(), file.path]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return result.stdout as String;
  }

  test('an exit with an allowlist is reported in full', () {
    final out = run('''
[global]
log_level = "info"

[proxy.exit]
enabled = true
allow_private = false
allowed_node_ids = ["${'a' * 64}", "${'b' * 64}"]
allow_all = false

[metrics]
listen = "tcp://0.0.0.0:19999"
''');

    expect(out, contains('EXIT_ENABLED: true'));
    expect(out, contains('EXIT_ALLOW_ALL: false'));
    expect(out, contains('EXIT_ALLOWED: ${'a' * 64},${'b' * 64}'));
  });

  test('a node with no exit table says so instead of staying silent', () {
    final out = run('[global]\nlog_level = "info"\n');

    // Absent is reported as off. A caller that saw nothing could not tell
    // "not an exit" from "the inventory did not look".
    expect(out, contains('EXIT_ENABLED: false'));
    expect(out, contains('EXIT_ALLOW_ALL: false'));
    expect(out, contains('EXIT_ALLOWED: \n'));
  });

  test('keys from OTHER tables are not read as the exit’s', () {
    final out = run('''
[proxy.exit]
enabled = true
allowed_node_ids = ["${'c' * 64}"]

[proxy.socks5]
enabled = false
allow_all = true
''');

    expect(out, contains('EXIT_ENABLED: true'));
    // `allow_all` below belongs to socks5. Reading it as the exit's would
    // report an OPEN proxy on a node that admits exactly one id.
    expect(out, contains('EXIT_ALLOW_ALL: false'));
    expect(out, contains('EXIT_ALLOWED: ${'c' * 64}'));
  });

  test('a list broken across lines is refused, not half-read', () {
    final out = run('''
[proxy.exit]
enabled = true
allowed_node_ids = [
  "${'d' * 64}",
]
''');

    // "admits nobody" and "admits one" are both wrong answers from a partial
    // line, and the first one silently locks people out.
    expect(out, contains('EXIT_ALLOWED: (unread)'));
  });

  test('an open exit is reported as open', () {
    final out = run('[proxy.exit]\nenabled = true\nallow_all = true\n');

    expect(out, contains('EXIT_ALLOW_ALL: true'));
  });

  group('re-attaching a server whose records were lost', () {
    // Deployment registered an exit in the routing catalog; the read-only
    // inventory did not. An operator who restored an identity from a phrase
    // could re-attach the machine, watch its node id come back, and still have
    // nothing to route through — the only way into the catalog was to deploy
    // over a working server and overwrite its config.
    const serverId = 'ab12cd34';
    final fullId = serverId.padRight(64, '0');
    final node = ManagedNode(id: 'n1', label: 'vdsina2', sshHost: '10.0.0.1');
    final empty = ProxyRouting.disabled;

    String report({
      required bool exit,
      String allowed = '',
      String? id,
    }) =>
        'NODE_ID: ${id ?? fullId}\n'
        'EXIT_ENABLED: $exit\n'
        'EXIT_ALLOW_ALL: false\n'
        'EXIT_ALLOWED: $allowed\n';

    test('an inventoried exit joins the catalog under the node’s label', () {
      final updated = routingWithInventoriedExit(
        empty,
        node: node,
        inventoryOutput: report(exit: true),
      );

      expect(updated, isNotNull);
      expect(updated!.effectiveOproxies.single.nodeId, fullId);
      expect(updated.effectiveOproxies.single.label, 'vdsina2');
    });

    test('a server that is not an exit is not added', () {
      expect(
        routingWithInventoriedExit(
          empty,
          node: node,
          inventoryOutput: report(exit: false),
        ),
        isNull,
      );
    });

    test('an older script’s silence leaves the catalog alone', () {
      // Not "no exit": nobody looked. Treating silence as a negative would
      // drop a working exit out of the catalog on a re-attach.
      expect(
        routingWithInventoriedExit(
          empty,
          node: node,
          inventoryOutput: 'NODE_ID: $fullId\n',
        ),
        isNull,
      );
    });

    test('a node already in the catalog is not added twice', () {
      final once = routingWithInventoriedExit(
        empty,
        node: node,
        inventoryOutput: report(exit: true),
      )!;

      expect(
        routingWithInventoriedExit(
          once,
          node: node,
          inventoryOutput: report(exit: true),
        ),
        isNull,
      );
    });

    group('does this device still get out through it', () {
      test('yes when the allowlist names it', () {
        final me = 'cc'.padRight(64, 'c');
        expect(exitAdmitsSelf(report(exit: true, allowed: me), me), isTrue);
      });

      test('no when the allowlist names someone else — the restore case', () {
        // After a restore this device is NEW on the same identity, and the
        // list still names the device that is gone. Every stream is refused,
        // with nothing connecting the refusal to a file on a machine the
        // operator still owns.
        final me = 'cc'.padRight(64, 'c');
        final gone = 'dd'.padRight(64, 'd');
        expect(exitAdmitsSelf(report(exit: true, allowed: gone), me), isFalse);
      });

      test('an open exit admits anyone', () {
        expect(
          exitAdmitsSelf(
            'EXIT_ENABLED: true\nEXIT_ALLOW_ALL: true\nEXIT_ALLOWED: \n',
            'cc'.padRight(64, 'c'),
          ),
          isTrue,
        );
      });

      test('an unread list accuses nobody', () {
        expect(
          exitAdmitsSelf(
            'EXIT_ENABLED: true\nEXIT_ALLOWED: (unread)\n',
            'cc'.padRight(64, 'c'),
          ),
          isNull,
        );
      });

      test('a server that is not an exit has no answer to give', () {
        expect(
          exitAdmitsSelf(report(exit: false), 'cc'.padRight(64, 'c')),
          isNull,
        );
      });
    });
  });

  group('the report the app reads back', () {
    test('carries the exit state', () {
      final report = parseProvisionReport(
        'NODE_ID: ${'e' * 64}\n'
        'EXIT_ENABLED: true\n'
        'EXIT_ALLOW_ALL: false\n'
        'EXIT_ALLOWED: ${'a' * 64},${'b' * 64}\n',
      );

      expect(report.nodeId, 'e' * 64);
      expect(report.exitEnabled, isTrue);
      expect(report.exitAllowAll, isFalse);
      expect(report.exitAllowedNodeIds, ['a' * 64, 'b' * 64]);
    });

    test('an old script that reports nothing leaves it unknown', () {
      // Not `false`: a server inventoried by an older build has an exit state
      // nobody looked at, and calling that "no exit" would drop it out of the
      // catalog on a re-attach.
      final report = parseProvisionReport('NODE_ID: ${'e' * 64}\n');

      expect(report.exitEnabled, isNull);
      expect(report.exitAllowedNodeIds, isEmpty);
    });

    test('an unread list is not mistaken for an empty one', () {
      final report = parseProvisionReport(
        'EXIT_ENABLED: true\nEXIT_ALLOWED: (unread)\n',
      );

      expect(report.exitEnabled, isTrue);
      expect(report.exitAllowedNodeIds, isEmpty);
      expect(report.exitAllowlistUnread, isTrue);
    });
  });
}
