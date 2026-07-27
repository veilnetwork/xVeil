import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/whisper_model_store.dart';
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
}

void main() {
  late _ScriptedStore store;
  late ProviderContainer container;

  setUp(() {
    store = _ScriptedStore();
    container = ProviderContainer(
      overrides: [whisperModelStoreProvider.overrideWithValue(store)],
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
}
