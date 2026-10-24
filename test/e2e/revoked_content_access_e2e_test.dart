@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'device_fixture.dart' show E2eIdentity;
import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart'
    show
        contactStatus,
        deviceInfo,
        hasBody,
        introduceProcesses,
        join,
        linkProcesses,
        rows;

void main() {
  final gate = E2eGate.read();
  test(
    'a revoked device cannot fetch a new file using a warm ownership mapping',
    () async {
      final fleet = await ProcessFleet.start(gate);
      addTearDown(fleet.dispose);
      final evidence = Platform.environment['XVEIL_REVOKED_CONTENT_EVIDENCE'];
      if (evidence != null) {
        await File('$evidence/fleet-private.json').writeAsString(
          jsonEncode({'root': fleet.root.path, 'runnerPid': pid}),
        );
      }
      final a = fleet.a, b = fleet.b, c = fleet.c;
      await introduceProcesses(a, c);
      await linkProcesses(a, b);
      final ai = (await deviceInfo(a))['identity'] as String;
      final ci = (await deviceInfo(c))['identity'] as String;
      final oldDevice = (await deviceInfo(b))['nodeId'] as String;
      await waitUntil(
        () async => await contactStatus(b, ci) == 'accepted',
        what: 'B knows C before the positive controls',
      );
      for (final (device, peer) in [(a, ci), (b, ci), (c, ai)]) {
        await device.checked(
          '/contact_set',
          query: {'peer': peer, 'p2p': 'deny'},
        );
      }
      await b.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'prime-file-device-proof'},
      );
      await hasBody(c, ai, 'prime-file-device-proof');
      final random = Random(40929);
      Future<({String cid, Uint8List bytes})> offer(String phase) async {
        final bytes = Uint8List.fromList(
          List.generate(96 * 1024, (_) => random.nextInt(256)),
        );
        final source = File('${c.dir.path}/$phase.bin');
        await source.writeAsBytes(bytes, flush: true);
        final sent = await c.checked(
          '/send_file',
          query: {'peer': ai, 'path': source.path, 'name': '$phase.bin'},
        );
        return (cid: sent['contentId'] as String, bytes: bytes);
      }

      Future<Map<String, dynamic>> download(
        ProcessDevice device,
        ({String cid, Uint8List bytes}) offered,
        String phase,
        int timeoutMs,
      ) => device.call(
        '/download_file',
        query: {
          'peer': ci,
          'cid': offered.cid,
          'path': '${device.dir.path}/received-$phase.bin',
          'expect_size': '${offered.bytes.length}',
          'timeout_ms': '$timeoutMs',
        },
        timeout: Duration(milliseconds: timeoutMs + 10000),
      );

      final before = await offer('before-revoke');
      final beforeResult = await download(b, before, 'before-revoke', 45000);
      expect(
        beforeResult['ok'],
        isTrue,
        reason: 'B must prove file access before revocation',
      );
      expect(
        await File('${b.dir.path}/received-before-revoke.bin').readAsBytes(),
        before.bytes,
      );
      final cPids = List<int>.of(c.ownedPids);
      await b.stop();
      final revoked = await a.checked(
        '/device_revoke',
        query: {'peer': oldDevice},
        body: E2eIdentity.x.phrase,
      );
      expect(revoked['docRevoked'], isTrue);
      final key = (await a.admin(gate.veilCli!, [
        'identity',
        'dht-key',
        ai,
      ])).trim();
      Future<String?> document(ProcessDevice device) async {
        final raw = await device.admin(gate.veilCli!, [
          'node',
          'dht',
          'get',
          key,
        ]);
        return RegExp(
          r'^value: ([0-9a-f]+)$',
          multiLine: true,
        ).firstMatch(raw)?.group(1);
      }

      final currentDocument = await document(a);
      expect(currentDocument, isNotNull);
      await a.checked(
        '/send_message',
        query: {'peer': ci, 'text': 'post-revoke-master-control'},
      );
      await hasBody(c, ai, 'post-revoke-master-control');
      await waitUntil(
        () async => await document(c) == currentDocument,
        what: 'warm C has the current signed revocation document',
        timeout: const Duration(minutes: 2),
      );
      await b.start();
      expect((await deviceInfo(b))['nodeId'], oldDevice);
      await join(b, c);
      final after = await offer('after-revoke');
      expect(after.cid, isNot(before.cid));
      final control = await download(a, after, 'after-revoke-control', 45000);
      expect(control['ok'], isTrue);
      expect(
        await File(
          '${a.dir.path}/received-after-revoke-control.bin',
        ).readAsBytes(),
        after.bytes,
      );
      final noNewOffer = !(await rows(b, ci)).any(
        (row) =>
            row['fileContentId'] == after.cid ||
            row['fileName'] == 'after-revoke.bin',
      );
      expect(
        noNewOffer,
        isTrue,
        reason:
            'B must not first receive the offer through normal identity fanout',
      );
      // CID is supplied explicitly by the adversarial fixture. Knowing it must
      // not revive this known revoked device's prior identity association.
      final attack = await download(b, after, 'after-revoke-attack', 15000);
      final attacked = File('${b.dir.path}/received-after-revoke-attack.bin');
      final receivedBytes = await attacked.exists()
          ? await attacked.length()
          : 0;
      final matched =
          receivedBytes == after.bytes.length &&
          (await attacked.readAsBytes()).indexed.every(
            (pair) => pair.$2 == after.bytes[pair.$1],
          );
      await b.call('/download_cancel', query: {'cid': after.cid});
      expect(
        c.ownedPids,
        cPids,
        reason:
            'C retains the primed ownership mapping in its original process',
      );
      if (evidence != null) {
        await File('$evidence/result.json').writeAsString(
          jsonEncode({
            'devices': 3,
            'same_identity_devices_before_revoke': 2,
            'pre_revoke_download_byte_exact': true,
            'current_document_barrier_observed': true,
            'unrevoked_post_revoke_download_byte_exact': true,
            'new_offer_absent_on_revoked_device': noNewOffer,
            'old_device_key_preserved': true,
            'source_process_not_restarted': true,
            'revoked_device_download_reported_success': attack['ok'] == true,
            'revoked_device_received_bytes': receivedBytes,
            'revoked_device_received_exact_new_payload': matched,
          }),
        );
      }
      expect(
        attack['ok'],
        isNot(true),
        reason: 'a learned revocation must fence stream access too',
      );
      expect(receivedBytes, 0);
    },
    skip: gate.skip,
  );
}
