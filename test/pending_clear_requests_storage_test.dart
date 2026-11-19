import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart'
    show workerSpaceOpener;
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/clear_request.dart';
import 'package:xveil/state/messaging.dart';

String _id(int value) =>
    NodeId(Uint8List.fromList(sha256.convert([value]).bytes)).hex;

PendingClearRequest _direct(int n) => PendingClearRequest(
  chatHex: _id(n),
  requesterHex: _id(n),
  atMs: 1000 + n,
  seq: 3,
  watermark: {_id(n): 2},
);

PendingClearRequest _largeGroup() => PendingClearRequest(
  chatHex: _id(100),
  requesterHex: _id(101),
  atMs: 2000,
  seq: 0,
  groupKind: kGroupClearAll,
  watermark: {for (var n = 1; n <= 96; n++) _id(n): n * 10},
);

class _ClearRequestCommitStore extends FakeKvLogStore {
  bool? failAfterCommit;

  @override
  int commit(List<KvLogOp> ops) {
    final failure = failAfterCommit;
    if (failure == null) return super.commit(ops);
    failAfterCommit = null;
    if (failure) super.commit(ops);
    throw StateError('fixture pending clear request commit failed');
  }
}

void main() {
  final nativeLibrary = Platform.environment['XVEIL_HV_DYLIB'];
  for (final native in [false, true]) {
    group(
      'pending clear request storage (native=$native)',
      () {
        late HiddenVolumeStorage storage;
        late MessagingService service;
        late LoopbackTransport transport;
        late _ClearRequestCommitStore raw;
        const password = 'clear-request-fixture';

        setUp(() async {
          if (native) {
            expect(ensureHiddenVolumeLoaded(dylibPath: nativeLibrary), isTrue);
            final directory = await Directory.systemTemp.createTemp(
              'clear-requests-',
            );
            addTearDown(() => directory.delete(recursive: true));
            final path = '${directory.path}/store.hv';
            HvKvLogStore(
              hv.HvSpace.create(
                path: path,
                password: Uint8List.fromList(password.codeUnits),
                argon: hv.ArgonPreset.light,
              ),
            ).close();
            storage = HiddenVolumeStorage.async(workerSpaceOpener(path));
          } else {
            raw = _ClearRequestCommitStore();
            storage = HiddenVolumeStorage(
              ({required password, required create}) => raw,
            );
          }
          expect(await storage.open(password: password), isTrue);
          transport = LoopbackTransport();
          service = MessagingService(transport, storage);
          addTearDown(() async {
            await service.dispose();
            await storage.close();
            await transport.dispose();
          });
        });

        Future<void> reopen() async {
          await service.dispose();
          await storage.close();
          expect(await storage.open(password: password), isTrue);
          service = MessagingService(transport, storage);
        }

        test('keeps 64 requests after migration and reopen', () async {
          await storage.putSetting(
            kPendingClearRequestsKey,
            encodePendingClearRequests([_direct(1)]),
          );
          for (var n = 2; n <= kMaxPendingClearRequests; n++) {
            await service.rememberClearRequest(_direct(n));
          }
          await reopen();
          expect((await service.pendingClearRequests()).map((r) => r.key), [
            for (var n = kMaxPendingClearRequests; n > 0; n--) _direct(n).key,
          ]);
          await service.rememberClearRequest(
            _direct(kMaxPendingClearRequests + 1),
          );
          await reopen();
          expect((await service.pendingClearRequests()).map((r) => r.key), [
            for (var n = kMaxPendingClearRequests + 1; n > 1; n--)
              _direct(n).key,
          ]);
        });

        test(
          'round-trips a large group watermark and retains a small request on removal',
          () async {
            final group = _largeGroup();
            await service.rememberClearRequest(_direct(1));
            await service.rememberClearRequest(group);
            await reopen();
            final pending = await service.pendingClearRequests();
            expect(pending.first.watermark, group.watermark);
            expect(pending.last.key, _direct(1).key);
            await service.answerClearRequest(pending.first, accept: false);
            await reopen();
            expect(
              (await service.pendingClearRequests()).single.key,
              _direct(1).key,
            );
            expect(
              (await storage.settingsKeys()).where(
                (k) => k.startsWith('clear.requests.chunk.v2:'),
              ),
              isEmpty,
            );
          },
        );

        if (!native) {
          for (final committed in [false, true]) {
            test(
              'publishes the complete chunked list or the old inline value (commit=$committed)',
              () async {
                await service.rememberClearRequest(_direct(1));
                final group = _largeGroup();
                raw.failAfterCommit = committed;
                await expectLater(
                  service.rememberClearRequest(group),
                  throwsStateError,
                );
                await reopen();
                final pending = await service.pendingClearRequests();
                expect(pending.map((r) => r.key), [
                  if (committed) group.key,
                  _direct(1).key,
                ]);
                if (committed) expect(pending.first.watermark, group.watermark);
              },
            );
          }

          test(
            'missing chunks leave the pending list unreadable until repaired',
            () async {
              final group = _largeGroup();
              await service.rememberClearRequest(group);
              final key = Uint8List.fromList(
                utf8.encode('clear.requests.chunk.v2:1'),
              );
              final part = raw.get(Ns.settings, key)!;
              raw.commit([DeleteOp(Ns.settings, key)]);
              await expectLater(
                service.pendingClearRequests(),
                throwsFormatException,
              );
              await expectLater(
                service.rememberClearRequest(_direct(1)),
                throwsFormatException,
              );
              raw.commit([PutOp(Ns.settings, key, part)]);
              expect(
                (await service.pendingClearRequests()).single.watermark,
                group.watermark,
              );
            },
          );
        }
      },
      skip: native && nativeLibrary == null,
    );
  }
}
