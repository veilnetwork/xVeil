import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/crypto/blake3.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/state/group_service.dart';

import '../support/timed_native_store.dart';

class _HeldReads extends HiddenVolumeStorage {
  _HeldReads(super.store) : super.fromAsyncStore();
  String? heldFirst, header;
  Completer<void>? entered, release, headerRead;
  @override
  Future<List<Uint8List>?> loadFiles(
    List<String> ids, {
    required int maxBytesPerFile,
  }) async {
    if (ids.isNotEmpty && ids.first == heldFirst) {
      heldFirst = null;
      entered!.complete();
      await release!.future;
    }
    return super.loadFiles(ids, maxBytesPerFile: maxBytesPerFile);
  }

  @override
  Future<Uint8List?> loadFile(String id, {int? maxBytes}) async {
    final value = await super.loadFile(id, maxBytes: maxBytes);
    if (id == header && headerRead != null) {
      final signal = headerRead!;
      headerRead = null;
      signal.complete();
    }
    return value;
  }
}

void main() {
  test(
    'staggered native journal readers retain independent verified views',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final dir = await Directory.systemTemp.createTemp('xveil-joined-read-');
      final lib = DynamicLibrary.open(Platform.environment['VEIL_FFI_DYLIB']!);
      final toml = File(
        'test/native/fixtures/ratchet_state_identity_0.toml',
      ).readAsStringSync();
      final signed = EmbeddedNode.signMessage(toml, Uint8List(0), lib: lib);
      final signer = NativeGroupSigner(
        identityToml: toml,
        selfId: NodeId(blake3Hash(signed.publicKey)),
        selfPubKey: signed.publicKey,
        lib: lib,
      );
      final inner = (await workerSpaceOpener('${dir.path}/fixture.hv')(
        password: Uint8List.fromList(utf8.encode('joined-fixture')),
        create: true,
      ))!;
      var recording = false;
      final counters = <String, int>{};
      final store = TimedNativeStore(inner, Stopwatch()..start(), (event) {
        if (!recording) return;
        final op = event['operation'] as String;
        counters.update(op, (n) => n + 1, ifAbsent: () => 1);
      });
      final storage = _HeldReads(store);
      final service = GroupService(storage, signer);
      try {
        final gid = await service.createGroup('joined fixture');
        final seed = (await service.load(gid))!;
        final rows = [
          for (var i = 0; i < 128; i++)
            signer.signMessage(
              GroupMessage(
                groupId: gid,
                author: signer.selfId,
                seq: i,
                prevHash: '',
                signature: Uint8List(0),
                body: 'row-$i:${'x' * 4096}',
                policyVersion: 1,
                createdAtMs: seed.manifest.createdAtMs + i,
              ),
            ),
        ];
        expect(
          await service.ingestSnapshot(
            jsonEncode({
              'm': seed.manifest.toJson(),
              'c': [for (final c in seed.control) c.toJson()],
              'g': [for (final row in rows) row.toJson()],
              'r': [],
            }),
          ),
          isTrue,
        );
        final key = 'group:${gid.hex}';
        final header =
            jsonDecode(utf8.decode((await storage.loadFile(key))!)) as Map;
        final segments = List<String>.from(header['gs'] as List);
        expect(segments.length, greaterThan(8));
        storage.header = key;
        final result = <String, Object?>{
          'schema': 'xveil-joined-read/1',
          'rows': 128,
          'segments': segments.length,
        };
        for (final parallel in [false, true]) {
          counters.clear();
          final watch = Stopwatch()..start();
          recording = true;
          for (var i = 0; i < 12; i++) {
            if (!parallel) {
              expect(
                (await service.load(gid))!.messages.map((m) => m.body),
                rows.map((m) => m.body),
              );
              continue;
            }
            final entered = Completer<void>(),
                release = Completer<void>(),
                headerRead = Completer<void>();
            storage.heldFirst = segments[8];
            storage.entered = entered;
            storage.release = release;
            final first = service.load(gid);
            Future<GroupBundle?>? second;
            try {
              await entered.future;
              storage.headerRead = headerRead;
              second = service.load(gid);
              await headerRead.future;
              await Future<void>.delayed(Duration.zero);
            } finally {
              release.complete();
            }
            final views = await Future.wait([first, second]);
            expect(views.every((v) => v!.messages.length == 128), isTrue);
            expect(
              views[0]!.messages.map((m) => m.body),
              rows.map((m) => m.body),
            );
            expect(
              views[1]!.messages.map((m) => m.body),
              rows.map((m) => m.body),
            );
            final signature = Uint8List.fromList(
              views[1]!.messages.first.signature,
            );
            views[0]!.messages.first.signature[0] ^= 1;
            expect(views[1]!.messages.first.signature, signature);
          }
          watch.stop();
          recording = false;
          result[parallel ? 'staggeredPairs' : 'sequential'] = {
            'repeats': 12,
            'us': watch.elapsedMicroseconds,
            'rpc': Map.of(counters),
          };
        }
        final saved = (await storage.loadFile(segments.first))!;
        await storage.deleteStoredFile(segments.first);
        expect(await service.load(gid), isNull);
        await storage.storeFile(segments.first, saved);
        expect(await service.messagesOf(gid), hasLength(128));
        result['independentViewsAndFreshDamageRepairVerified'] = true;
        final evidence = Platform.environment['GROUP_JOINED_READ_EVIDENCE'];
        if (evidence != null) {
          await File(evidence).writeAsString(jsonEncode(result));
        }
      } finally {
        recording = false;
        if (storage.release != null && !storage.release!.isCompleted) {
          storage.release!.complete();
        }
        await service.dispose();
        await storage.close();
        await dir.delete(recursive: true);
      }
    },
    skip:
        [
          'XVEIL_HV_DYLIB',
          'VEIL_FFI_DYLIB',
        ].every((k) => Platform.environment[k]?.isNotEmpty == true)
        ? false
        : 'set verified native libraries',
  );
}
