import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_anchor_state.dart';
import 'package:xveil/data/storage/managed_encrypted_kv_log_store.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_metadata_blob.dart';
import 'package:xveil/data/storage/managed_store_tag.dart';
import 'package:xveil/data/storage/storage.dart' show RatchetStateEntry;
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/identity.dart';

import 'support/managed_store_fixture.dart';

void main() {
  setUp(() => expect(ensureHiddenVolumeLoaded(), isTrue));
  test(
    'native KV/log groups, anchors and outer keys survive cold reopen',
    () async {
      final fixture = await ManagedStoreFixture.create();
      final store = fixture.initialize();
      final keys = store.exportKeys();
      final before = store.commitSeq();
      expect(
        store.commit([
          PutOp(Ns.settings, Uint8List.fromList([7]), Uint8List.fromList([8])),
          AppendLogOp(Ns.fileChunks, 1, Uint8List.fromList([1, 2])),
          AppendLogOp(Ns.fileChunks, 2, Uint8List.fromList([3, 4])),
        ]),
        before + 1,
      );
      expect(store.commitSeq(), before + 1);
      expect(store.commitRoots().containsKey(before + 1), isTrue);
      expect(
        store.readLogGroups(Ns.fileChunks, [
          (ids: [1, 2], maxBytes: 4),
        ]),
        [
          Uint8List.fromList([1, 2, 3, 4]),
        ],
      );
      expect(
        store
            .iterLogRange(namespace: Ns.fileChunks, start: 2, limit: 1)
            .single
            .payload,
        [3, 4],
      );
      final occupancy = store.slotUtilization();
      expect(occupancy, isNotNull);
      expect(occupancy!.ownedChunks, greaterThan(0));
      store.close();
      expect(store.commitSeq, throwsStateError);
      expect(
        () => store.get(Ns.settings, Uint8List.fromList([7])),
        throwsStateError,
      );
      final cold = fixture.open();
      try {
        expect(cold.get(Ns.settings, Uint8List.fromList([7])), [8]);
        expect(cold.readLog(Ns.fileChunks, 2), [3, 4]);
        expect(cold.exportKeys(), keys);
        cold.commit([DeleteLogOp(Ns.fileChunks, 1)]);
        expect(cold.readLog(Ns.fileChunks, 1), isNull);
      } finally {
        cold.close();
      }
    },
  );

  test(
    'reserved metadata is inaccessible and invalid batches have no applied prefix',
    () async {
      final fixture = await ManagedStoreFixture.create();
      final store = fixture.initialize();
      try {
        final before = store.commitSeq();
        for (final namespace in [0, 254, 255, 256, -1]) {
          expect(
            () => store.commit([
              PutOp(
                Ns.settings,
                Uint8List.fromList([1]),
                Uint8List.fromList([2]),
              ),
              DeleteOp(namespace, Uint8List.fromList([3])),
            ]),
            throwsArgumentError,
          );
          expect(() => store.eraseNamespace(namespace), throwsArgumentError);
          expect(() => store.get(namespace, Uint8List(0)), throwsArgumentError);
          expect(() => store.readLogGroups(namespace, []), throwsArgumentError);
          expect(() => store.kvKeys(namespace), throwsArgumentError);
        }
        expect(store.get(Ns.settings, Uint8List.fromList([1])), isNull);
        expect(store.commitSeq(), before);
      } finally {
        store.close();
      }
      fixture.open().close();
    },
  );

  test(
    'constructor rejects conflicting roles or malformed metadata without resetting files',
    () async {
      for (final problem in ['role', 'metadata', 'initialize-existing']) {
        final corruptState = problem == 'metadata';
        final fixture = await ManagedStoreFixture.create();
        final seed = fixture.initialize();
        seed.commit([
          PutOp(Ns.settings, Uint8List.fromList([7]), Uint8List.fromList([8])),
        ]);
        seed.close();
        final owned = fixture.spaces();
        if (corruptState) {
          ManagedMetadataBlob(
            owned.maintenance,
          ).write(Uint8List.fromList([99]));
        } else if (problem == 'role') {
          owned.content.commit([
            ManagedStoreTag(
              identity: ManagedIdentityId('2' * 32),
              role: ManagedStoreRole.content,
              generation: 'a' * 64,
            ).putOp(),
          ]);
        }
        final contentBytes = await File(
          '${fixture.root.path}/content.hv',
        ).readAsBytes();
        expect(
          () => problem == 'initialize-existing'
              ? ManagedEncryptedKvLogStore.initializeOwned(
                  keybox: owned.keybox,
                  content: owned.content,
                  maintenance: owned.maintenance,
                )
              : ManagedEncryptedKvLogStore.openOwned(
                  keybox: owned.keybox,
                  content: owned.content,
                  maintenance: owned.maintenance,
                ),
          corruptState ? throwsFormatException : throwsStateError,
        );
        expect(owned.content.closed, isTrue);
        expect(owned.maintenance.closed, isTrue);
        expect(owned.keybox.exportKeys, throwsStateError);
        expect(
          await File('${fixture.root.path}/content.hv').readAsBytes(),
          contentBytes,
        );
        final reopened = fixture.spaces();
        try {
          expect(reopened.content.get(Ns.settings, Uint8List.fromList([7])), [
            8,
          ]);
          if (corruptState) {
            expect(ManagedMetadataBlob(reopened.maintenance).read(), [99]);
          }
        } finally {
          reopened.content.close();
          reopened.maintenance.close();
          reopened.keybox.close();
        }
      }
    },
  );

  test(
    'close failure releases other handles, blocks new I/O and can be retried',
    () async {
      final fixture = await ManagedStoreFixture.create();
      fixture.initialize().close();
      final owned = fixture.spaces();
      final store = ManagedEncryptedKvLogStore.openOwned(
        keybox: owned.keybox,
        content: owned.content,
        maintenance: owned.maintenance,
      );
      owned.content.failClose = true;
      expect(store.close, throwsA(isA<ManagedFixtureFailure>()));
      expect(owned.content.closed, isFalse);
      expect(owned.maintenance.closed, isTrue);
      expect(owned.keybox.exportKeys, throwsStateError);
      expect(store.exportKeys, throwsStateError);
      expect(() => store.commit([]), throwsStateError);
      store.close();
      expect(owned.content.closeCalls, 2);
      expect(owned.maintenance.closeCalls, 1);
      fixture.open().close();
    },
  );

  test(
    'lost recovery response does not erase a prepared state or repeat a completed one',
    () async {
      for (final after in [false, true]) {
        final fixture = await ManagedStoreFixture.create();
        fixture.initialize().close();
        final owned = fixture.spaces();
        final blob = ManagedMetadataBlob(owned.maintenance);
        final state = ManagedAnchorState.decode(blob.read());
        final tag = ManagedStoreTag.read(
          owned.content,
          identity: fixture.identity,
          role: ManagedStoreRole.content,
        );
        final source = state.resolve(
          contentIdentity: fixture.identity,
          contentMarker: tag.generation!,
          innerSequence: owned.content.commitSeq(),
          innerRoots: owned.content.commitRoots(),
        );
        final pending = state.prepare(
          source: source,
          replacement: ManagedGeneration.fresh(
            innerFloor: 1,
            offset: source.sequence,
          ),
        );
        blob.write(pending.encode());
        owned.maintenance.failHeadBefore = !after;
        owned.maintenance.failHeadAfter = after;
        expect(
          () => ManagedEncryptedKvLogStore.openOwned(
            keybox: owned.keybox,
            content: owned.content,
            maintenance: owned.maintenance,
          ),
          throwsA(isA<ManagedFixtureFailure>()),
        );
        final retry = fixture.spaces();
        final stored = ManagedAnchorState.decode(
          ManagedMetadataBlob(retry.maintenance).read(),
        );
        expect(stored.prepared == null, after);
        final reopened = ManagedEncryptedKvLogStore.openOwned(
          keybox: retry.keybox,
          content: retry.content,
          maintenance: retry.maintenance,
        );
        try {
          expect(reopened.commitSeq(), source.sequence);
          expect(retry.maintenance.commitCalls, after ? 0 : greaterThan(0));
        } finally {
          reopened.close();
        }
      }
    },
  );

  test(
    'current application namespace budget fits beside the managed role marker',
    () async {
      final fixture = await ManagedStoreFixture.create();
      final store = fixture.initialize();
      try {
        store.commit([
          for (final namespace in [
            Ns.settings,
            Ns.contacts,
            Ns.media,
            Ns.outboxIndex,
            Ns.ratchet,
          ])
            PutOp(namespace, Uint8List.fromList([1]), Uint8List.fromList([2])),
          for (final namespace in [
            Ns.fileChunks,
            Ns.outbox,
            Ns.callLog,
            for (
              var n = Ns.messageLogShardFirst;
              n <= Ns.messageLogShardLast;
              n++
            )
              n,
          ])
            AppendLogOp(namespace, 1, Uint8List.fromList([3])),
        ]);
        expect(store.readLog(Ns.messageLogShardLast, 1), [3]);
        expect(store.get(Ns.ratchet, Uint8List.fromList([1])), [2]);
        final before = store.commitSeq();
        expect(
          () => store.commit([
            PutOp(
              Ns.ratchet,
              Uint8List.fromList([1]),
              Uint8List.fromList([99]),
            ),
            AppendLogOp(Ns.messageLog, 1, Uint8List.fromList([4])),
          ]),
          throwsA(
            isA<hv.HvException>().having(
              (error) => error.kind,
              'kind',
              'TooManyNamespaces',
            ),
          ),
        );
        expect(store.commitSeq(), before);
        expect(store.get(Ns.ratchet, Uint8List.fromList([1])), [2]);
      } finally {
        store.close();
      }
    },
  );

  test('warnings and occupancy include all three owned files', () async {
    final fixture = await ManagedStoreFixture.create();
    fixture.initialize().close();
    final owned = fixture.spaces();
    owned.content.stagedWarning = 'fixture-content';
    owned.maintenance.stagedWarning = 'fixture-maintenance';
    final expected = [
      owned.keybox.slotUtilization()!,
      owned.content.slotUtilization()!,
      owned.maintenance.slotUtilization()!,
    ];
    final store = ManagedEncryptedKvLogStore.openOwned(
      keybox: owned.keybox,
      content: owned.content,
      maintenance: owned.maintenance,
    );
    try {
      expect(
        store.hardeningWarning(),
        allOf(contains('fixture-content'), contains('fixture-maintenance')),
      );
      expect(
        store.slotUtilization()!.totalSlots,
        expected.fold<int>(0, (sum, item) => sum + item.totalSlots),
      );
      expect(
        store.slotUtilization()!.ownedChunks,
        expected.fold<int>(0, (sum, item) => sum + item.ownedChunks),
      );
      store.acknowledgeHardeningWarning();
      expect(store.hardeningWarning(), isNull);
    } finally {
      store.close();
    }
  });

  test(
    'real domain facade persists profile/messages/files and erase preserves sibling and backend roles',
    () async {
      final first = await ManagedStoreFixture.create();
      final sibling = await ManagedStoreFixture.create(
        id: '22222222222222222222222222222222',
      );
      HiddenVolumeStorage facade(ManagedStoreFixture fixture) =>
          HiddenVolumeStorage(
            ({required password, required create}) {
              try {
                return create
                    ? fixture.initialize(withPassword: password)
                    : fixture.open(withPassword: password);
              } on hv.HvException catch (error) {
                if (error.kind == 'AuthFailed') return null;
                rethrow;
              }
            },
            keysOpener: (keys) {
              try {
                return fixture.open(withKeys: keys);
              } on hv.HvException catch (error) {
                if (error.kind == 'AuthFailed') return null;
                rethrow;
              }
            },
          );
      final body = Uint8List.fromList(List.generate(17000, (i) => i % 251));
      final conversationKey = Uint8List.fromList(List.generate(64, (i) => i));
      final peer = NodeId.fromHex('a' * 64);
      for (final fixture in [first, sibling]) {
        final storage = facade(fixture);
        try {
          expect(
            await storage.open(
              password: utf8.decode(fixture.password),
              createIfMissing: true,
            ),
            isTrue,
          );
          await storage.saveProfile(
            UserProfile(displayName: fixture == first ? 'first' : 'sibling'),
          );
          await storage.appendMessage(
            Message(
              id: 'fixture-message',
              conversationId: peer.hex,
              direction: MessageDirection.outgoing,
              body: 'managed native content',
              timestamp: DateTime.utc(2026),
            ),
          );
          await storage.storeFile('fixture-body', body);
          await storage.enqueueOutboxFrame('fixture-outbox', peer.hex, body);
          await storage.saveRatchetStates([
            RatchetStateEntry(conversationKey, body),
          ]);
          expect(await storage.readCommitAnchor(), isNotNull);
          expect(await storage.exportSpaceKeys(), fixture.keys);
        } finally {
          await storage.close();
        }
      }
      final siblingFiles = {
        for (final name in ['keybox', 'content', 'maintenance'])
          name: await File('${sibling.root.path}/$name.hv').readAsBytes(),
      };
      final rejected = facade(first);
      try {
        expect(await rejected.openWithKeys(Uint8List(64)), isFalse);
        expect(
          await rejected.open(password: 'wrong-fixture-password'),
          isFalse,
        );
      } finally {
        await rejected.close();
      }
      final cold = facade(first);
      try {
        expect(await cold.openWithKeys(first.keys!), isTrue);
        expect(
          (await cold.loadMessages(peer.hex)).single.body,
          'managed native content',
        );
        expect(await cold.loadFile('fixture-body'), body);
        expect((await cold.pendingOutboxFrames()).single.wire, body);
        expect(await cold.loadRatchetState(conversationKey), body);
        await cold.ackOutboxFrame('fixture-outbox', fromPeerHex: 'b' * 64);
        expect(
          (await cold.pendingOutboxFrames()).single.frameId,
          'fixture-outbox',
        );
        await cold.ackOutboxFrame('fixture-outbox', fromPeerHex: peer.hex);
        expect(await cold.pendingOutboxFrames(), isEmpty);
        await cold.eraseSpace();
        expect(await cold.loadProfile(), isNull);
        expect(await cold.loadFile('fixture-body'), isNull);
      } finally {
        await cold.close();
      }
      for (final name in siblingFiles.keys) {
        expect(
          await File('${sibling.root.path}/$name.hv').readAsBytes(),
          siblingFiles[name],
        );
      }
      final survivor = facade(sibling);
      try {
        expect(await survivor.openWithKeys(sibling.keys!), isTrue);
        expect((await survivor.loadProfile())!.displayName, 'sibling');
        expect(
          (await survivor.loadMessages(peer.hex)).single.id,
          'fixture-message',
        );
        expect(await survivor.loadFile('fixture-body'), body);
        expect((await survivor.pendingOutboxFrames()).single.wire, body);
        expect(await survivor.loadRatchetState(conversationKey), body);
      } finally {
        await survivor.close();
      }
      final empty = facade(first);
      try {
        expect(await empty.openWithKeys(first.keys!), isTrue);
        expect(await empty.loadProfile(), isNull);
        expect(await empty.loadMessages(peer.hex), isEmpty);
        expect(await empty.loadFile('fixture-body'), isNull);
        expect(await empty.pendingOutboxFrames(), isEmpty);
        expect(await empty.loadRatchetState(conversationKey), isNull);
      } finally {
        await empty.close();
      }
    },
  );
}
