import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/veil_bundle.dart';
import 'package:xveil/data/translation_model_store.dart';
import 'package:xveil/state/translation_controller.dart';
import 'package:xveil/state/translation_model_controller.dart';

void main() {
  late Directory tmp;
  late Directory root;
  late Directory pairDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xveil-models-ctl');
    root = Directory('${tmp.path}/translate')..createSync();
    pairDir = Directory('${tmp.path}/source-ru-en')..createSync();
    for (final name in kPairFiles) {
      File('${pairDir.path}/$name').writeAsStringSync('$name payload');
    }
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<File> bundle({String from = 'ru', String to = 'en'}) async {
    final out = File('${tmp.path}/$from-$to.veiltranslate');
    await writeBundle(
      sourceDir: pairDir,
      pair: TranslationPair(from, to),
      out: out,
    );
    return out;
  }

  /// A container whose models root is the temp directory, and which counts how
  /// often the engine was asked to look again.
  ({ProviderContainer container, List<int> resolves}) build() {
    final resolves = <int>[0];
    final container = ProviderContainer(
      overrides: [
        translationModelsRootProvider.overrideWithValue(() async => root),
        // Replaces the body, not the identity: ref.invalidate() in the
        // controller still targets this provider, so the counter measures the
        // real call.
        translationEnginesProvider.overrideWith((ref) async {
          resolves[0]++;
          return null;
        }),
      ],
    );
    addTearDown(container.dispose);
    // Something must be listening, or Riverpod never builds the provider and
    // invalidating it is unobservable. In the app that listener is
    // textTranslatorProvider; here it has to be explicit, or this test would
    // measure nothing and say so with a zero.
    container.listen(translationEnginesProvider, (_, _) {}, fireImmediately: true);
    return (container: container, resolves: resolves);
  }

  /// Drive the controller's initial refresh to completion instead of racing
  /// it. build() starts one in a microtask; awaiting the same method is
  /// deterministic, where a delay(zero) is a guess that fails on a slower
  /// machine and passes on this one.
  Future<TranslationModelsState> settled(ProviderContainer c) async {
    await c.read(translationModelsControllerProvider.notifier).refresh();
    return c.read(translationModelsControllerProvider);
  }

  /// Riverpod rebuilds lazily: invalidate() marks the provider dirty and
  /// nothing recomputes until something reads it. Reading is what a widget
  /// watching it would do, so the count only means anything after this.
  Future<int> resolvesAfterRead(
    ({ProviderContainer container, List<int> resolves}) t,
  ) async {
    await t.container.read(translationEnginesProvider.future);
    return t.resolves[0];
  }

  group('listing', () {
    test('an empty root has nothing installed', () async {
      final t = build();
      final state = await settled(t.container);
      expect(state.installed, isEmpty);
      expect(state.hasAny, isFalse);
    });

    test('a complete pair is listed, an incomplete one is not', () async {
      for (final name in kPairFiles) {
        File('${root.path}/ru-en/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync('x');
      }
      // Four files out of five: the engine would refuse this, so listing it as
      // installed would have a person deleting the wrong thing to fix it.
      for (final name in kPairFiles.where((n) => n != 'target.spm')) {
        File('${root.path}/de-en/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync('x');
      }
      Directory('${root.path}/notapair').createSync(recursive: true);

      final t = build();
      final state = await settled(t.container);
      expect(state.installed.map((p) => p.id), equals(['ru-en']));
    });
  });

  group('importing', () {
    test('a good bundle installs, and the engine is told to look again',
        () async {
      final t = build();
      await settled(t.container);
      final before = await resolvesAfterRead(t);

      final ok = await t.container
          .read(translationModelsControllerProvider.notifier)
          .importBundle((await bundle()).path);

      expect(ok, isTrue);
      final state = t.container.read(translationModelsControllerProvider);
      expect(state.installed.map((p) => p.id), equals(['ru-en']));
      expect(state.lastInstalled?.id, 'ru-en');
      expect(state.error, isNull);
      expect(state.progress, isNull, reason: 'progress is cleared when it ends');
      // Without this the freshly installed model stays invisible until the
      // next launch.
      expect(await resolvesAfterRead(t), greaterThan(before));
    });

    test('a bundle that is not one fails with a reason, and installs nothing',
        () async {
      final junk = File('${tmp.path}/photo.jpg')
        ..writeAsBytesSync(utf8.encode('not a bundle at all'));
      final t = build();
      await settled(t.container);

      final ok = await t.container
          .read(translationModelsControllerProvider.notifier)
          .importBundle(junk.path);

      expect(ok, isFalse);
      final state = t.container.read(translationModelsControllerProvider);
      expect(state.phase, TranslationImportPhase.failed);
      expect(state.error, isNotNull);
      expect(state.error, isNotEmpty);
      expect(state.installed, isEmpty);
      expect(root.listSync().where((e) => e.path.contains('incoming')), isEmpty);
    });

    test('the error is cleared when the next attempt starts', () async {
      final t = build();
      await settled(t.container);
      final notifier =
          t.container.read(translationModelsControllerProvider.notifier);

      await notifier.importBundle('${tmp.path}/nothing-here');
      expect(
        t.container.read(translationModelsControllerProvider).error,
        isNotNull,
      );

      await notifier.importBundle((await bundle()).path);
      final state = t.container.read(translationModelsControllerProvider);
      expect(state.error, isNull, reason: 'a stale failure must not sit under a success');
      expect(state.phase, TranslationImportPhase.idle);
    });

    test('two directions coexist', () async {
      final t = build();
      await settled(t.container);
      final notifier =
          t.container.read(translationModelsControllerProvider.notifier);

      expect(await notifier.importBundle((await bundle()).path), isTrue);
      expect(
        await notifier.importBundle(
          (await bundle(from: 'en', to: 'ru')).path,
        ),
        isTrue,
      );
      expect(
        t.container.read(translationModelsControllerProvider).installed
            .map((p) => p.id),
        equals(['en-ru', 'ru-en']),
      );
    });
  });

  group('passing one on', () {
    test('an exported pair installs on the other side, byte for byte', () async {
      final t2 = build();
      await settled(t2.container);
      final notifier =
          t2.container.read(translationModelsControllerProvider.notifier);
      await notifier.importBundle((await bundle()).path);

      final out = '${tmp.path}/handed-over.veiltranslate';
      final written = await notifier.exportPair(
        const TranslationPair('ru', 'en'),
        out,
      );
      expect(written, out);

      // The real guarantee: what came out installs, and the files match. An
      // export that produced a file nobody could install would look identical
      // from this side.
      final theirs = Directory('${tmp.path}/theirs')..createSync();
      final result = await installBundle(File(out), modelsRoot: theirs);
      expect(result.succeeded, isTrue, reason: result.error);
      for (final name in kPairFiles) {
        expect(
          File('${theirs.path}/ru-en/$name').readAsBytesSync(),
          equals(File('${pairDir.path}/$name').readAsBytesSync()),
          reason: name,
        );
      }
    });

    test('a direction that is not installed exports nothing', () async {
      final t2 = build();
      await settled(t2.container);
      final written = await t2.container
          .read(translationModelsControllerProvider.notifier)
          .exportPair(const TranslationPair('de', 'fr'), '${tmp.path}/no.bundle');
      expect(written, isNull);
      expect(File('${tmp.path}/no.bundle').existsSync(), isFalse);
    });
  });

  group('removing', () {
    test('takes the pair and tells the engine', () async {
      final t = build();
      await settled(t.container);
      final notifier =
          t.container.read(translationModelsControllerProvider.notifier);
      await notifier.importBundle((await bundle()).path);
      final before = await resolvesAfterRead(t);

      await notifier.remove(const TranslationPair('ru', 'en'));

      expect(
        t.container.read(translationModelsControllerProvider).installed,
        isEmpty,
      );
      expect(Directory('${root.path}/ru-en').existsSync(), isFalse);
      // A removed model that the engine still holds open is worse than one
      // that never installed: it keeps translating from a file that is gone.
      expect(await resolvesAfterRead(t), greaterThan(before));
    });

    test('removing something that is not there is not an error', () async {
      final t = build();
      await settled(t.container);
      await t.container
          .read(translationModelsControllerProvider.notifier)
          .remove(const TranslationPair('de', 'fr'));
      expect(
        t.container.read(translationModelsControllerProvider).installed,
        isEmpty,
      );
    });
  });
}
