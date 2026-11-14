import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/android_microphone_lifetime.dart';

final class _Resources implements MicrophoneResourceRetirement {
  int verified = 0, releases = 0;
  bool loseReleaseReply = false;
  bool released = false;
  @override
  Future<void> verifyReleasedResources() async {
    verified++;
  }

  @override
  Future<void> releaseAdmission() async {
    releases++;
    released = true;
    if (loseReleaseReply) {
      loseReleaseReply = false;
      throw StateError('synthetic lost reply');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(AndroidMicrophoneLifetime.debugReset);

  test(
    'retirement joins accepted start and permanently seals old controller',
    () async {
      final entered = Completer<void>(), returned = Completer<bool>();
      final requests = <bool>[];
      final native = _Resources();
      var acquisitions = 0;
      AndroidMicrophoneLifetime.debugInvokeOverride = (active) async {
        requests.add(active);
        if (!entered.isCompleted) {
          entered.complete();
          return returned.future;
        }
        return true;
      };
      AndroidMicrophoneLifetime.debugRetireOverride = () async {
        acquisitions++;
        return native;
      };
      final old = AndroidMicrophoneLifetime.current();
      final starting = old.setActive(true);
      await entered.future;
      final retiring = old.retireForErasure();
      await expectLater(old.setActive(true), throwsStateError);
      expect(acquisitions, 0);
      returned.complete(true);
      await starting;
      final receipt = await retiring;
      expect(acquisitions, 1);
      expect(identical(await old.retireForErasure(), receipt), isTrue);
      await receipt.verifyReleasedResources();
      expect(native.verified, 1);
      await receipt.releaseNativeAdmission();
      receipt.publishFreshLifetime();
      final fresh = AndroidMicrophoneLifetime.current();
      expect(identical(old, fresh), isFalse);
      await expectLater(old.setActive(false), throwsStateError);
      await fresh.setActive(true);
      expect(requests, [true, true]);
      receipt.publishFreshLifetime();
      expect(identical(AndroidMicrophoneLifetime.current(), fresh), isTrue);
    },
  );

  test('late permission cannot acquire fresh profile service', () async {
    final requests = <bool>[];
    AndroidMicrophoneLifetime.debugInvokeOverride = (active) async {
      requests.add(active);
      return true;
    };
    AndroidMicrophoneLifetime.debugRetireOverride = () async => _Resources();
    final old = AndroidMicrophoneLifetime.current();
    final consent = Completer<bool>();
    final waiting = old.activateWhenMicrophoneGranted(
      consent.future,
      isCurrent: () => true,
    );
    final receipt = await old.retireForErasure();
    await receipt.releaseNativeAdmission();
    receipt.publishFreshLifetime();
    consent.complete(true);
    await waiting;
    expect(requests, isEmpty);
    await AndroidMicrophoneLifetime.current().setActive(true);
    expect(requests, [true]);
  });

  test('reentrant retirement includes the adapter that requested it', () async {
    final release = Completer<bool>(), entered = Completer<void>();
    final native = _Resources();
    var acquisitions = 0;
    final old = AndroidMicrophoneLifetime.current();
    late Future<AndroidMicrophoneRetirement> retiring;
    AndroidMicrophoneLifetime.debugRetireOverride = () async {
      acquisitions++;
      return native;
    };
    AndroidMicrophoneLifetime.debugInvokeOverride = (_) {
      retiring = old.retireForErasure();
      entered.complete();
      return release.future;
    };
    final starting = old.setActive(true);
    await entered.future;
    expect(acquisitions, 0);
    release.complete(true);
    await starting;
    await retiring;
    expect(acquisitions, 1);
  });

  test(
    'failed acquisition stays sealed and retry preserves successful receipt',
    () async {
      final native = _Resources();
      var acquisitions = 0;
      AndroidMicrophoneLifetime.debugRetireOverride = () async {
        if (++acquisitions == 1) throw StateError('synthetic refusal');
        return native;
      };
      final old = AndroidMicrophoneLifetime.current();
      await expectLater(old.retireForErasure(), throwsStateError);
      await expectLater(old.setActive(true), throwsStateError);
      final receipt = await old.retireForErasure();
      expect(identical(await old.retireForErasure(), receipt), isTrue);
      expect(acquisitions, 2);
    },
  );

  test(
    'lost native release reply cannot publish early or release another lifetime',
    () async {
      final native = _Resources()..loseReleaseReply = true;
      AndroidMicrophoneLifetime.debugRetireOverride = () async => native;
      final old = AndroidMicrophoneLifetime.current();
      final receipt = await old.retireForErasure();
      await expectLater(receipt.releaseNativeAdmission(), throwsStateError);
      expect(receipt.publishFreshLifetime, throwsStateError);
      expect(identical(AndroidMicrophoneLifetime.current(), old), isTrue);
      await receipt.releaseNativeAdmission();
      receipt.publishFreshLifetime();
      final fresh = AndroidMicrophoneLifetime.current();
      receipt.publishFreshLifetime();
      expect(identical(AndroidMicrophoneLifetime.current(), fresh), isTrue);
      expect(native.releases, 2);
    },
  );

  test(
    'missing native retirement cannot be replaced by ordinary stop',
    () async {
      final requests = <bool>[];
      AndroidMicrophoneLifetime.debugInvokeOverride = (active) async {
        requests.add(active);
        return true;
      };
      final old = AndroidMicrophoneLifetime.current();
      await old.setActive(true);
      await expectLater(
        old.retireForErasure(),
        throwsA(isA<MissingPluginException>()),
      );
      expect(requests, [true]);
      await expectLater(old.setActive(false), throwsStateError);
    },
  );
}
