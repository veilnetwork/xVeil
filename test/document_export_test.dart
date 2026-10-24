import 'dart:async';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_method_channel.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/document_export.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/data_transfer.dart';
import 'package:xveil/state/data_export.dart';
import 'package:xveil/state/data_export_destination.dart';

class _LocalPicker extends FilePickerPlatform {
  _LocalPicker(this.path);
  final String? path;
  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async => path;
}

class _HeldStorage extends HiddenVolumeStorage {
  _HeldStorage() : super.fromStore(FakeKvLogStore());
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<List<Conversation>> loadConversations() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return super.loadConversations();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final originalPicker = FilePickerPlatform.instance;
  const filename = 'fixture.xveilbk';
  final me = NodeId(Uint8List.fromList(List.filled(32, 1)));

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    FilePickerPlatform.instance = originalPicker;
    messenger.setMockMethodCallHandler(documentExportChannel, null);
  });

  Future<DataExporter> exporter({HiddenVolumeStorage? storage}) async {
    final s = storage ?? HiddenVolumeStorage.fromStore(FakeKvLogStore());
    final peer = NodeId(Uint8List.fromList(List.filled(32, 2)));
    await s.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    await s.appendMessage(
      Message(
        id: 'fixture',
        conversationId: peer.hex,
        direction: MessageDirection.outgoing,
        body: 'fixture message',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
        author: me.hex,
      ),
    );
    return DataExporter(storage: s, nodeIdHex: me.hex, syncedSettingKeys: {});
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('$platform: path-only pinned picker is a real regression premise', () {
      expect(
        () => MethodChannelFilePicker().saveFile(fileName: filename),
        throwsArgumentError,
      );
    });

    test(
      '$platform: cancelled native picker does not create an export',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        var calls = 0;
        messenger.setMockMethodCallHandler(documentExportChannel, (call) async {
          calls++;
          expect(call.method, 'open');
          return null;
        });
        final report = await exportDataArchive(
          exporter: await exporter(),
          name: filename,
          stillOurs: () => true,
          includeIdentity: false,
          includeFiles: false,
        );
        expect(report, isNull);
        expect(calls, 1);
      },
    );

    test(
      '$platform: real archive streams to provider and decodes after finish',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        final bytes = BytesBuilder();
        var finished = false;
        messenger.setMockMethodCallHandler(documentExportChannel, (call) async {
          if (call.method == 'open') return {'id': 'opaque-token'};
          final args = call.arguments as Map;
          expect(args['id'], 'opaque-token');
          if (call.method == 'write') {
            expect(
              (args['bytes'] as Uint8List).length,
              lessThanOrEqualTo(kDocumentExportChunkBytes),
            );
            bytes.add(args['bytes'] as Uint8List);
          } else if (call.method == 'finish') {
            finished = true;
          } else {
            fail('unexpected provider method ${call.method}');
          }
          return null;
        });
        final report = await exportDataArchive(
          exporter: await exporter(),
          name: filename,
          stillOurs: () => true,
          includeIdentity: false,
          includeFiles: false,
        );
        expect(finished, isTrue);
        expect(report!.bytes, bytes.length);
        final reader = await DataTransferReader.open(
          Stream.value(bytes.takeBytes()),
        );
        final records = await reader.records().toList();
        expect(records, isNotEmpty);
        expect(records.any((r) => r.kind == TransferRecordKind.sync), isTrue);
      },
    );
  }

  test(
    'native writer enforces bounded awaited chunks and refuses concurrent writes',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final entered = Completer<void>(), release = Completer<void>();
      final parts = <Uint8List>[];
      messenger.setMockMethodCallHandler(documentExportChannel, (call) async {
        if (call.method == 'open') return {'id': 'token'};
        if (call.method == 'write') {
          parts.add((call.arguments as Map)['bytes'] as Uint8List);
          if (parts.length == 1) {
            entered.complete();
            await release.future;
          }
        }
        return null;
      });
      final doc = (await openExportDocument(filename))!;
      final input = Uint8List.fromList(
        List.generate(kDocumentExportChunkBytes * 2 + 17, (i) => i % 251),
      );
      final writing = doc.write(input);
      await entered.future;
      expect(parts, hasLength(1));
      await expectLater(
        doc.write([1]),
        throwsA(isA<DocumentExportException>()),
      );
      await expectLater(doc.finish(), throwsA(isA<DocumentExportException>()));
      release.complete();
      await writing;
      expect(parts.map((p) => p.length), [
        kDocumentExportChunkBytes,
        kDocumentExportChunkBytes,
        17,
      ]);
      expect(parts.expand((p) => p).toList(), input);
      await doc.finish();
    },
  );

  for (final failing in ['open', 'write', 'finish']) {
    test(
      'provider $failing failure is anonymous, aborts and never returns success',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        var aborted = 0;
        messenger.setMockMethodCallHandler(documentExportChannel, (call) async {
          if (call.method == 'abort') {
            aborted++;
            return null;
          }
          if (call.method == failing) {
            throw PlatformException(
              code: 'provider_io',
              message: 'content://provider/private-account/very-private-name',
              details: {'key': 'not-for-the-report'},
            );
          }
          if (call.method == 'open') return {'id': 'token'};
          return null;
        });
        Object? observed;
        try {
          await exportDataArchive(
            exporter: await exporter(),
            name: filename,
            stillOurs: () => true,
            includeIdentity: false,
            includeFiles: false,
          );
          fail('a failed provider must not return a completed report');
        } catch (e) {
          observed = e;
        }
        expect(observed, isA<DocumentExportException>());
        expect(observed.toString(), isNot(contains('private-account')));
        expect(observed.toString(), isNot(contains('not-for-the-report')));
        expect(aborted, failing == 'open' ? 0 : 1);
      },
    );
  }

  test(
    'lease lost after selection aborts before the first archive byte',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      var ours = true, writes = 0, aborts = 0;
      messenger.setMockMethodCallHandler(documentExportChannel, (call) async {
        if (call.method == 'open') {
          ours = false;
          return {'id': 'token'};
        }
        if (call.method == 'write') writes++;
        if (call.method == 'abort') aborts++;
        return null;
      });
      await expectLater(
        exportDataArchive(
          exporter: await exporter(),
          name: filename,
          stillOurs: () => ours,
          includeIdentity: false,
          includeFiles: false,
        ),
        throwsA(isA<DataExportCancelled>()),
      );
      expect(writes, 0);
      expect(aborts, 1);
    },
  );

  test(
    'lease lost during output stops at the acknowledged block and aborts',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      var ours = true, writes = 0, aborts = 0, finishes = 0;
      messenger.setMockMethodCallHandler(documentExportChannel, (call) async {
        if (call.method == 'open') return {'id': 'token'};
        if (call.method == 'write') {
          writes++;
          ours = false;
        }
        if (call.method == 'abort') aborts++;
        if (call.method == 'finish') finishes++;
        return null;
      });
      await expectLater(
        exportDataArchive(
          exporter: await exporter(),
          name: filename,
          stillOurs: () => ours,
          includeIdentity: false,
          includeFiles: false,
        ),
        throwsA(isA<DataExportCancelled>()),
      );
      expect(writes, 1);
      expect(aborts, 1);
      expect(finishes, 0);
    },
  );

  test(
    'route cancellation closes destination while source read remains blocked',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      var aborts = 0;
      messenger.setMockMethodCallHandler(documentExportChannel, (call) async {
        if (call.method == 'open') return {'id': 'token'};
        if (call.method == 'abort') aborts++;
        return null;
      });
      final source = _HeldStorage();
      final cancellation = DataExportCancellation();
      final future = exportDataArchive(
        exporter: await exporter(storage: source),
        name: filename,
        stillOurs: () => true,
        includeIdentity: false,
        includeFiles: false,
        cancellation: cancellation,
      );
      await source.entered.future;
      await cancellation.cancel();
      expect(
        aborts,
        1,
        reason: 'do not wait for storage to release the native handle',
      );
      final assertion = expectLater(
        future,
        throwsA(isA<DataExportCancelled>()),
      );
      source.release.complete();
      await assertion;
      expect(aborts, 1, reason: 'abort is idempotent');
    },
  );

  test(
    'desktop abort preserves old target; finished stream replaces it completely',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final dir = await Directory.systemTemp.createTemp('xveil-export-');
      addTearDown(() => dir.delete(recursive: true));
      final target = File('${dir.path}/archive.xveilbk');
      await target.writeAsString('existing');
      FilePickerPlatform.instance = _LocalPicker(target.path);
      var doc = (await openExportDocument(filename))!;
      await doc.write([1, 2, 3]);
      expect(await target.readAsString(), 'existing');
      await doc.abort();
      expect(await target.readAsString(), 'existing');
      expect(await dir.list().length, 1);
      doc = (await openExportDocument(filename))!;
      await doc.write([4, 5]);
      await doc.write([6]);
      await doc.finish();
      await doc.abort();
      expect(await target.readAsBytes(), [4, 5, 6]);
      expect(await dir.list().length, 1);
    },
  );
}
