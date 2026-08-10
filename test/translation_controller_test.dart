// What the translation controller must get right without an engine in sight.
//
// The engine is injected, so everything below is about the DECISIONS this
// layer owns: what to run, what not to run twice, where the answer is kept,
// and what happens when the answer is bad. A fake engine makes each of those
// exact instead of timing-dependent.
//
// The cache lives in the ENCRYPTED store, which is the point of caching here
// at all: a translation is the message's content in another language, and
// writing it anywhere else would put plaintext on disk that the original
// never was.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/translation_controller.dart';
import 'dart:typed_data';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HiddenVolumeStorage storage;
  late ProviderContainer container;
  var calls = 0;
  late Future<String?> Function(String, {required String from, required String to})
  engine;

  Future<ProviderContainer> boot({TranslateText? translator}) async {
    final log = FakeKvLogStore();
    storage = HiddenVolumeStorage(
      ({required Uint8List password, required bool create}) => log,
    );
    expect(await storage.open(password: 'pw', createIfMissing: true), isTrue);
    final c = ProviderContainer(
      overrides: [
        storageProvider.overrideWith((ref) => storage as Storage),
        if (translator != null)
          textTranslatorProvider.overrideWithValue(translator),
      ],
    );
    addTearDown(c.dispose);
    addTearDown(storage.close);
    return c;
  }

  setUp(() {
    calls = 0;
    engine = (text, {required from, required to}) async {
      calls++;
      return '[$to] $text';
    };
  });

  test('with no engine there is nothing to offer, and nothing runs', () async {
    container = await boot();
    expect(
      container.read(translationAvailableProvider),
      isFalse,
      reason:
          'a build without a translator must show no affordance at all — a '
          'button that cannot work is worse than no button',
    );
    final ctl = container.read(translationControllerProvider.notifier);
    await ctl.translate('m1', 'hello', to: 'ru');
    expect(
      ctl.entryFor('m1').phase,
      TranslationPhase.none,
      reason: 'the controller moved a message into a phase it cannot leave',
    );
  });

  test('a translation is produced once and then served from the store', () async {
    container = await boot(translator: engine);
    expect(container.read(translationAvailableProvider), isTrue);
    final ctl = container.read(translationControllerProvider.notifier);

    await ctl.translate('m1', 'hello', to: 'ru');
    final done = ctl.entryFor('m1');
    expect(done.isDone, isTrue);
    expect(done.text, '[ru] hello');
    expect(done.to, 'ru');
    expect(calls, 1);

    // Asking again for the SAME language must not run the engine — and must
    // not pass through `running` on the way to the answer it already holds.
    //
    // The engine count alone does not test the guard: without it the call
    // falls through to the store, finds the answer and returns, still without
    // running anything. What changes is the UI, which flashes a spinner over
    // text it is already showing. So the phases are watched, not just the
    // count.
    final seen = <TranslationPhase>[];
    final sub = container.listen<Map<String, TranslationEntry>>(
      translationControllerProvider,
      (_, next) {
        final e = next['m1'];
        if (e != null) seen.add(e.phase);
      },
    );
    addTearDown(sub.close);
    await ctl.translate('m1', 'hello', to: 'ru');
    expect(calls, 1, reason: 'the engine ran again for an answer already held');
    expect(
      seen,
      isNot(contains(TranslationPhase.running)),
      reason:
          'a repeat request for a language already shown moved the message '
          'back into `running` — the reader sees a spinner over text that is '
          'already there',
    );

    // And a fresh controller — a new session — finds it in the store rather
    // than running. This is the half that justifies writing to disk at all.
    final fresh = ProviderContainer(
      overrides: [
        storageProvider.overrideWith((ref) => storage as Storage),
        textTranslatorProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(fresh.dispose);
    final ctl2 = fresh.read(translationControllerProvider.notifier);
    await ctl2.loadCached('m1', to: 'ru');
    expect(
      ctl2.entryFor('m1').text,
      '[ru] hello',
      reason: 'the cached reading did not survive into a new session',
    );
    expect(calls, 1, reason: 'loadCached ran the engine');
  });

  test('two languages are two answers, and neither overwrites the other', () async {
    container = await boot(translator: engine);
    final ctl = container.read(translationControllerProvider.notifier);
    await ctl.translate('m1', 'hello', to: 'ru');
    await ctl.translate('m1', 'hello', to: 'de');
    expect(calls, 2, reason: 'asking for another language must run again');
    expect(ctl.entryFor('m1').text, '[de] hello');

    // The Russian reading is still in the store: a cache keyed only by message
    // id would have lost it, and the reader who asked for it first would get
    // German back on the next session.
    final fresh = ProviderContainer(
      overrides: [
        storageProvider.overrideWith((ref) => storage as Storage),
        textTranslatorProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(fresh.dispose);
    final ctl2 = fresh.read(translationControllerProvider.notifier);
    await ctl2.loadCached('m1', to: 'ru');
    expect(ctl2.entryFor('m1').text, '[ru] hello');
  });

  test('an engine that fails leaves the message retryable, not cached', () async {
    var attempt = 0;
    container = await boot(
      translator: (text, {required from, required to}) async {
        attempt++;
        return attempt == 1 ? null : '[$to] $text';
      },
    );
    final ctl = container.read(translationControllerProvider.notifier);
    await ctl.translate('m1', 'hello', to: 'ru');
    expect(ctl.entryFor('m1').phase, TranslationPhase.failed);

    // Nothing was written, so the next attempt really runs.
    await ctl.translate('m1', 'hello', to: 'ru');
    expect(ctl.entryFor('m1').text, '[ru] hello');
    expect(attempt, 2);
  });

  test('an empty answer is not cached', () async {
    // An engine that returns "" is either failing without saying so or was
    // handed nothing to translate. Caching that would make the message
    // permanently blank in the reader's language, and blank is not a
    // translation.
    var attempt = 0;
    container = await boot(
      translator: (text, {required from, required to}) async {
        attempt++;
        return attempt == 1 ? '' : '[$to] $text';
      },
    );
    final ctl = container.read(translationControllerProvider.notifier);
    await ctl.translate('m1', 'hello', to: 'ru');
    expect(ctl.entryFor('m1').isDone, isTrue);
    expect(ctl.entryFor('m1').text, '');

    final fresh = ProviderContainer(
      overrides: [
        storageProvider.overrideWith((ref) => storage as Storage),
      ],
    );
    addTearDown(fresh.dispose);
    final ctl2 = fresh.read(translationControllerProvider.notifier);
    await ctl2.loadCached('m1', to: 'ru');
    expect(
      ctl2.entryFor('m1').phase,
      TranslationPhase.none,
      reason: 'an empty answer was written to the store and is now permanent',
    );
  });

  test('clearing goes back to the original text', () async {
    container = await boot(translator: engine);
    final ctl = container.read(translationControllerProvider.notifier);
    await ctl.translate('m1', 'hello', to: 'ru');
    expect(ctl.entryFor('m1').isDone, isTrue);
    ctl.clear('m1');
    expect(ctl.entryFor('m1').phase, TranslationPhase.none);
    // Still in the store, so showing it again costs nothing.
    await ctl.loadCached('m1', to: 'ru');
    expect(ctl.entryFor('m1').text, '[ru] hello');
    expect(calls, 1);
  });

  test('a miss is remembered, so the store is read once per message', () async {
    // The widget under every incoming message asks for a cached reading. The
    // guard used to be "is there an entry for this message", which is only
    // true after a HIT — so for every message nobody has translated, and that
    // is almost all of them, the store was read again every time. A read per
    // message per frame, on the hottest path the app has.
    //
    // Observable without a spy: write the value into the store AFTER the miss
    // has been remembered. A controller that re-reads would find it.
    container = await boot(translator: engine);
    final ctl = container.read(translationControllerProvider.notifier);
    await ctl.loadCached('m1', to: 'ru');
    expect(ctl.entryFor('m1').phase, TranslationPhase.none);

    await storage.putSetting('msg.translation.v1:ru:m1', 'planted');
    await ctl.loadCached('m1', to: 'ru');
    expect(
      ctl.entryFor('m1').text,
      isNull,
      reason:
          'the store was read a second time for a message already looked up '
          'and found empty — that read happens on every rebuild of every '
          'incoming message',
    );

    // Another LANGUAGE is a different question and must still be asked.
    await storage.putSetting('msg.translation.v1:de:m1', 'anders');
    await ctl.loadCached('m1', to: 'de');
    expect(
      ctl.entryFor('m1').text,
      'anders',
      reason: 'the miss for one language silenced the look-up for another',
    );
  });

  test('a read that THREW is not remembered as a miss', () async {
    // The order inside the try matters. Marking the key probed before the
    // store answers means a read that failed — the store is not open yet,
    // which happens during an identity switch — is remembered as "nothing
    // there", and the translation stays hidden for the rest of the session.
    final log = FakeKvLogStore();
    final inner = HiddenVolumeStorage(
      ({required Uint8List password, required bool create}) => log,
    );
    expect(await inner.open(password: 'pw', createIfMissing: true), isTrue);
    addTearDown(inner.close);
    await inner.putSetting('msg.translation.v1:ru:m1', 'hola');
    final flaky = _FailFirstStorage(inner);
    final c = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => flaky as Storage)],
    );
    addTearDown(c.dispose);

    final ctl = c.read(translationControllerProvider.notifier);
    await ctl.loadCached('m1', to: 'ru'); // throws inside
    expect(ctl.entryFor('m1').text, isNull);
    await ctl.loadCached('m1', to: 'ru'); // the store answers this time
    expect(
      ctl.entryFor('m1').text,
      'hola',
      reason:
          'a failed read was remembered as a miss — the reading exists and is '
          'now unreachable until the app restarts',
    );
  });

  test('an empty body is not sent to the engine', () async {
    container = await boot(translator: engine);
    final ctl = container.read(translationControllerProvider.notifier);
    await ctl.translate('m1', '   ', to: 'ru');
    expect(calls, 0);
    expect(ctl.entryFor('m1').phase, TranslationPhase.none);
  });
}

/// Fails the first `getSetting`, then forwards. Everything else goes straight
/// through — `noSuchMethod` rather than a hand-written stub for each member,
/// because the interface is wide and none of the rest is under test here.
class _FailFirstStorage implements Storage {
  _FailFirstStorage(this._inner);
  final Storage _inner;
  var _failuresLeft = 1;

  @override
  Future<String?> getSetting(String key) async {
    if (_failuresLeft > 0) {
      _failuresLeft--;
      throw StateError('store not open');
    }
    return _inner.getSetting(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Function.apply(
        (_inner as dynamic).noSuchMethod,
        [invocation],
      );
}
