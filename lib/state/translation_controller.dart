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
import 'providers.dart';

/// Translate [text] from [from] into [to]. Null means the engine could not.
///
/// `from` is a hint, not a promise: a sender's tag can be wrong and a chat can
/// switch languages mid-thread, so an engine that detects for itself is free to
/// ignore it.
typedef TranslateText =
    Future<String?> Function(String text, {required String from, required String to});

/// No engine by default. Wired by the platform layer once a local translator
/// exists; until then every call returns null and the UI stays hidden.
final textTranslatorProvider = Provider<TranslateText?>((ref) => null);

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
  @override
  Map<String, TranslationEntry> build() => const {};

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

  /// Show a previously-made translation without running anything. No-op when
  /// one is already in hand.
  Future<void> loadCached(String messageId, {String? to}) async {
    if (state.containsKey(messageId)) return;
    final target = to ?? deviceLang();
    try {
      final cached = await ref
          .read(storageProvider)
          .getSetting(_cacheKey(messageId, target));
      if (cached != null) {
        _set(
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

    _set(messageId, const TranslationEntry(phase: TranslationPhase.running));
    try {
      final cached = await _cached(messageId, target);
      if (cached != null) {
        _set(
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
        _set(messageId, const TranslationEntry(phase: TranslationPhase.failed));
        return;
      }
      // An empty result is NOT cached: it is either a failure the engine did
      // not report or a message with nothing to translate, and both should
      // stay retryable across sessions.
      if (out.isNotEmpty) {
        try {
          await ref
              .read(storageProvider)
              .putSetting(_cacheKey(messageId, target), out);
        } catch (e) {
          devLog(() => 'xVeil[translate]: cache write failed: $e');
        }
      }
      _set(
        messageId,
        TranslationEntry(
          phase: TranslationPhase.done,
          text: out,
          to: target,
        ),
      );
    } catch (e) {
      devLog(() => 'xVeil[translate]: failed: $e');
      _set(messageId, const TranslationEntry(phase: TranslationPhase.failed));
    }
  }

  /// Drop the shown translation for [messageId] — back to the original text.
  void clear(String messageId) {
    final next = {...state}..remove(messageId);
    state = next;
  }

  Future<String?> _cached(String messageId, String to) async {
    try {
      return await ref.read(storageProvider).getSetting(_cacheKey(messageId, to));
    } catch (_) {
      return null;
    }
  }

  void _set(String messageId, TranslationEntry e) {
    state = {...state, messageId: e};
  }
}

final translationControllerProvider =
    NotifierProvider<TranslationController, Map<String, TranslationEntry>>(
      TranslationController.new,
    );
