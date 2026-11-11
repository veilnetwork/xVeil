import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_connect.dart';
import 'package:xveil/data/node/node_lifecycle.dart';

/// Owned Linux helper only. Never point at a production server: this exercises
/// shell execution. The invite file is private and must not enter Git/logs.
void main() {
  final inviteFile = Platform.environment['XVEIL_NODE_CONNECT_QA_INVITE'];
  test(
    'real pinned TLS claim, inventory, commands, bounded output and identity guard',
    () async {
      HttpOverrides.global = null;
      final invite = NodeConnectInvite.parse(
        await File(inviteFile!).readAsString(),
      );
      final wrong = NodeConnectClient(endpoint: invite.endpoint, pin: '0' * 64);
      try {
        await expectLater(
          wrong.claim(invite),
          throwsA(
            isA<NodeConnectException>().having(
              (error) => error.failure,
              'failure',
              NodeConnectFailure.certificate,
            ),
          ),
        );
      } finally {
        wrong.close();
      }
      var current = true;
      final client = NodeConnectClient(
        endpoint: invite.endpoint,
        pin: invite.pin,
        isCurrent: () => current,
      );
      addTearDown(client.close);
      // If the wrong-pin attempt leaked the bootstrap token and claimed the
      // helper, this independent claimant would now be rejected.
      final session = await client.claim(invite);
      expect((await client.info(session))['host_os'], 'linux');
      final inventory = await client.run(session, buildNodeInventoryScript());
      expect(inventory.ok, isTrue);
      expect(inventory.stdout, contains('BINARY_veil-cli: missing'));
      final output = await client.run(
        session,
        "printf 'owned QA'; printf 'stderr QA' >&2; exit 7",
      );
      expect(output.stdout, 'owned QA');
      expect(output.stderr, 'stderr QA');
      expect(output.exitCode, 7);
      final cap = await client.run(session, 'head -c 1100000 /dev/zero');
      expect(cap.truncated, isTrue);
      expect(cap.stdout.length, 1024 * 1024);
      current = false;
      await expectLater(
        client.run(session, 'exit 0'),
        throwsA(
          isA<NodeConnectException>().having(
            (error) => error.failure,
            'failure',
            NodeConnectFailure.identityChanged,
          ),
        ),
      );
    },
    skip: inviteFile == null
        ? 'Requires an explicitly started disposable Linux helper'
        : false,
  );
}
