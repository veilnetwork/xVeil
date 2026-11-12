@Timeout(Duration(minutes: 12))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/device_link_invite.dart';

import 'device_fixture.dart' show E2eIdentity;
import 'device_process_fixture.dart';
import 'e2e_env.dart';
import 'multi_device_process_e2e_test.dart' as base;

void main() {
  final gate = E2eGate.read();
  for (final includeDocument in [true, false]) {
    test(
      'link retry publishes saved identity with invite document=$includeDocument',
      () async {
        final evidence = Platform.environment['XVEIL_E2E_EVIDENCE_DIR'];
        expect(evidence, isNotNull);
        expect(Platform.environment['XVEIL_E2E_STORAGE_TIMING'], isNot('1'));
        final f = await ProcessFleet.start(gate);
        addTearDown(f.dispose);
        final a = f.a, b = f.b, c = f.c;
        await base.introduceProcesses(a, c);
        final ai = (await base.deviceInfo(a))['identity'] as String;
        final ci = (await base.deviceInfo(c))['identity'] as String;
        final bInfo = await base.deviceInfo(b);
        final beforeB = bInfo['nodeId'];
        expect(beforeB, isNot((await base.deviceInfo(a))['nodeId']));
        const history = 'link-write-retry-before-link';
        await a.checked('/send_message', query: {'peer': ci, 'text': history});
        await base.hasBody(c, ai, history);
        expect(
          (await base.rows(b, ci)).any((row) => row['body'] == history),
          isFalse,
          reason: 'history must not already be present before linking',
        );
        final key = (await a.admin(gate.veilCli!, [
          'identity',
          'dht-key',
          ai,
        ])).trim();
        Future<String?> document() async {
          final dump = await a.admin(gate.veilCli!, [
            'node',
            'dht',
            'get',
            key,
          ]);
          final hex = RegExp(
            r'^value: ([0-9a-f]+)$',
            multiLine: true,
          ).firstMatch(dump)?.group(1);
          if (hex == null) return null;
          return base64Encode([
            for (var i = 0; i < hex.length; i += 2)
              int.parse(hex.substring(i, i + 2), radix: 16),
          ]);
        }

        final before = await document();
        expect(before, isNotNull);
        final original = DeviceLinkInvite.parse(bInfo['invite'] as String);
        Uint8List? invitationDocument;
        if (includeDocument) {
          final request = File('${a.dir.path}/storage-inspect.new');
          await request.writeAsString(
            jsonEncode({
              'nonce': 'link-document',
              'linkDocumentFor': base64Encode(original.device.publicKey),
            }),
          );
          await request.rename('${a.dir.path}/storage-inspect.json');
          await waitUntil(
            () async {
              final response = File('${a.dir.path}/storage-inspected.json');
              if (!await response.exists()) return false;
              final value = jsonDecode(await response.readAsString()) as Map;
              if (value['nonce'] != 'link-document') return false;
              expect(value['sourceUnchanged'], isTrue);
              invitationDocument = base64Decode(value['document'] as String);
              return true;
            },
            what: 'owner prepares a signed invitation on an isolated copy',
            describe: a.tail,
          );
        }
        final invite = DeviceLinkInvite(
          device: BootstrapInvite.parse(await base.physicalInvite(b)),
          document: invitationDocument,
        ).toUri();
        expect(
          DeviceLinkInvite.parse(invite).document?.isNotEmpty ?? false,
          includeDocument,
          reason: 'the two runs must exercise different document paths',
        );
        const nonce = 'device-link-write-retry';
        await File(
          '${a.dir.path}/sovereign-write-arm.json',
        ).writeAsString(jsonEncode({'nonce': nonce}));
        final first = await a.call(
          '/device_link_prepare',
          query: {'invite': invite},
          body: E2eIdentity.x.phrase,
        );
        expect(first['ok'], isFalse);
        final checkpoint =
            jsonDecode(
                  await File(
                    '${a.dir.path}/sovereign-write-reached.json',
                  ).readAsString(),
                )
                as Map;
        expect(checkpoint['nonce'], nonce);
        expect(checkpoint['storeReturned'], isTrue);
        final saved = checkpoint['document'] as String;
        expect(saved, isNot(before));
        expect(await document(), before);
        expect((await a.checked('/devices'))['deviceGroup'], isNull);
        final pids = List<int>.of(a.ownedPids);
        final retry = await a.checked(
          '/device_link_prepare',
          query: {'invite': invite},
          body: E2eIdentity.x.phrase,
        );
        await waitUntil(
          () async => await document() == saved,
          what:
              'link retry refreshes the saved document before returning a token',
          describe: () async => 'matchesSaved=${await document() == saved}',
          progressEvery: const Duration(seconds: 1),
          timeout: const Duration(seconds: 5),
        );
        expect(a.ownedPids, pids);
        await base.join(b, a);
        final adopted = await b.checked(
          '/device_adopt_prepare',
          body: retry['token'] as String,
        );
        if (adopted['restarting'] == true) await b.restart();
        await base.join(a, b);
        await base.join(b, a);
        await a.checked('/device_snapshot_send');
        await waitUntil(
          () async =>
              (await b.checked('/devices'))['deviceGroup'] ==
              retry['deviceGroup'],
          what: 'B adopts the retried link',
          describe: b.tail,
        );
        final linkedB = await base.deviceInfo(b);
        expect(linkedB['identity'], ai);
        expect(linkedB['nodeId'], beforeB);
        await base.hasBody(b, ci, history);
        await b.checked(
          '/send_message',
          query: {'peer': ci, 'text': 'link-write-retry-B-to-C'},
        );
        await base.hasBody(c, ai, 'link-write-retry-B-to-C');
        await c.checked(
          '/send_message',
          query: {'peer': ai, 'text': 'link-write-retry-C-to-family'},
        );
        await base.hasBody(a, ci, 'link-write-retry-C-to-family');
        await base.hasBody(b, ci, 'link-write-retry-C-to-family');
        await File(
          '$evidence/link-write-retry-$includeDocument-summary.json',
        ).writeAsString(
          jsonEncode({
            'inviteIncludedDocument': includeDocument,
            'firstWriteDurableButCompletionLost': true,
            'firstCallerFailedWithoutGroupAdmission': true,
            'retryPublishedSavedDocument': true,
            'noSourceRestart': true,
            'targetKeptPhysicalDeviceId': true,
            'historyReachedTargetExactlyOnce': true,
            'targetToContactDelivered': true,
            'contactToBothDevicesDelivered': true,
          }),
        );
      },
      skip: !gate.enabled
          ? gate.skip
          : Platform.environment['XVEIL_E2E_SOVEREIGN_WRITE_FAULT'] != '1'
          ? 'set XVEIL_E2E_SOVEREIGN_WRITE_FAULT=1'
          : false,
    );
  }
}
