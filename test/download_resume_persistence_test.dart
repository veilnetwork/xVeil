import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

const registry = 'download-resume.registry.v1';
String cid(int n) => n.toRadixString(16).padLeft(64, '0');
final peer = NodeId(Uint8List(32)..fillRange(0, 32, 0xbb));

class _Offline extends LoopbackTransport {
  int sends = 0;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    sends++;
  }
}

class _HeldStorage extends HiddenVolumeStorage {
  _HeldStorage(FakeKvLogStore kv)
    : super(({required password, required bool create}) => kv);
  Completer<void>? entered, release;
  Completer<void>? lookupEntered, lookupRelease;
  Object? readFailure;
  StackTrace? readFailureStack;
  @override
  Future<Uint8List?> loadFile(String id, {int? maxBytes}) {
    if (id == registry && readFailure != null) {
      final stack = readFailureStack;
      if (stack != null) Error.throwWithStackTrace(readFailure!, stack);
      throw readFailure!;
    }
    return super.loadFile(id, maxBytes: maxBytes);
  }

  @override
  Future<bool> hasFile(String id) async {
    final gate = lookupRelease;
    if (gate != null) {
      lookupRelease = null;
      lookupEntered!.complete();
      await gate.future;
    }
    return super.hasFile(id);
  }

  @override
  Future<void> storeFile(
    String id,
    Uint8List bytes, {
    String? name,
    List<String> retireHints = const [],
  }) async {
    if (id == registry && release != null) {
      final gate = release!;
      release = null;
      entered!.complete();
      await gate.future;
    }
    return super.storeFile(id, bytes, name: name, retireHints: retireHints);
  }
}

class _RefusedMetadata extends FakeKvLogStore {
  bool refuse = false;
  @override
  int commit(List<KvLogOp> ops) {
    if (refuse &&
        ops.any(
          (op) =>
              op is PutOp &&
              op.namespace == Ns.settings &&
              utf8.decode(op.key) == 'file:$registry',
        )) {
      throw StateError('secret-cid /private/secret-destination');
    }
    return super.commit(ops);
  }
}

void main() {
  late FakeKvLogStore kv;
  late _HeldStorage s;
  late _Offline transport;
  late MessagingService service;
  setUp(() async {
    kv = _RefusedMetadata();
    s = _HeldStorage(kv);
    await s.open(password: 'fixture', createIfMissing: true);
    await s.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    transport = _Offline();
    service = MessagingService(transport, s, plainFileStream: true);
    errorJournal.clear();
  });
  tearDown(() async {
    s.release?.complete();
    s.lookupRelease?.complete();
    await service.dispose();
    await transport.dispose();
    await s.close();
    errorJournal.clear();
  });
  Future<void> restart() async {
    await service.dispose();
    service = MessagingService(transport, s, plainFileStream: true);
  }

  for (final entry in ['store', 'store-any', 'file', 'file-any']) {
    for (final action in ['cancel', 'replace', 'clear']) {
      test('a suspended $entry preparation cannot survive $action', () async {
        const oldPath = '/virtual/preparation-old.bin';
        const newPath = '/virtual/preparation-new.bin';
        final contentId = cid(99);
        var oldCloses = 0;
        var oldWrites = 0;
        s.lookupEntered = Completer<void>();
        final gate = Completer<void>();
        s.lookupRelease = gate;
        Future<ContentDownloadResult> old;
        switch (entry) {
          case 'store':
            old = service.downloadContent(peer, contentId);
          case 'store-any':
            old = service.downloadContentFromAny(const [], contentId);
          case 'file':
            old = service.downloadContentToFile(
              peer,
              contentId,
              oldPath,
              write: (_, _) async {
                oldWrites++;
              },
              close: () async {
                oldCloses++;
              },
            );
          default:
            old = service.downloadContentToFileFromAny(
              const [],
              contentId,
              oldPath,
              write: (_, _) async {
                oldWrites++;
              },
              close: () async {
                oldCloses++;
              },
            );
        }
        await s.lookupEntered!.future;
        try {
          if (action == 'cancel') {
            await service.cancelContentDownload(contentId);
          }
          if (action == 'clear') await service.clearPendingDownloads();
          if (action == 'replace') {
            expect(
              await service.downloadContentToFileFromAny(
                const [],
                contentId,
                newPath,
                write: (_, _) async {},
                close: () async {},
              ),
              ContentDownloadResult.noOffer,
            );
          }
        } finally {
          gate.complete();
        }
        await old;
        final encoded = await s.loadFile(registry);
        final entries = encoded == null
            ? []
            : jsonDecode(utf8.decode(encoded)) as List;
        if (action == 'replace') {
          expect(entries.single['path'], newPath);
          expect(entries.single['mode'], 'file');
        } else {
          expect(entries, isEmpty);
        }
        expect(
          transport.sends,
          0,
          reason: 'the obsolete request must not seek a reoffer',
        );
        expect(oldWrites, 0);
        if (entry.startsWith('file')) expect(oldCloses, 1);
      });
    }
  }

  for (final anySource in [false, true]) {
    for (final closeFails in [false, true]) {
      test(
        'retired ${anySource ? 'swarm' : 'direct'} sink cleanup preserves '
        'a new request to the same path (close failure=$closeFails)',
        () async {
          final contentId = cid(100);
          const path = '/virtual/same-destination.bin';
          s.lookupEntered = Completer<void>();
          final gate = Completer<void>();
          s.lookupRelease = gate;
          var oldCloses = 0;
          Future<void> oldClose() async {
            oldCloses++;
            if (closeFails) throw StateError('private cleanup failure');
          }

          final old = anySource
              ? service.downloadContentToFileFromAny(
                  const [],
                  contentId,
                  path,
                  write: (_, _) async {},
                  close: oldClose,
                )
              : service.downloadContentToFile(
                  peer,
                  contentId,
                  path,
                  write: (_, _) async {},
                  close: oldClose,
                );
          await s.lookupEntered!.future;
          var newCloses = 0;
          expect(
            await service.downloadContentToFile(
              peer,
              contentId,
              path,
              write: (_, _) async {},
              close: () async {
                newCloses++;
              },
            ),
            ContentDownloadResult.requestedReoffer,
          );
          gate.complete();
          expect(await old, ContentDownloadResult.noOffer);
          expect(oldCloses, 1);
          expect(
            newCloses,
            0,
            reason: 'the replacement still owns its pending sink',
          );
          expect(
            await service.cancelContentDownload(contentId),
            path,
            reason: 'stale cleanup cannot erase an identical replacement path',
          );
          expect(newCloses, 1);
        },
      );
    }
  }

  test('no request leaves before its resume intent is committed', () async {
    s.entered = Completer<void>();
    final release = Completer<void>();
    s.release = release;
    var returned = false;
    final request = service.downloadContent(peer, cid(1)).then((r) {
      returned = true;
      return r;
    });
    await s.entered!.future;
    expect(returned, false);
    expect(transport.sends, 0);
    release.complete();
    expect(await request, ContentDownloadResult.requestedReoffer);
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    while (transport.sends == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(transport.sends, greaterThan(0));
    await restart();
    expect(await service.pendingAutoResumeContentIds(), [cid(1)]);
  });

  test(
    'refused final commit preserves old requests and the next write recovers',
    () async {
      await service.downloadContent(peer, cid(1));
      final before = await s.loadFile(registry);
      final sentBefore = transport.sends;
      (kv as _RefusedMetadata).refuse = true;
      await expectLater(
        service.downloadContent(peer, cid(2)),
        throwsStateError,
      );
      expect(transport.sends, sentBefore);
      expect(await s.loadFile(registry), before);
      expect(await service.pendingAutoResumeContentIds(), [cid(1)]);
      expect(errorJournal.entries.single.kind, 'download-resume-write');
      expect(errorJournal.entries.single.message, isNot(contains('secret')));
      (kv as _RefusedMetadata).refuse = false;
      await service.downloadContent(peer, cid(3));
      await restart();
      expect(
        await service.pendingAutoResumeContentIds(),
        unorderedEquals([cid(1), cid(3)]),
      );
    },
  );

  test(
    'legacy migration and cancellation never restore a retired request',
    () async {
      await s.putSetting(
        'pending_downloads',
        jsonEncode([
          for (var i = 0; i < 3; i++)
            {
              'cid': cid(i),
              'mode': 'store',
              'peers': [peer.hex],
              'at': DateTime.now().toIso8601String(),
            },
        ]),
      );
      expect(await service.pendingAutoResumeContentIds(), hasLength(3));
      await service.cancelContentDownload(cid(0));
      expect(await s.getSetting('pending_downloads'), 'file:v1');
      await restart();
      expect(
        await service.pendingAutoResumeContentIds(),
        unorderedEquals([cid(1), cid(2)]),
      );
      expect(await service.clearPendingDownloads(), 2);
      await restart();
      expect(await service.pendingAutoResumeContentIds(), isEmpty);
    },
  );

  for (final missing in [false, true]) {
    test(
      'an unreadable current registry is not replaced by a new request missing=$missing',
      () async {
        await s.putSetting('pending_downloads', 'file:v1');
        if (!missing) {
          await s.storeFile(
            registry,
            Uint8List.fromList(utf8.encode('{broken')),
          );
        }
        final before = await s.loadFile(registry);
        await expectLater(
          service.downloadContent(peer, cid(9)),
          throwsStateError,
        );
        expect(transport.sends, 0);
        expect(await s.loadFile(registry), before);
        final failure = errorJournal.entries.lastWhere(
          (entry) => entry.kind == 'download-resume-read',
        );
        expect(
          failure.type,
          missing ? '_IncompleteDownloadResumeRegistry' : 'FormatException',
        );
        // A transient read failure is not cached as a new empty registry.
        await s.storeFile(registry, Uint8List.fromList(utf8.encode('[]')));
        await service.downloadContent(peer, cid(9));
        await restart();
        expect(await service.pendingAutoResumeContentIds(), [cid(9)]);
      },
    );
  }

  test('resume read keeps errno and drops private exception data', () async {
    await service.downloadContent(peer, cid(1));
    final before = await s.loadFile(registry);
    await restart();
    s.readFailure = const FileSystemException(
      'PRIVATE_SOURCE_BYTES',
      '/private/PRIVATE_DESTINATION',
      OSError('PRIVATE_OS_MESSAGE', 13),
    );
    s.readFailureStack = StackTrace.fromString(
      '#0 fixture (package:xveil/data/storage/hidden_volume_storage.dart:10:2)\n'
      '#1 private (/private/PRIVATE_SOURCE.dart:20:3)',
    );
    final sent = transport.sends;
    await expectLater(service.downloadContent(peer, cid(2)), throwsStateError);
    expect(transport.sends, sent);
    final failure = errorJournal.entries.lastWhere(
      (entry) => entry.kind == 'download-resume-read',
    );
    expect(failure.type, 'FileSystemException');
    expect(failure.numericCode, 13);
    expect(failure.frames, [
      'package:xveil/data/storage/hidden_volume_storage.dart:10:2',
    ]);
    expect(failure.message, isNot(contains('PRIVATE_')));
    expect(jsonEncode(failure.toJson()), isNot(contains('PRIVATE_')));
    s.readFailure = null;
    s.readFailureStack = null;
    expect(await s.loadFile(registry), before);
    await service.downloadContent(peer, cid(3));
    await restart();
    expect(
      await service.pendingAutoResumeContentIds(),
      unorderedEquals([cid(1), cid(3)]),
    );
  });

  test(
    'cancel during a held intent write cannot start a late plaintext pull',
    () async {
      s.entered = Completer<void>();
      final release = Completer<void>();
      s.release = release;
      var closes = 0;
      final request = service.downloadContentToFile(
        peer,
        cid(1),
        'fixture-output.bin',
        write: (_, _) async => fail('a cancelled pull wrote to the sink'),
        close: () async => closes++,
      );
      await s.entered!.future;
      final cancel = service.cancelContentDownload(cid(1));
      release.complete();
      expect(await request, ContentDownloadResult.noOffer);
      await cancel;
      expect(transport.sends, 0);
      expect(closes, 1);
      await restart();
      expect(await service.pendingAutoResumeContentIds(), isEmpty);
    },
  );
}
