// At-rest batching qualification. Documents here are opaque random fixtures;
// signed revocation/FFI restore is covered by peer_authorization_live_test.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/peer_authorization.dart';

class _FaultStore extends SyncWrappedAsyncKvLogStore {
  _FaultStore(super.inner);
  final batches = <int>[];
  int? failAt;

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    batches.add(ops.length);
    if (batches.length == failAt) throw StateError('fixture commit refusal');
    return super.commit(ops);
  }
}

List<PeerAuthorizationEntry> _entries(int length) => List.generate(20, (index) {
  final peer = index + 1;
  final random = Random(peer + length);
  return PeerAuthorizationEntry(
    peer.toRadixString(16).padLeft(64, '0'),
    Uint8List.fromList(List.generate(length, (_) => random.nextInt(256))),
  );
});

void main() {
  test(
    'native authorization batches retain whole documents across failure and reopen',
    () async {
      final dir = await Directory.systemTemp.createTemp('xveil-auth-batch-');
      final path = '${dir.path}/fixture.hv';
      final password = Uint8List.fromList(utf8.encode('test-only-password'));
      final old = _entries(100);
      final large = _entries(PeerAuthorizationEntry.maxDocumentBytes);
      final io = _FaultStore(
        HvKvLogStore(
          hv.HvSpace.create(
            path: path,
            password: password,
            argon: hv.ArgonPreset.min,
          ),
        ),
      );
      var storage = HiddenVolumeStorage.fromAsyncStore(io);
      try {
        await storage.replacePeerAuthorization(old);
        io.batches.clear();
        io.failAt = 2;
        await expectLater(
          storage.replacePeerAuthorization(large),
          throwsStateError,
        );
        final partial = await storage.loadPeerAuthorization();
        expect(partial, hasLength(20));
        for (final entry in partial) {
          final index = int.parse(entry.peer, radix: 16) - 1;
          expect(
            entry.document,
            anyOf(equals(old[index].document), equals(large[index].document)),
          );
        }
        io.failAt = null;
        await storage.replacePeerAuthorization(large);
        expect(io.batches, everyElement(lessThanOrEqualTo(64)));
        expect(io.batches.length, greaterThan(2));
        await storage.close();
        storage = HiddenVolumeStorage.fromStore(
          HvKvLogStore(hv.HvSpace.open(path: path, password: password)),
        );
        final reopened = await storage.loadPeerAuthorization();
        expect(reopened, hasLength(20));
        for (final entry in reopened) {
          expect(
            entry.document,
            large[int.parse(entry.peer, radix: 16) - 1].document,
          );
        }
        // Shrinking all documents must remove every old tail atomically too.
        final small = _entries(1200);
        await storage.replacePeerAuthorization(small);
        for (final entry in await storage.loadPeerAuthorization()) {
          expect(
            entry.document,
            small[int.parse(entry.peer, radix: 16) - 1].document,
          );
        }
      } finally {
        await storage.close();
        await dir.delete(recursive: true);
      }
    },
    skip: Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty == true
        ? false
        : 'set XVEIL_HV_DYLIB to the native encrypted store',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
