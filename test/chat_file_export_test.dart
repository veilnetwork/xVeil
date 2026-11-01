import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/document_export.dart';
import 'package:xveil/domain/chat_file_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(documentExportChannel, null);
  });

  Future<bool> save({
    int size = 17,
    Future<List<int>?> Function(int, int)? read,
    bool Function()? owner,
  }) => exportChatFile(
    name: 'fixture.bin',
    size: size,
    read: read ?? (offset, want) async => List.filled(want, 42),
    stillOurs: owner ?? () => true,
  );

  test(
    'Android large attachment uses picker, bounded writes and awaited close',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final entered = Completer<void>(), release = Completer<void>();
      final actual = BytesBuilder();
      var finished = false;
      messenger.setMockMethodCallHandler(documentExportChannel, (call) async {
        if (call.method == 'open') return {'id': 'opaque'};
        if (call.method == 'write') {
          final bytes = (call.arguments as Map)['bytes'] as Uint8List;
          expect(bytes.length, lessThanOrEqualTo(kDocumentExportChunkBytes));
          actual.add(bytes);
        } else if (call.method == 'finish') {
          entered.complete();
          await release.future;
          finished = true;
        } else {
          fail('unexpected ${call.method}');
        }
        return null;
      });
      final expected = Uint8List.fromList(
        List.generate(4 * 1024 * 1024 + 13, (i) => i % 251),
      );
      var done = false;
      final saving =
          save(
            size: expected.length,
            read: (offset, want) async =>
                Uint8List.sublistView(expected, offset, offset + want),
          ).then((saved) {
            done = true;
            return saved;
          });
      await entered.future;
      expect(done, isFalse);
      expect(actual.takeBytes(), orderedEquals(expected));
      release.complete();
      expect(await saving, isTrue);
      expect(finished, isTrue);
    },
  );

  test('cancelled picker does not read or report saved', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(
      documentExportChannel,
      (_) async => null,
    );
    expect(
      await save(
        read: (_, _) async {
          fail('read after cancel');
        },
      ),
      isFalse,
    );
  });

  for (final stage in ['open', 'write', 'finish']) {
    test(
      'provider permission refusal at $stage survives anonymous classification',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        var aborted = false;
        messenger.setMockMethodCallHandler(documentExportChannel, (call) async {
          if (call.method == stage) {
            throw PlatformException(
              code: 'document_export_permission',
              message: 'private/path/private-account',
              details: 'content://private',
            );
          }
          if (call.method == 'open') return {'id': 'opaque'};
          if (call.method == 'abort') aborted = true;
          return null;
        });
        try {
          await save();
          fail('must refuse');
        } on DocumentExportException catch (error) {
          expect(error.permissionDenied, isTrue);
          expect(error.toString(), isNot(contains('private')));
        }
        expect(aborted, stage != 'open');
      },
    );
  }

  test(
    'short read never finishes and aborts the incomplete document',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(documentExportChannel, (call) async {
        calls.add(call.method);
        return call.method == 'open' ? {'id': 'opaque'} : null;
      });
      await expectLater(
        save(read: (_, _) async => null),
        throwsA(isA<DocumentExportException>()),
      );
      expect(calls, ['open', 'abort']);
    },
  );

  test(
    'switch during picker or source read exports no bytes of either identity',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      for (final duringRead in [false, true]) {
        var owner = true;
        final calls = <String>[];
        messenger.setMockMethodCallHandler(documentExportChannel, (call) async {
          calls.add(call.method);
          if (call.method == 'open') {
            if (!duringRead) owner = false;
            return {'id': 'opaque'};
          }
          return null;
        });
        await expectLater(
          save(
            owner: () => owner,
            read: (_, want) async {
              owner = false;
              return List.filled(want, 42);
            },
          ),
          throwsA(isA<DocumentExportException>()),
        );
        expect(calls, ['open', 'abort']);
      }
    },
  );

  test(
    'full disk and generic provider refusal are not mislabeled permission',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(documentExportChannel, (_) async {
        throw PlatformException(
          code: 'document_export_open',
          message: 'private',
        );
      });
      await expectLater(
        save(),
        throwsA(
          isA<DocumentExportException>().having(
            (e) => e.permissionDenied,
            'permission',
            isFalse,
          ),
        ),
      );
    },
  );
}
