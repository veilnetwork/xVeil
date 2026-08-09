import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/transcription_controller.dart';

import 'support/fake_hv_container.dart';

Future<ProviderContainer> _c({
  required Future<String?> Function(Uint8List, {String lang}) transcribe,
}) async {
  final storage = FakeHvContainer().storage();
  await storage.open(password: 'pw', createIfMissing: true);
  await storage.storeFile('vk', Uint8List.fromList([1, 2, 3]), name: 'v.opus');
  return ProviderContainer(
    overrides: [
      singleSpaceStorageProvider.overrideWithValue(storage),
      voiceTranscriberProvider.overrideWithValue(transcribe),
    ],
  );
}

void main() {
  test('transcribe: running -> done, text cached + reloadable', () async {
    var calls = 0;
    final c = await _c(
      transcribe: (bytes, {lang = 'auto'}) async {
        calls++;
        return 'привет мир';
      },
    );
    addTearDown(c.dispose);
    final ctrl = c.read(transcriptionControllerProvider.notifier);

    await ctrl.transcribe('m1', 'vk');
    expect(ctrl.entryFor('m1').isDone, isTrue);
    expect(ctrl.entryFor('m1').text, 'привет мир');
    expect(calls, 1);

    // A second controller (fresh state) loads the cached transcript, no re-run.
    final ctrl2 = ProviderContainer(
      overrides: [
        singleSpaceStorageProvider.overrideWithValue(
          c.read(singleSpaceStorageProvider),
        ),
        voiceTranscriberProvider.overrideWithValue((b, {lang = 'auto'}) async {
          calls++;
          return 'SHOULD NOT RUN';
        }),
      ],
    );
    addTearDown(ctrl2.dispose);
    await ctrl2
        .read(transcriptionControllerProvider.notifier)
        .loadCached('m1', 'vk');
    expect(
      ctrl2.read(transcriptionControllerProvider.notifier).entryFor('m1').text,
      'привет мир',
    );
    expect(calls, 1); // cache hit — transcriber not called again
  });

  test('an explicit language wins over the sender\'s tag, and asking again in '
      'another language re-runs', () async {
    // Auto-detect is unreliable on the quantized model and the sender's own tag
    // can be wrong — a note recorded in a language its owner's device does not
    // announce. So a person must be able to say "read this as X", and be able
    // to change their mind: keying the cache by clip alone handed the first
    // answer back forever, which made a second choice impossible to act on.
    final seen = <String>[];
    final c = await _c(
      transcribe: (bytes, {lang = 'auto'}) async {
        seen.add(lang);
        return 'text-in-$lang';
      },
    );
    addTearDown(c.dispose);
    final ctrl = c.read(transcriptionControllerProvider.notifier);

    await ctrl.transcribe('m1', 'vk', senderLang: 'ru', chosenLang: 'de');
    expect(seen, ['de'], reason: "the pick beats the sender's tag");
    expect(ctrl.entryFor('m1').text, 'text-in-de');

    // Same language again: nothing to redo.
    await ctrl.transcribe('m1', 'vk', chosenLang: 'de');
    expect(seen, ['de'], reason: 'asking for what is already there is free');

    // A different language: run again and replace the shown text.
    await ctrl.transcribe('m1', 'vk', chosenLang: 'fr');
    expect(seen, ['de', 'fr']);
    expect(ctrl.entryFor('m1').text, 'text-in-fr');
    expect(ctrl.entryFor('m1').lang, 'fr');
  });

  test('each language keeps its own cached text', () async {
    var calls = 0;
    final c = await _c(
      transcribe: (bytes, {lang = 'auto'}) async {
        calls++;
        return 'text-in-$lang';
      },
    );
    addTearDown(c.dispose);
    await c
        .read(transcriptionControllerProvider.notifier)
        .transcribe('m1', 'vk', chosenLang: 'es');
    expect(calls, 1);

    // A fresh controller asked for the SAME language reads the cache; asked for
    // another one it must not be handed the first language's text.
    final fresh = ProviderContainer(
      overrides: [
        singleSpaceStorageProvider.overrideWithValue(
          c.read(singleSpaceStorageProvider),
        ),
        voiceTranscriberProvider.overrideWithValue((b, {lang = 'auto'}) async {
          calls++;
          return 'text-in-$lang';
        }),
      ],
    );
    addTearDown(fresh.dispose);
    final ctrl = fresh.read(transcriptionControllerProvider.notifier);
    await ctrl.loadCached('m1', 'vk', senderLang: 'es');
    expect(ctrl.entryFor('m1').text, 'text-in-es');
    expect(calls, 1, reason: 'cache hit for the language it was made in');

    await ctrl.transcribe('m1', 'vk', chosenLang: 'it');
    expect(ctrl.entryFor('m1').text, 'text-in-it');
    expect(calls, 2, reason: 'another language is another answer');

    // Both answers must survive each other. Keyed by the clip alone, the second
    // write lands on top of the first and asking for the first language again
    // hands back the second one's text.
    final again = ProviderContainer(
      overrides: [
        singleSpaceStorageProvider.overrideWithValue(
          c.read(singleSpaceStorageProvider),
        ),
        voiceTranscriberProvider.overrideWithValue((b, {lang = 'auto'}) async {
          calls++;
          return 'FRESH RUN';
        }),
      ],
    );
    addTearDown(again.dispose);
    final back = again.read(transcriptionControllerProvider.notifier);
    await back.loadCached('m1', 'vk', senderLang: 'es');
    expect(
      back.entryFor('m1').text,
      'text-in-es',
      reason: 'the Spanish reading is still its own cache entry',
    );
    expect(calls, 2, reason: 'and it came from cache, not a re-run');
  });

  test('null transcript -> failed, re-tappable', () async {
    var calls = 0;
    final c = await _c(
      transcribe: (b, {lang = 'auto'}) async {
        calls++;
        return calls == 1 ? null : 'ok now';
      },
    );
    addTearDown(c.dispose);
    final ctrl = c.read(transcriptionControllerProvider.notifier);

    await ctrl.transcribe('m1', 'vk');
    expect(ctrl.entryFor('m1').phase, TranscriptPhase.failed);
    // Failed is neither running nor done → a second tap re-runs.
    await ctrl.transcribe('m1', 'vk');
    expect(ctrl.entryFor('m1').isDone, isTrue);
    expect(ctrl.entryFor('m1').text, 'ok now');
  });

  test('done/running is not re-run', () async {
    var calls = 0;
    final c = await _c(
      transcribe: (b, {lang = 'auto'}) async {
        calls++;
        return 'text';
      },
    );
    addTearDown(c.dispose);
    final ctrl = c.read(transcriptionControllerProvider.notifier);
    await ctrl.transcribe('m1', 'vk');
    await ctrl.transcribe('m1', 'vk'); // done → no-op
    expect(calls, 1);
  });
}
