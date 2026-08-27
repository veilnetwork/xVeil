import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/transcription_controller.dart';
import 'package:xveil/state/translation_controller.dart';

/// A reading of a message is the message.
///
/// Both controllers hand a body to an engine that takes as long as it takes,
/// and both read the storage provider AGAIN when it comes back. An all-online
/// switch in between — which `_activateOnline` performs with no teardown —
/// wrote A's message, in another language, and the words spoken in A's voice
/// note, into B's storage; both survive the lock there (report17 XV17-H4).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<HiddenVolumeStorage> opened(String password) async {
    final backing = FakeKvLogStore();
    final storage = HiddenVolumeStorage(
      ({required Uint8List password, required bool create}) => backing,
    );
    await storage.open(password: password, createIfMissing: true);
    return storage;
  }

  // The cache keys both controllers compute — deterministic, so asking a
  // storage for exactly these is asking whether the reading landed in it.
  const translationKey = 'msg.translation.v1:en:m1';
  const transcriptKey = 'voice.transcript.v3:ru:clip';

  test('a translation that finishes after the switch stays with A', () async {
    final a = await opened('a');
    final b = await opened('b');
    var active = a;

    final engineRan = Completer<void>();
    final release = Completer<String?>();

    final container = ProviderContainer(
      overrides: [
        storageProvider.overrideWith((ref) => active),
        textTranslatorProvider.overrideWithValue((
          body, {
          required String from,
          required String to,
        }) {
          engineRan.complete();
          return release.future;
        }),
      ],
    );
    addTearDown(container.dispose);

    final ctrl = container.read(translationControllerProvider.notifier);
    final running = ctrl.translate('m1', 'секрет A', to: 'en');
    await engineRan.future;

    // The identity moves while the engine is still working.
    active = b;
    container.invalidate(storageProvider);
    container.read(translationControllerProvider);

    release.complete("A's secret");
    await running;

    expect(
      await b.getSetting(translationKey),
      isNull,
      reason: "A's message, translated, was written into B's storage",
    );
    expect(
      container.read(translationControllerProvider)['m1']?.text,
      isNull,
      reason: "and shown on B's screen",
    );
    // It did land where it belongs.
    expect(await a.getSetting(translationKey), "A's secret");
  });

  test('a transcript that finishes after the switch stays with A', () async {
    final a = await opened('a');
    final b = await opened('b');
    await a.storeFile('clip', Uint8List.fromList([1, 2, 3]), name: 'v.opus');
    var active = a;

    final whisperRan = Completer<void>();
    final release = Completer<String?>();

    final container = ProviderContainer(
      overrides: [
        storageProvider.overrideWith((ref) => active),
        voiceTranscriberProvider.overrideWithValue((bytes, {lang = 'auto'}) {
          whisperRan.complete();
          return release.future;
        }),
      ],
    );
    addTearDown(container.dispose);

    final ctrl = container.read(transcriptionControllerProvider.notifier);
    final running = ctrl.transcribe('m1', 'clip', chosenLang: 'ru');
    await whisperRan.future;

    active = b;
    container.invalidate(storageProvider);
    container.read(transcriptionControllerProvider);

    release.complete('сказано под A');
    await running;

    expect(
      await b.getSetting(transcriptKey),
      isNull,
      reason: "the words in A's voice note were written into B's storage",
    );
    expect(
      container.read(transcriptionControllerProvider)['m1']?.text,
      isNull,
      reason: "and shown on B's screen",
    );
    expect(await a.getSetting(transcriptKey), 'сказано под A');
  });

  test('a remembered miss does not follow the identity', () async {
    // `_probed` is a fact about ONE store: "there is nothing here for this
    // message". Carried into B, it hides a translation B's store does have.
    final a = await opened('a');
    final b = await opened('b');
    var active = a;

    final container = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => active)],
    );
    addTearDown(container.dispose);

    final ctrl = container.read(translationControllerProvider.notifier);
    await ctrl.loadCached('m1', to: 'en'); // a miss, remembered
    expect(container.read(translationControllerProvider)['m1']?.text, isNull);

    await b.putSetting('msg.translation.v1:en:m1', "B's own reading");
    active = b;
    container.invalidate(storageProvider);
    container.read(translationControllerProvider);
    await container
        .read(translationControllerProvider.notifier)
        .loadCached('m1', to: 'en');

    expect(
      container.read(translationControllerProvider)['m1']?.text,
      "B's own reading",
      reason: "a miss recorded against A's store hid B's own translation",
    );
  });
}
