import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/crypto/blake3.dart';
import 'package:xveil/crypto/sha256_backend.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/state/group_service.dart';

void main() {
  final path = Platform.environment['VEIL_FFI_DYLIB'];
  test(
    'native chain SHA-256 matches the independent Dart protocol hash',
    () async {
      final backend = Sha256Backend.forLibrary(DynamicLibrary.open(path!));
      expect(backend.nativeEnabled, isTrue);
      final random = Random(113);
      for (final length in [0, 1, 55, 56, 63, 64, 65, 1024, 4097, 65536]) {
        for (final signatureLength in [0, 64, 3400]) {
          final row = GroupMessage(
            groupId: NodeId(Uint8List(32)..fillRange(0, 32, 1)),
            author: NodeId(Uint8List(32)..fillRange(0, 32, 2)),
            seq: length,
            prevHash: 'a' * 64,
            body: String.fromCharCodes(
              List.generate(length, (_) => 32 + random.nextInt(95)),
            ),
            policyVersion: 1,
            createdAtMs: 1700000000000,
            signature: Uint8List.fromList(
              List.generate(signatureLength, (_) => random.nextInt(256)),
            ),
          );
          String native() => crypto.Digest(
            backend.hashParts([row.canonicalBytes(), row.signature]),
          ).toString();
          expect(native(), groupMessageHash(row));
          final original = native();
          if (row.signature.isNotEmpty) {
            row.signature[0] ^= 1;
            expect(native(), groupMessageHash(row));
            expect(native(), isNot(original));
          }
          row.groupId.bytes[0] ^= 1;
          expect(
            native(),
            groupMessageHash(row),
            reason: 'mutable fields are always rehashed',
          );
        }
      }
      final abc = backend.hash(Uint8List.fromList(utf8.encode('abc')));
      expect(
        crypto.Digest(abc).toString(),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        crypto.Digest(backend.hash(Uint8List(0))).toString(),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    },
    skip: path == null ? 'set VEIL_FFI_DYLIB' : false,
  );

  test(
    'native service reads a Dart-hashed chain and appends the same commitment',
    () async {
      final library = DynamicLibrary.open(path!);
      final toml = File(
        'test/native/fixtures/ratchet_state_identity_0.toml',
      ).readAsStringSync();
      final signed = EmbeddedNode.signMessage(toml, Uint8List(0), lib: library);
      final signer = NativeGroupSigner(
        identityToml: toml,
        selfId: NodeId(blake3Hash(signed.publicKey)),
        selfPubKey: signed.publicKey,
        lib: library,
      );
      final kv = FakeKvLogStore();
      final storage = HiddenVolumeStorage(
        ({required password, required bool create}) => kv,
      );
      await storage.open(password: 'synthetic-chain', createIfMissing: true);
      final service = GroupService(storage, signer);
      addTearDown(() async {
        service.dispose();
        await storage.close();
      });
      final gid = await service.createGroup('synthetic chain');
      final seed = (await service.load(gid))!;
      final rows = <GroupMessage>[];
      for (var i = 0; i < 64; i++) {
        rows.add(
          signer.signMessage(
            GroupMessage(
              groupId: gid,
              author: signer.selfId,
              seq: i,
              prevHash: rows.isEmpty ? '' : groupMessageHash(rows.last),
              body: 'row-$i',
              policyVersion: 1,
              createdAtMs: seed.manifest.createdAtMs + i,
              signature: Uint8List(0),
            ),
          ),
        );
      }
      expect(
        await service.ingestSnapshot(
          jsonEncode({
            'm': seed.manifest.toJson(),
            'c': [for (final c in seed.control) c.toJson()],
            'g': [for (final m in rows) m.toJson()],
            'r': [],
          }),
        ),
        isTrue,
      );
      expect(
        (await service.messagesOf(gid)).map((m) => m.body),
        rows.map((m) => m.body),
      );
      expect(
        await service.postMessage(gid, 'native suffix', broadcast: false),
        isTrue,
      );
      final complete = await service.messagesOf(gid);
      expect(complete, hasLength(65));
      final nativeSuffix = complete.singleWhere(
        (m) => m.body == 'native suffix',
      );
      expect(nativeSuffix.prevHash, groupMessageHash(rows.last));
      // Same valid signature over a different predecessor does not repair a gap.
      final suffix = signer.signMessage(
        GroupMessage(
          groupId: gid,
          author: signer.selfId,
          seq: 66,
          prevHash: 'f' * 64,
          body: 'disconnected suffix',
          policyVersion: 1,
          createdAtMs: complete.last.createdAtMs + 1,
          signature: Uint8List(0),
        ),
      );
      final held = (await service.load(gid))!;
      await service.ingestSnapshot(
        jsonEncode({
          'm': held.manifest.toJson(),
          'c': [for (final c in held.control) c.toJson()],
          'g': [
            for (final m in [...held.messages, suffix]) m.toJson(),
          ],
          'r': [],
        }),
      );
      expect(
        (await service.messagesOf(gid)).map((m) => m.body),
        complete.map((m) => m.body),
      );
    },
    skip: path == null ? 'set VEIL_FFI_DYLIB' : false,
  );
}
