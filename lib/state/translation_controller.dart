// Message translation (local): turns a received message into the reader's own
// language on demand, and caches the result in the ENCRYPTED store so it never
// re-runs and never leaks the text to plaintext. By button only — the same
// bargain transcription makes, for the same two reasons (CPU and privacy).
//
// The engine is injected, exactly as the voice transcriber is: this layer owns
// the decision of WHAT to translate, WHEN not to bother, and WHERE the answer
// is kept. A build with no engine present shows nothing at all rather than a
// button that cannot work.

import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../data/storage/storage.dart';
import 'providers.dart';
import 'translation_engines.dart';

/// Translate [text] from [from] into [to]. Null means the engine could not.
///
/// `from` is a hint, not a promise: a sender's tag can be wrong and a chat can
/// switch languages mid-thread, so an engine that detects for itself is free to
/// ignore it.
typedef TranslateText =
    Future<String?> Function(
      String text, {
      required String from,
      required String to,
    });

/// Resolving what is actually on this device: a native library, and at least
/// one language pair. Null when either is missing.
///
/// A FutureProvider because both answers need the filesystem, and the UI must
/// not decide "translation is unavailable" from a check that had not run yet.
/// Riverpod rebuilds the two providers below when it settles, so the
/// affordance appears when the evidence does.
final translationEnginesProvider = FutureProvider<TranslationEngines?>((
  ref,
) async {
  final engines = await TranslationEngines.resolve();
  // Each open engine holds an isolate and a loaded model; a provider that is
  // torn down without releasing them leaks both.
  ref.onDispose(() => engines?.dispose());
  return engines;
});

/// The engine, or null while it is still being resolved or when there is
/// none. Overridden wholesale in tests, which is why the real wiring lives in
/// the provider above rather than in this expression.
final textTranslatorProvider = Provider<TranslateText?>(
  (ref) => ref.watch(translationEnginesProvider).asData?.value?.translate,
);

/// Whether translation can run at all on this build.
final translationAvailableProvider = Provider<bool>(
  (ref) => ref.watch(textTranslatorProvider) != null,
);

enum TranslationPhase { none, running, done, failed }

class TranslationEntry {
  const TranslationEntry({
    this.phase = TranslationPhase.none,
    this.text,
    this.to,
  });
  final TranslationPhase phase;
  final String? text;

  /// The language this reading is IN. Kept for the same reason the transcript
  /// keeps its own: without it, asking for another language cannot be told
  /// apart from asking again for the one already shown.
  final String? to;

  bool get isRunning => phase == TranslationPhase.running;
  bool get isDone => phase == TranslationPhase.done;
}

class TranslationController extends Notifier<Map<String, TranslationEntry>> {
  /// The storage THIS build belongs to.
  ///
  /// A translation runs for as long as the engine takes, and the store was
  /// read again afterwards. An all-online switch in between — which
  /// `AppController._activateOnline` performs with no teardown — put the
  /// finished reading of A's message into B's storage, where it stays after
  /// the lock. What is written is the message text itself, in another
  /// language (report17 XV17-H4).
  late Storage _storage;

  @override
  Map<String, TranslationEntry> build() {
    // WATCHED: a switch rebuilds this notifier, and everything below belongs
    // to the identity it was built for.
    _storage = ref.watch(storageProvider);
    // Which keys have been looked for is a fact about ONE store. Carried into
    // another, a remembered miss hides a translation that store does have.
    _probed.clear();
    // And the readings themselves go with it: they are A's messages.
    return const {};
  }

  /// Cached per (message, target language) — the same message read in two
  /// languages is two answers, and one must not overwrite the other.
  static String _cacheKey(String messageId, String to) =>
      'msg.translation.v1:$to:$messageId';

  /// This reader's own language — the default target.
  static String deviceLang() {
    final code = PlatformDispatcher.instance.locale.languageCode;
    if (code.isNotEmpty) return code;
    final os = Platform.localeName.split(RegExp('[_-]')).first;
    return os.isNotEmpty ? os : 'en';
  }

  TranslationEntry entryFor(String messageId) =>
      state[messageId] ?? const TranslationEntry();

  /// Cache keys this controller has already looked for, hit or miss.
  ///
  /// A MISS has to be remembered, and that is the whole point. The guard used
  /// to be "is there an entry for this message", which is only ever true after
  /// a hit — so for every message nobody has translated, and that is almost
  /// all of them, the store was read again on every call. The caller is a
  /// widget under each incoming message, so "every call" meant every rebuild
  /// of the chat list: a storage read per message per frame, on the hottest
  /// path the app has.
  ///
  /// Keyed by (message, language) rather than by message, because asking for
  /// another language is a different question and must still be asked.
  final _probed = <String>{};

  /// Show a previously-made translation without running anything. No-op when
  /// one is already in hand, and no-op after the first look that found none.
  Future<void> loadCached(String messageId, {String? to}) async {
    final target = to ?? deviceLang();
    final key = _cacheKey(messageId, target);
    if (_probed.contains(key)) return;
    final current = state[messageId];
    if (current != null && current.isDone && current.to == target) return;
    final storage = _storage;
    try {
      final cached = await storage.getSetting(key);
      // And only if the store that answered is still the one this notifier
      // belongs to. The rebuild that swaps stores CLEARS `_probed` for the
      // reason written at `build`: a remembered miss is a fact about ONE
      // store, and carried into another it hides a translation that one does
      // have. A read begun under the old store and finishing after the switch
      // put its key into the new store's set, which is that same harm arriving
      // one entry at a time — and `_set` below cannot undo it, because the
      // damage is the remembered miss, not the display (report21 XV18-L1).
      if (!identical(_storage, storage)) return;
      // Marked only once the store ANSWERED. A read that threw means the store
      // is not open yet, and remembering that as "nothing there" would hide a
      // translation for the rest of the session.
      _probed.add(key);
      if (cached != null) {
        _set(
          storage,
          messageId,
          TranslationEntry(
            phase: TranslationPhase.done,
            text: cached,
            to: target,
          ),
        );
      }
    } catch (_) {
      /* store not open / transient — leave as none */
    }
  }

  /// Translate [body] into [to] (default: this reader's language).
  ///
  /// Asking again for the SAME language is free; asking for a different one
  /// runs again and replaces what is shown.
  Future<void> translate(
    String messageId,
    String body, {
    String? from,
    String? to,
  }) async {
    final target = to ?? deviceLang();
    final cur = entryFor(messageId);
    if (cur.isRunning) return;
    if (cur.isDone && cur.to == target) return;

    final engine = ref.read(textTranslatorProvider);
    if (engine == null || body.trim().isEmpty) return;

    // The storage this reading belongs to, captured before the engine runs.
    final storage = _storage;
    _set(
      storage,
      messageId,
      const TranslationEntry(phase: TranslationPhase.running),
    );
    try {
      final cached = await _cached(storage, messageId, target);
      if (cached != null) {
        _set(
          storage,
          messageId,
          TranslationEntry(
            phase: TranslationPhase.done,
            text: cached,
            to: target,
          ),
        );
        return;
      }
      final out = await engine(body, from: from ?? '', to: target);
      if (out == null) {
        _set(
          storage,
          messageId,
          const TranslationEntry(phase: TranslationPhase.failed),
        );
        return;
      }
      // An empty result is NOT cached: it is either a failure the engine did
      // not report or a message with nothing to translate, and both should
      // stay retryable across sessions.
      if (out.isNotEmpty) {
        try {
          await storage.putSetting(_cacheKey(messageId, target), out);
        } catch (e) {
          devLog(() => 'xVeil[translate]: cache write failed: $e');
        }
      }
      _set(
        storage,
        messageId,
        TranslationEntry(phase: TranslationPhase.done, text: out, to: target),
      );
    } catch (e) {
      devLog(() => 'xVeil[translate]: failed: $e');
      _set(
        storage,
        messageId,
        const TranslationEntry(phase: TranslationPhase.failed),
      );
    }
  }

  /// Drop the shown translation for [messageId] — back to the original text.
  ///
  /// The probe memory is NOT cleared: the store still holds what it held, and
  /// re-reading it would only put back what the reader just dismissed.
  void clear(String messageId) {
    final next = {...state}..remove(messageId);
    state = next;
  }

  Future<String?> _cached(Storage storage, String messageId, String to) async {
    try {
      return await storage.getSetting(_cacheKey(messageId, to));
    } catch (_) {
      return null;
    }
  }

  /// Show [e], but only while the identity it was made for is still the one
  /// being shown. A reading of A's message under B is the leak this guards.
  void _set(Storage storage, String messageId, TranslationEntry e) {
    if (!identical(_storage, storage)) return;
    state = {...state, messageId: e};
  }
}

final translationControllerProvider =
    NotifierProvider<TranslationController, Map<String, TranslationEntry>>(
      TranslationController.new,
    );
