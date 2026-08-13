// What the app does on a build that carries NO call media engine.
//
// `libveil_media` is a gitignored prebuilt, and since the desktop plugin CMake
// stopped refusing to configure without one, a build with no engine is a thing
// that exists on purpose. This file pins what such a build DOES: every media
// entry point reports the feature as unavailable, and none of them throws.
//
// Before this, none of them checked. The plugin opens the library from a lazy
// top-level `final` and every binding is a lazy lookup off it, so the first
// media call of any kind — a mic button tap, a voice bubble tap — threw an
// uncaught `ArgumentError` out of the widget callback.
//
// ## Why the availability answer is injected and the functions are not
//
// The functions under test are the REAL ones: `NativeVoiceRecorder.create`,
// the real factory providers, the real `VoiceRecordController`. Only the one
// input they cannot have on a developer machine — "there is no engine here" —
// is supplied, through [VeilMediaNative.debugForceAvailable]. That is the same
// reason `nativeLibCandidates` takes an explicit `allowDevPaths`: a test that
// could only observe the ambient machine would assert the arm that happens to
// be true here and vouch for nothing about the arm that ships.
//
// The last group asserts the probe itself against the real FFI layer, with
// nothing injected.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/media_availability.dart';
import 'package:xveil/state/media_ffi.dart';
import 'package:xveil/state/vnote_play_controller.dart';
import 'package:xveil/state/vnote_record_controller.dart';
import 'package:xveil/state/voice_play_controller.dart';
import 'package:xveil/state/voice_record_controller.dart';

/// The error `dart:ffi` really raises for a library that is not there.
///
/// Produced by asking for one, rather than written out: a hand-made
/// `ArgumentError('Failed to load dynamic library')` would prove only that the
/// guard recognises the string this test chose, which is the string the guard
/// was written against. This one comes from the same code path the app hits.
ArgumentError _realMissingLibraryError() {
  try {
    DynamicLibrary.open('/nonexistent/veil-media-that-is-not-here.so');
  } on ArgumentError catch (e) {
    return e;
  }
  fail('DynamicLibrary.open of a nonexistent path did not throw ArgumentError');
}

/// The error `dart:ffi` really raises for a symbol an engine does not export —
/// the stale-engine case, and what iOS/macOS produce when the archive was
/// never linked in (`DynamicLibrary.process()` opens fine and resolves
/// nothing).
ArgumentError _realMissingSymbolError() {
  try {
    DynamicLibrary.process()
        .lookup<NativeFunction<Void Function()>>('veil_media_no_such_symbol');
  } on ArgumentError catch (e) {
    return e;
  }
  fail('lookup of a nonexistent symbol did not throw ArgumentError');
}

void main() {
  setUp(() {
    VeilMediaNative.debugForceAvailable = null;
    VeilMediaNative.forgetProbe();
  });
  tearDown(() {
    VeilMediaNative.debugForceAvailable = null;
    VeilMediaNative.forgetProbe();
  });

  group('VeilMediaNative.guard', () {
    test('a missing library becomes null, not a throw', () {
      final missing = _realMissingLibraryError();
      expect(VeilMediaNative.guard<int>(() => throw missing), isNull);
    });

    test('a missing symbol becomes null too (stale or unlinked engine)', () {
      final missing = _realMissingSymbolError();
      expect(VeilMediaNative.guard<int>(() => throw missing), isNull);
    });

    test('a value passes straight through', () {
      expect(VeilMediaNative.guard<int>(() => 7), 7);
      expect(VeilMediaNative.guard<int>(() => null), isNull);
    });

    // The guard must not become a blanket catch. A media call site that starts
    // failing for a real reason has to keep failing loudly instead of turning
    // into a button that silently does nothing.
    test('an unrelated ArgumentError is rethrown', () {
      expect(
        () => VeilMediaNative.guard<int>(
          () => throw ArgumentError('peer id must be 32 bytes'),
        ),
        throwsArgumentError,
      );
    });

    test('a non-ArgumentError is rethrown', () {
      expect(
        () => VeilMediaNative.guard<int>(() => throw StateError('boom')),
        throwsStateError,
      );
    });
  });

  group('with no engine, every entry point reports unavailable', () {
    setUp(() => VeilMediaNative.debugForceAvailable = false);

    test('availability is what the UI provider reports', () {
      expect(VeilMediaNative.available(), isFalse);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(callMediaAvailableProvider), isFalse);
    });

    test('voice recorder: null, not a throw', () {
      expect(NativeVoiceRecorder.create(), isNull);
    });

    test('video-note recorder: null, not a throw', () {
      expect(NativeVnoteRecorder.create(), isNull);
    });

    test('voice player factory: null, not a throw', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final make = container.read(voicePlayerFactoryProvider);
      expect(await make(Uint8List.fromList(const [1, 2, 3])), isNull);
    });

    test('video-note frame player factory: null, not a throw', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final make = container.read(vnoteFramePlayerFactoryProvider);
      expect(make(Uint8List.fromList(const [1, 2, 3])), isNull);
    });

    // The whole point: the person gets told, through the state the composer
    // already renders as a toast, instead of an uncaught error crossing the
    // widget boundary.
    test('the record controller reports error rather than throwing', () async {
      final container = ProviderContainer(
        overrides: [
          // The only thing still stubbed is the OS permission prompt, which no
          // unit test can answer for real.
          micPermissionProvider.overrideWithValue(() async => true),
        ],
      );
      addTearDown(container.dispose);
      await container.read(voiceRecordControllerProvider.notifier).start();
      expect(
        container.read(voiceRecordControllerProvider).phase,
        VoiceRecordPhase.error,
      );
    });
  });

  group('with an engine, nothing is gated off', () {
    setUp(() => VeilMediaNative.debugForceAvailable = true);

    test('the UI provider says the features are offered', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(callMediaAvailableProvider), isTrue);
    });
  });

  group('the real probe', () {
    // Nothing injected here: this runs the actual `VeilMediaEngine.version()`
    // call through the plugin's own loader. A test binary has no app bundle
    // and no engine on its library path, so the answer is expected to be
    // false — but the assertion that matters is that ASKING does not throw,
    // which is what every caller depends on.
    test('answers without throwing, and caches its answer', () {
      final first = VeilMediaNative.available();
      expect(first, isA<bool>());
      expect(VeilMediaNative.available(), first);
    });
  });
}
