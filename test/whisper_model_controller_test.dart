import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:xveil/data/veil_bundle.dart';
import 'package:xveil/data/translation_model_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/state/identity_scoped_prefs.dart';
import 'package:xveil/state/whisper_model_controller.dart';

/// A store that answers on command, so the controller's own decisions are what
/// the test observes — not a network.
class _ScriptedStore implements WhisperModelStore {
  bool installedNow = false;
  int pendingOnDisk = 0;
  int downloads = 0;
  int removals = 0;
  Completer<WhisperModelDownload>? pending;
  bool Function()? cancelProbe;
  void Function(double progress)? lastProgress;

  @override
  Future<bool> isInstalled() async => installedNow;

  @override
  Future<File?> installed() async => null;

  @override
  Future<int> pendingBytes() async => pendingOnDisk;

  @override
  Future<void> remove() async {
    removals++;
    installedNow = false;
  }

  @override
  Future<WhisperModelDownload> download({
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
    Uri? from,
  }) {
    downloads++;
    lastProgress = onProgress;
    cancelProbe = isCancelled;
    return (pending = Completer<WhisperModelDownload>()).future;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  /// Where a .veilaudio bundle installs to. Set by the tests that use it.
  Directory? root;

  @override
  Future<Directory> modelDirectory() async => root!;
}

void main() {
  late _ScriptedStore store;
  late ProviderContainer container;

  setUp(() {
    // No stored answer = no consent, which is the shipped default.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    store = _ScriptedStore();
    container = ProviderContainer(
      overrides: [
        whisperModelStoreProvider.overrideWithValue(store),
        // A unit test has no native library; without this the background
        // fetch correctly refuses and every assertion below would be about
        // that refusal instead of about the fetch.
        whisperNativeProbeProvider.overrideWithValue(() async => true),
      ],
    );
    addTearDown(container.dispose);
  });

  WhisperModelState read() => container.read(whisperModelControllerProvider);
  WhisperModelController ctrl() =>
      container.read(whisperModelControllerProvider.notifier);

  test('starts absent and finds an already-installed model', () async {
    expect(read().phase, WhisperModelPhase.absent);
    store.installedNow = true;
    await ctrl().refresh();
    expect(read().phase, WhisperModelPhase.ready);
  });

  test('pressing twice does NOT start two 57 MiB transfers', () async {
    // The whole reason the busy state exists. A second tap while the first is
    // in flight is the most ordinary thing a person does on a slow connection.
    unawaited(ctrl().download());
    await Future<void>.delayed(Duration.zero);
    expect(read().isBusy, isTrue);

    final second = await ctrl().download();
    expect(second, isFalse, reason: 'the second press is refused');
    expect(store.downloads, 1);

    store.pending!.complete(const WhisperModelDownload.ok('/tmp/model'));
    await Future<void>.delayed(Duration.zero);
    expect(read().phase, WhisperModelPhase.ready);
  });

  test(
    'a failure is a state the person can act on, not a silent nothing',
    () async {
      unawaited(ctrl().download());
      await Future<void>.delayed(Duration.zero);
      store.pending!.complete(
        const WhisperModelDownload.failed('server said 503'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(read().phase, WhisperModelPhase.failed);
      expect(read().error, contains('503'));
      expect(read().isBusy, isFalse, reason: 'and it can be retried');
    },
  );

  test(
    'progress reaches the state while it is running, and stops after',
    () async {
      unawaited(ctrl().download());
      await Future<void>.delayed(Duration.zero);
      store.lastProgress!(0.5);
      expect(read().progress, 0.5);

      store.pending!.complete(const WhisperModelDownload.ok('/tmp/model'));
      await Future<void>.delayed(Duration.zero);
      // A late callback from a finished transfer must not drag the UI back into
      // "downloading" — the sink can outlive the await in real HTTP.
      store.lastProgress!(0.9);
      expect(read().phase, WhisperModelPhase.ready);
    },
  );

  test('a refresh during a download does not clobber it', () async {
    unawaited(ctrl().download());
    await Future<void>.delayed(Duration.zero);
    await ctrl().refresh();
    expect(read().isBusy, isTrue, reason: 'a stale probe must not win');
  });

  test('removing puts it back to absent', () async {
    store.installedNow = true;
    await ctrl().refresh();
    expect(read().phase, WhisperModelPhase.ready);

    await ctrl().remove();
    expect(store.removals, 1);
    expect(read().phase, WhisperModelPhase.absent);
  });

  test('removing is refused while a download is running', () async {
    // Deleting the target from under an in-flight write is a way to end up
    // with neither.
    unawaited(ctrl().download());
    await Future<void>.delayed(Duration.zero);
    await ctrl().remove();
    expect(store.removals, 0);
    expect(read().isBusy, isTrue);
  });

  test('cancel reaches the running transfer', () async {
    unawaited(ctrl().download());
    await Future<void>.delayed(Duration.zero);
    expect(store.cancelProbe!(), isFalse, reason: 'not asked for yet');

    ctrl().cancel();
    expect(
      store.cancelProbe!(),
      isTrue,
      reason: 'the store consults this between chunks',
    );
  });

  test('a cancelled download returns to the offer, not to an error', () async {
    unawaited(ctrl().download());
    await Future<void>.delayed(Duration.zero);
    ctrl().cancel();
    store.pendingOnDisk = (WhisperModelStore.expectedBytes * 0.4).round();
    store.pending!.complete(const WhisperModelDownload.cancelled());
    await Future<void>.delayed(Duration.zero);

    expect(read().phase, WhisperModelPhase.absent);
    expect(read().error, isNull, reason: 'nobody made a mistake');
    expect(read().resumeFraction, closeTo(0.4, 0.01));
  });

  test('cancel does nothing when nothing is running', () async {
    ctrl().cancel();
    expect(read().phase, WhisperModelPhase.absent);
  });

  group('fetching it in the background, once agreed to', () {
    // Nobody should have to know a speech model exists — but fetching ~57 MiB
    // from a public CDN the moment a session opens tells that CDN this device
    // runs xVeil, from this IP, at this minute, with a traffic shape
    // distinctive enough to recognise again (audit XV-05). So the automatic
    // path waits for an answer, and tapping Download in Settings or under a
    // voice message IS that answer.

    /// Grant what a deliberate Download would have granted.
    Future<void> agree() async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        identityScopedPrefKey(kWhisperAutoFetchPrefKey): true,
      });
    }

    /// The background path awaits a probe, then a disk check, then starts the
    /// download — several hops, so one microtask is not enough to see it.
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('nothing is fetched until the person has agreed', () async {
      await ctrl().ensureDownloadedInBackground();
      await settle();
      expect(
        store.downloads,
        0,
        reason: 'an unprompted CDN fetch announces the device — the one thing '
            'this app exists to avoid doing on its own',
      );
    });

    test('an absent model is fetched once agreed to', () async {
      await agree();
      unawaited(ctrl().ensureDownloadedInBackground());
      await settle();
      expect(store.downloads, 1);
      expect(read().isBusy, isTrue);
    });

    test('a deliberate Download is itself the agreement', () async {
      unawaited(ctrl().download());
      await settle();
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(identityScopedPrefKey(kWhisperAutoFetchPrefKey)),
        isTrue,
        reason: 'nobody should be asked twice for the same thing',
      );
    });

    test('an installed model is not fetched again', () async {
      await agree();
      store.installedNow = true;
      await ctrl().ensureDownloadedInBackground();
      expect(store.downloads, 0);
      expect(read().phase, WhisperModelPhase.ready);
    });

    test('only once, however often the session re-enters', () async {
      // A person who leaves during the transfer is not chased on the next
      // screen. A deliberate retry is still a tap away.
      await agree();
      unawaited(ctrl().ensureDownloadedInBackground());
      await Future<void>.delayed(Duration.zero);
      store.pending!.complete(const WhisperModelDownload.failed('no network'));
      await Future<void>.delayed(Duration.zero);

      await ctrl().ensureDownloadedInBackground();
      expect(store.downloads, 1, reason: 'the second call is a no-op');
    });

    test('it never fights a download the person started', () async {
      unawaited(ctrl().download());
      await Future<void>.delayed(Duration.zero);
      await ctrl().ensureDownloadedInBackground();
      expect(store.downloads, 1);
    });

    test('a failure is silent — no error state to interrupt anyone', () async {
      // Agreeing to a background fetch is not asking to be interrupted by its
      // failure. It may leave "failed" for the tile to show, but nothing here
      // throws.
      await agree();
      unawaited(ctrl().ensureDownloadedInBackground());
      await settle();
      store.pending!.complete(const WhisperModelDownload.failed('offline'));
      await Future<void>.delayed(Duration.zero);
      expect(read().isBusy, isFalse);
    });
  });

  group('installing from a .veilaudio file', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('xveil-veilaudio');
      store.root = Directory('${tmp.path}/support')..createSync();
    });
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    /// A bundle whose single file has [body] as its contents, and whose
    /// manifest declares [claimedHash] — which may be a lie.
    Future<File> speechBundle(List<int> body, {String? claimedHash}) async {
      final src = Directory('${tmp.path}/src')..createSync();
      File('${src.path}/${kSpeechFiles.single}').writeAsBytesSync(body);
      final out = File('${tmp.path}/model.veilaudio');
      await writeBundle(sourceDir: src, kind: kBundleSpeech, out: out);
      if (claimedHash == null) return out;

      // Rewrite the manifest's hash without touching the bytes, which is what
      // a substitution looks like from the outside.
      final raw = out.readAsBytesSync();
      final manifestLength =
          ByteData.sublistView(Uint8List.fromList(raw), 8, 12).getUint32(0);
      final manifest = jsonDecode(utf8.decode(raw.sublist(12, 12 + manifestLength)))
          as Map<String, dynamic>;
      (manifest['files'] as List).single['sha256'] = claimedHash;
      final newManifest = utf8.encode(jsonEncode(manifest));
      final head = ByteData(4)..setUint32(0, newManifest.length);
      final rebuilt = File('${tmp.path}/rewritten.veilaudio')
        ..writeAsBytesSync([
          ...raw.sublist(0, 8),
          ...head.buffer.asUint8List(),
          ...newManifest,
          ...raw.sublist(12 + manifestLength),
        ]);
      return rebuilt;
    }

    test('a model that is not the one this build pins is refused', () async {
      // The guarantee the translation import cannot offer: the right hash is
      // KNOWN here, so a stranger's bundle is checked against what this build
      // expects rather than against its own claim about itself.
      final bundle = await speechBundle(utf8.encode('some other model'));
      expect(await ctrl().importBundle(bundle.path), isFalse);
      expect(read().phase, WhisperModelPhase.failed);
      expect(read().error, contains('not the speech model'));
      // And refused BEFORE writing 57 MiB.
      expect(
        File('${store.root!.path}/${kSpeechFiles.single}').existsSync(),
        isFalse,
      );
    });

    test('a bundle claiming the right hash but carrying other bytes is caught',
        () async {
      final bundle = await speechBundle(
        utf8.encode('impostor'),
        claimedHash: WhisperModelStore.expectedSha256,
      );
      expect(await ctrl().importBundle(bundle.path), isFalse);
      expect(read().phase, WhisperModelPhase.failed);
      // Past the declaration check, stopped by hashing the actual bytes.
      expect(read().error, contains('hash'));
      expect(
        File('${store.root!.path}/${kSpeechFiles.single}').existsSync(),
        isFalse,
      );
    });

    test('a translation bundle offered as a speech model is refused', () async {
      final src = Directory('${tmp.path}/pair')..createSync();
      for (final name in kPairFiles) {
        File('${src.path}/$name').writeAsStringSync(name);
      }
      final out = File('${tmp.path}/pair.veiltranslate');
      await writeBundle(
        sourceDir: src,
        pair: const TranslationPair('ru', 'en'),
        out: out,
      );

      expect(await ctrl().importBundle(out.path), isFalse);
      expect(read().error, contains('not a speech model'));
    });

    test('a file that is not a bundle fails with a reason', () async {
      final junk = File('${tmp.path}/holiday.jpg')..writeAsStringSync('nope');
      expect(await ctrl().importBundle(junk.path), isFalse);
      expect(read().phase, WhisperModelPhase.failed);
      expect(read().error, isNotEmpty);
    });
  });

}
