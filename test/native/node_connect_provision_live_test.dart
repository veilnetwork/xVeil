import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_connect.dart';
import 'package:xveil/data/node/node_lifecycle.dart';
import 'package:xveil/data/node/node_provisioner.dart';

/// Explicitly owned, disposable Linux/systemd server only. Installation runs
/// as root and changes services. Never supply a production server invitation.
void main() {
  final env = Platform.environment;
  final inviteFile = env['XVEIL_NODE_CONNECT_SYSTEMD_QA_INVITE'];
  final proofDir = env['XVEIL_NODE_CONNECT_SYSTEMD_QA_PROOF'];
  final existing = env['XVEIL_NODE_CONNECT_SYSTEMD_QA_MODE'] == 'existing';
  test(
    'pinned helper provisions and rediscovers a real systemd node',
    () async {
      HttpOverrides.global = null;
      final invite = NodeConnectInvite.parse(
        await File(inviteFile!).readAsString(),
      );
      final client = NodeConnectClient(
        endpoint: invite.endpoint,
        pin: invite.pin,
      );
      addTearDown(client.close);
      final session = await client.claim(invite);
      final info = await client.info(session);
      expect(info['administrator'], isTrue);
      expect(info['host_os'], 'linux');
      expect(info['config_present'], existing);
      final guard = await client.run(
        session,
        'test -f /xveil-disposable-node-connect-qa && '
        'command -v curl && command -v flock && '
        'test -d /run/systemd/system',
      );
      expect(guard.ok, isTrue);

      Future<String> inventory() async {
        final result = await client.run(session, buildNodeInventoryScript());
        expect(result.ok && !result.truncated, isTrue);
        return result.stdout;
      }

      final before = await inventory();
      if (existing) {
        final report = parseProvisionReport(before, reachableHost: '127.0.0.1');
        expect(report.nodeId, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(report.invite, isNotNull);
        expect(before, contains('UNIT_veil.service_ACTIVE: active'));
        await File(
          '$proofDir/existing-proof.json',
        ).writeAsString(jsonEncode({'newHelperRediscoversActiveNode': true}));
        return;
      }
      expect(before, contains('BINARY_veil-cli: missing'));
      final sha = env['XVEIL_NODE_CONNECT_SYSTEMD_QA_SHA256']!;
      final tag = env['XVEIL_NODE_CONNECT_SYSTEMD_QA_TAG']!;
      expect(tag, matches(RegExp(r'^v[0-9]+\.[0-9]+\.[0-9]+$')));
      final config = NodeProvisionConfig(
        releaseUrl:
            'https://github.com/veilnetwork/veil/releases/download/'
            '$tag/veil-cli-aarch64-unknown-linux-musl',
        expectedSha256: sha,
        obfs4PskB64: base64Encode(List<int>.filled(32, 42)),
        runExit: false,
        advertiseHost: 'node.example.org',
      );
      String? nodeId;
      for (var pass = 1; pass <= 2; pass++) {
        final result = await client.run(
          session,
          'test -f /xveil-disposable-node-connect-qa || exit 1\n'
          '${buildProvisionScript(config)}',
          timeout: const Duration(minutes: 6),
        );
        // Raw node IDs and bootstrap addresses stay in the explicitly supplied
        // private evidence directory, never in assertions or repository data.
        await File(
          '$proofDir/provision-$pass-private.log',
        ).writeAsString('${result.stdout}\n${result.stderr}');
        expect(
          result.ok && !result.truncated,
          isTrue,
          reason: 'See private stand evidence for installation failure',
        );
        final report = parseProvisionReport(
          result.stdout,
          reachableHost: '127.0.0.1',
        );
        expect(report.nodeId != null && report.nodeId!.length == 64, isTrue);
        expect(report.invite != null, isTrue);
        if (pass == 1) {
          nodeId = report.nodeId;
        } else {
          expect(
            report.nodeId == nodeId,
            isTrue,
            reason: 'Redeployment changed the node identity',
          );
        }
      }
      final after = await inventory();
      expect(after, contains('UNIT_veil.service_ACTIVE: active'));
      expect(after, contains('UNIT_veil.service_ENABLED: enabled'));
      expect(parseProvisionReport(after).nodeId == nodeId, isTrue);
      final read = await client.run(
        session,
        buildReadNodeConfigScript(NodeConfigTarget.veil),
      );
      expect(read.ok && !read.truncated, isTrue);
      final snapshot = parseReadNodeConfig(read.stdout);
      expect(snapshot != null && snapshot.sha256 != null, isTrue);
      final apply = await client.run(
        session,
        buildWriteNodeConfigScript(
          NodeConfigTarget.veil,
          snapshot!.contents,
          expectedSha256: snapshot.sha256,
        ),
      );
      await File(
        '$proofDir/config-private.log',
      ).writeAsString('${apply.stdout}\n${apply.stderr}');
      expect(apply.ok && !apply.truncated, isTrue);
      expect(apply.stdout, contains('CONFIG_APPLIED:'));
      final update = await client.run(
        session,
        buildNodeSoftwareUpdateScript(config.artifacts),
      );
      await File(
        '$proofDir/update-private.log',
      ).writeAsString('${update.stdout}\n${update.stderr}');
      expect(update.ok && !update.truncated, isTrue);
      expect(update.stdout, contains('UPDATED: veil-cli'));
      expect(parseProvisionReport(await inventory()).nodeId == nodeId, isTrue);
      await File('$proofDir/install-proof.json').writeAsString(
        jsonEncode({
          'installViaPinnedHelper': true,
          'systemdActive': true,
          'systemdEnabled': true,
          'identityPreservedOnRedeploy': true,
          'inventoryMatchesDeployment': true,
          'configCasApplyViaHelper': true,
          'sameVersionBinaryReinstallViaHelper': true,
        }),
      );
    },
    timeout: const Timeout(Duration(minutes: 14)),
    skip: inviteFile == null || proofDir == null
        ? 'Requires an explicitly owned disposable Linux/systemd helper'
        : false,
  );
}
