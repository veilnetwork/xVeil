import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/whisper_model_store.dart';
import 'whisper_ffi.dart';

/// Injectable so tests drive the controller without a network.
final whisperModelStoreProvider = Provider<WhisperModelStore>(
  (ref) => WhisperModelStore(),
);

/// Whether this platform has a whisper build at all.
///
/// A provider rather than a direct call into the FFI statics, so the decision
/// "is transcription possible here" can be answered in a test that has no
/// native library — and so the controller does not reach into a static class
/// to make it.
final whisperNativeProbeProvider = Provider<Future<bool> Function()>(
  (ref) => () async {
    await WhisperTranscriber.ensureResolved();
    return WhisperTranscriber.nativeReady();
  },
);

enum WhisperModelPhase { absent, downloading, ready, failed }

class WhisperModelState {
  const WhisperModelState({
    this.phase = WhisperModelPhase.absent,
    this.progress,
    this.error,
    this.resumeFraction,
  });

  final WhisperModelPhase phase;

  /// 0..1 once the transfer reports, null before the first tick. The store
  /// always knows the fraction (the size is pinned), so null here means "not
  /// started yet", never "cannot tell".
  final double? progress;
  final String? error;

  /// How much of an interrupted attempt is already on disk, 0..1, or null if
  /// there is nothing to resume. Shown so the offer can say "continue" rather
  /// than "download 57 MB" — a person on mobile data decides differently when
  /// they know most of it is already there.
  final double? resumeFraction;

  bool get isBusy => phase == WhisperModelPhase.downloading;
  bool get isReady => phase == WhisperModelPhase.ready;
}

/// Owns the on-demand speech model: whether it is here, fetching it, and
/// dropping it again.
///
/// The model is deliberately not in the build (57 MiB, 63% of the download,
/// for a feature most people never touch), so the app has to be able to say
/// "not yet" without that reading as "broken".
class WhisperModelController extends Notifier<WhisperModelState> {
  /// Set by [cancel], read by the store between chunks.
  bool _cancelRequested = false;

  /// One automatic attempt per session. A person who declines by leaving is
  /// not asked again on the next screen; a deliberate retry is a tap away.
  bool _autoAttempted = false;
  @override
  WhisperModelState build() {
    // After build, not during: refresh() consults `state`, and reading it
    // while the provider is still being created is a circular read.
    Future.microtask(refresh);
    return const WhisperModelState();
  }

  WhisperModelStore get _store => ref.read(whisperModelStoreProvider);

  Future<void> refresh() async {
    // A download in flight must not be overwritten by a stale probe.
    if (state.isBusy) return;
    final installed = await _store.isInstalled();
    final pending = installed ? 0 : await _store.pendingBytes();
    // The screen can be gone by now — the initial probe is scheduled from
    // build() and a person can leave before a disk check returns. Assigning
    // state to a disposed provider throws, and that exception would reach the
    // error report as a fault nobody caused.
    if (!ref.mounted) return;
    // And a download may have STARTED during those two awaits: the check at
    // the top of this method was true when it ran and is not any more. That
    // is not hypothetical — build() schedules this probe and the session
    // start kicks off the background fetch immediately after, so the probe's
    // stale answer would land on top of a running transfer and the UI would
    // show an offer for a download already in progress.
    if (state.isBusy) return;
    state = WhisperModelState(
      phase: installed ? WhisperModelPhase.ready : WhisperModelPhase.absent,
      resumeFraction: pending > 0
          ? pending / WhisperModelStore.expectedBytes
          : null,
    );
  }

  Future<bool> download() async {
    // Pressing twice must not start two 57 MiB transfers.
    if (state.isBusy) return false;
    _cancelRequested = false;
    state = const WhisperModelState(phase: WhisperModelPhase.downloading);
    final result = await _store.download(
      isCancelled: () => _cancelRequested,
      onProgress: (progress) {
        if (ref.mounted && state.isBusy) {
          state = WhisperModelState(
            phase: WhisperModelPhase.downloading,
            progress: progress,
          );
        }
      },
    );
    if (result.succeeded) {
      // The transcriber caches the resolved path and would keep answering
      // "no model" with one sitting right there.
      WhisperTranscriber.forgetResolved();
      if (!ref.mounted) return true;
      state = const WhisperModelState(phase: WhisperModelPhase.ready);
      return true;
    }
    if (!ref.mounted) return false;
    if (result.wasCancelled) {
      // Not an error: back to the offer, which will now say "continue".
      state = WhisperModelState(resumeFraction: await _pendingFraction());
      return false;
    }
    // Keep the resume marker: a failed transport attempt usually left bytes.
    state = WhisperModelState(
      phase: WhisperModelPhase.failed,
      error: result.error,
      resumeFraction: await _pendingFraction(),
    );
    return false;
  }

  /// Fetch the model in the background if it is missing.
  ///
  /// Nobody should have to know a speech model exists, let alone go looking
  /// for it in Settings: transcription either works or it does not. So this
  /// runs once when the session opens and quietly puts the model in place.
  ///
  /// Quietly is the operative word. The person did not ask for this, so a
  /// failure produces no dialog and no toast — the state simply stays
  /// "absent", and the offer in Settings and under a voice message is there
  /// for anyone who wants to retry deliberately.
  ///
  /// Three things stop it before it starts: a download already running (the
  /// person got there first), a model already installed, and a platform with
  /// no whisper build at all — on iOS there is none, and 57 MB that cannot
  /// help is worse than no transcription.
  Future<void> ensureDownloadedInBackground() async {
    if (_autoAttempted || state.isBusy) return;
    _autoAttempted = true;
    if (!await ref.read(whisperNativeProbeProvider)()) return;
    if (await _store.isInstalled()) {
      if (ref.mounted) {
        state = const WhisperModelState(phase: WhisperModelPhase.ready);
      }
      return;
    }
    if (!ref.mounted) return;
    await download();
  }

  /// Ask the running transfer to stop. It finishes the chunk in flight and
  /// keeps what it has, so the next tap resumes rather than restarts.
  void cancel() {
    if (state.isBusy) _cancelRequested = true;
  }

  Future<double?> _pendingFraction() async {
    final pending = await _store.pendingBytes();
    return pending > 0 ? pending / WhisperModelStore.expectedBytes : null;
  }

  Future<void> remove() async {
    if (state.isBusy) return;
    await _store.remove();
    WhisperTranscriber.forgetResolved();
    if (!ref.mounted) return;
    state = const WhisperModelState();
  }
}

final whisperModelControllerProvider =
    NotifierProvider<WhisperModelController, WhisperModelState>(
      WhisperModelController.new,
    );
