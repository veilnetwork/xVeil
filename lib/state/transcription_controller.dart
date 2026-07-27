// Voice transcription controller (brick 6): drives on-device whisper for a
// voice message's "Transcribe" button, and caches the result in the ENCRYPTED
// store (keyed by the clip's blob key) so it never re-runs and never leaks the
// text to plaintext. By button only (CPU cost + privacy), never automatic.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import 'providers.dart';
import 'whisper_ffi.dart';

/// Injectable so widget tests fake the native transcriber.
typedef VoiceTranscribe =
    Future<String?> Function(Uint8List opus, {String lang});

final voiceTranscriberProvider = Provider<VoiceTranscribe>(
  (ref) => WhisperTranscriber().transcribe,
);

/// Whether the native STT layer + model are present (gates the UI affordance).
/// Async because the Android model path needs a path_provider lookup; resolves
/// to false until (and unless) the libs + model are found.
final transcriptionAvailableProvider = FutureProvider<bool>((ref) async {
  await WhisperTranscriber.ensureResolved();
  return WhisperTranscriber.available();
});

/// Whether the native STT layer is here at all, model aside.
///
/// The model is fetched on demand, so "no model" and "no whisper build for
/// this platform" are different sentences: the first is a download away, the
/// second is not, and only the first should be offered.
final transcriptionNativeReadyProvider = FutureProvider<bool>((ref) async {
  await WhisperTranscriber.ensureResolved();
  return WhisperTranscriber.nativeReady();
});

enum TranscriptPhase { none, running, done, failed }

class TranscriptEntry {
  const TranscriptEntry({this.phase = TranscriptPhase.none, this.text});
  final TranscriptPhase phase;
  final String? text;

  bool get isRunning => phase == TranscriptPhase.running;
  bool get isDone => phase == TranscriptPhase.done;
}

class TranscriptionController extends Notifier<Map<String, TranscriptEntry>> {
  @override
  Map<String, TranscriptEntry> build() => const {};

  static String _cacheKey(String fileKey) => 'voice.transcript.v2:$fileKey';

  /// The language to transcribe in. whisper's auto-detect is unreliable on the
  /// small quantized model (it silently returns empty), so we use the user's
  /// UI/device language as a strong prior — voice notes are almost always in it.
  static String _lang() {
    final code = PlatformDispatcher.instance.locale.languageCode;
    if (code.isNotEmpty) return code;
    final os = Platform.localeName.split(RegExp('[_-]')).first;
    return os.isNotEmpty ? os : 'en';
  }

  TranscriptEntry entryFor(String messageId) =>
      state[messageId] ?? const TranscriptEntry();

  /// Load a previously-cached transcript for this clip into state (called when
  /// the bubble first renders a downloaded voice message). No-op if already
  /// loaded or nothing cached.
  Future<void> loadCached(String messageId, String fileKey) async {
    if (state.containsKey(messageId)) return;
    try {
      final cached = await ref
          .read(storageProvider)
          .getSetting(_cacheKey(fileKey));
      if (cached != null) {
        _set(
          messageId,
          TranscriptEntry(phase: TranscriptPhase.done, text: cached),
        );
      }
    } catch (_) {
      /* store not open / transient — leave as none */
    }
  }

  /// Transcribe the clip [fileKey] and cache the result. [senderLang] (from the
  /// message's sidecar) is preferred over the local device language — a note is
  /// in the SENDER's language. No-op while already running or done.
  Future<void> transcribe(
    String messageId,
    String fileKey, {
    String? senderLang,
  }) async {
    final cur = entryFor(messageId);
    if (cur.isRunning || cur.isDone) return;
    _set(messageId, const TranscriptEntry(phase: TranscriptPhase.running));
    try {
      final bytes = await ref.read(storageProvider).loadFile(fileKey);
      if (bytes == null) {
        _set(messageId, const TranscriptEntry(phase: TranscriptPhase.failed));
        return;
      }
      final lang = (senderLang != null && senderLang.isNotEmpty)
          ? senderLang
          : _lang();
      final text = await ref.read(voiceTranscriberProvider)(bytes, lang: lang);
      if (text == null) {
        _set(messageId, const TranscriptEntry(phase: TranscriptPhase.failed));
        return;
      }
      // Cache non-empty results (best-effort) so they survive a rebuild + never
      // re-run. An empty result (silence / a mis-detect) is NOT cached, so the
      // Transcribe button stays available to retry across sessions.
      if (text.isNotEmpty) {
        try {
          await ref.read(storageProvider).putSetting(_cacheKey(fileKey), text);
        } catch (e) {
          devLog(() => 'xVeil[transcript]: cache write failed: $e');
        }
      }
      _set(messageId, TranscriptEntry(phase: TranscriptPhase.done, text: text));
    } catch (e) {
      devLog(() => 'xVeil[transcript]: transcribe failed: $e');
      _set(messageId, const TranscriptEntry(phase: TranscriptPhase.failed));
    }
  }

  void _set(String messageId, TranscriptEntry e) {
    state = {...state, messageId: e};
  }
}

final transcriptionControllerProvider =
    NotifierProvider<TranscriptionController, Map<String, TranscriptEntry>>(
      TranscriptionController.new,
    );
