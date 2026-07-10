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
  return ProviderContainer(overrides: [
    singleSpaceStorageProvider.overrideWithValue(storage),
    voiceTranscriberProvider.overrideWithValue(transcribe),
  ]);
}

void main() {
  test('transcribe: running -> done, text cached + reloadable', () async {
    var calls = 0;
    final c = await _c(transcribe: (bytes, {lang = 'auto'}) async {
      calls++;
      return 'привет мир';
    });
    addTearDown(c.dispose);
    final ctrl = c.read(transcriptionControllerProvider.notifier);

    await ctrl.transcribe('m1', 'vk');
    expect(ctrl.entryFor('m1').isDone, isTrue);
    expect(ctrl.entryFor('m1').text, 'привет мир');
    expect(calls, 1);

    // A second controller (fresh state) loads the cached transcript, no re-run.
    final ctrl2 = ProviderContainer(overrides: [
      singleSpaceStorageProvider
          .overrideWithValue(c.read(singleSpaceStorageProvider)),
      voiceTranscriberProvider.overrideWithValue((b, {lang = 'auto'}) async {
        calls++;
        return 'SHOULD NOT RUN';
      }),
    ]);
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

  test('null transcript -> failed, re-tappable', () async {
    var calls = 0;
    final c = await _c(transcribe: (b, {lang = 'auto'}) async {
      calls++;
      return calls == 1 ? null : 'ok now';
    });
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
    final c = await _c(transcribe: (b, {lang = 'auto'}) async {
      calls++;
      return 'text';
    });
    addTearDown(c.dispose);
    final ctrl = c.read(transcriptionControllerProvider.notifier);
    await ctrl.transcribe('m1', 'vk');
    await ctrl.transcribe('m1', 'vk'); // done → no-op
    expect(calls, 1);
  });
}
