import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/capture_output_file.dart';
import 'package:xveil/core/capture_resource_lifetime.dart';

class _Store implements CaptureOutputStore {
  bool refuse = false;
  int removes = 0;
  Completer<void>? gate;
  final entered = Completer<void>();
  @override
  Future<void> remove(String path) async {
    removes++;
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    if (refuse) throw FileSystemException('synthetic refusal', path);
    await const FileCaptureOutputStore().remove(path);
  }
}

void main() {
  late Directory fixture;
  late File output;
  late CaptureResourceLifetime lifetime;
  late _Store store;
  late CaptureOutputFile source;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('xveil-owned-output-');
    output = File('${fixture.path}/capture.bin')
      ..writeAsStringSync('synthetic bytes');
    lifetime = CaptureResourceLifetime.current();
    store = _Store();
    source = CaptureOutputFile(output.path, lifetime: lifetime, store: store);
  });
  tearDown(() async {
    store.refuse = false;
    if (store.gate != null && !store.gate!.isCompleted) store.gate!.complete();
    await source.retire();
    CaptureResourceLifetime.resetForTesting();
    fixture.deleteSync(recursive: true);
  });

  test('consumes once and deletes before returning to the caller', () async {
    expect(
      await source.use((path) async => File(path).readAsString()),
      'synthetic bytes',
    );
    expect(output.existsSync(), isFalse);
    expect(source.canUse, isFalse);
    await expectLater(
      source.use((_) async => fail('second consumer')),
      throwsA(isA<CaptureResourceRetirementFailure>()),
    );
    await lifetime.retire();
    expect(store.removes, 1);
  });

  test(
    'retirement joins accepted consumer before native file removal',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final reading = source.use((path) async {
        entered.complete();
        await release.future;
        return File(path).readAsString();
      });
      await entered.future;
      final retiring = lifetime.retire();
      try {
        await Future<void>(() {});
        expect(store.entered.isCompleted, isFalse);
        expect(output.existsSync(), isTrue);
        expect(source.canUse, isFalse);
      } finally {
        release.complete();
        expect(await reading, 'synthetic bytes');
        await retiring;
      }
      expect(output.existsSync(), isFalse);
      expect(store.removes, 1);
    },
  );

  test(
    'cleanup refusal does not repeat a successful consumer or forget its file',
    () async {
      var sends = 0;
      store.refuse = true;
      expect(await source.use((_) async => ++sends), 1);
      expect(output.existsSync(), isTrue);
      expect(source.canUse, isFalse);
      await expectLater(
        lifetime.retire(),
        throwsA(isA<CaptureResourceRetirementFailure>()),
      );
      store.refuse = false;
      await lifetime.retire();
      expect(output.existsSync(), isFalse);
      expect(sends, 1);
    },
  );

  test(
    'consumer failure still cleans the output and preserves the original failure',
    () async {
      final failure = StateError('synthetic consumer failure');
      await expectLater(
        source.use<void>((_) async => throw failure),
        throwsA(same(failure)),
      );
      expect(output.existsSync(), isFalse);
      await lifetime.retire();
    },
  );

  test(
    'concurrent deletion attempts join the same platform operation',
    () async {
      store.gate = Completer<void>();
      final first = source.retire();
      await store.entered.future;
      final second = source.retire();
      expect(store.removes, 1);
      store.gate!.complete();
      await Future.wait([first, second]);
      expect(store.removes, 1);
      expect(output.existsSync(), isFalse);
    },
  );
}
