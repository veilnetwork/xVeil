import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/whisper_model_store.dart';
import 'whisper_ffi.dart';

/// Injectable so tests drive the controller without a network.
final whisperModelStoreProvider = Provider<WhisperModelStore>(
  (ref) => WhisperModelStore(),
);

enum WhisperModelPhase { absent, downloading, ready, failed }

class WhisperModelState {
  const WhisperModelState({
    this.phase = WhisperModelPhase.absent,
    this.progress,
    this.error,
  });

  final WhisperModelPhase phase;

  /// 0..1, or null while the server has not said how long the body is — an
  /// indeterminate bar is honest, a made-up percentage is not.
  final double? progress;
  final String? error;

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
    state = WhisperModelState(
      phase: installed ? WhisperModelPhase.ready : WhisperModelPhase.absent,
    );
  }

  Future<bool> download() async {
    // Pressing twice must not start two 57 MiB transfers.
    if (state.isBusy) return false;
    state = const WhisperModelState(phase: WhisperModelPhase.downloading);
    final result = await _store.download(
      onProgress: (progress) {
        if (state.isBusy) {
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
      state = const WhisperModelState(phase: WhisperModelPhase.ready);
      return true;
    }
    state = WhisperModelState(
      phase: WhisperModelPhase.failed,
      error: result.error,
    );
    return false;
  }

  Future<void> remove() async {
    if (state.isBusy) return;
    await _store.remove();
    WhisperTranscriber.forgetResolved();
    state = const WhisperModelState();
  }
}

final whisperModelControllerProvider =
    NotifierProvider<WhisperModelController, WhisperModelState>(
      WhisperModelController.new,
    );
