import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_network_activity.dart';

class _Resources implements CallNetworkResourceRetirement {
  bool held = false, loseRelease = false;
  int verified = 0, releases = 0;
  @override
  Future<void> verifyReleasedResources() async {
    verified++;
    if (held) throw StateError('synthetic native resource remains');
  }

  @override
  Future<void> releaseAdmission() async {
    await verifyReleasedResources();
    releases++;
    if (loseRelease) {
      loseRelease = false;
      throw StateError('synthetic release reply lost');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Resources native;
  setUp(() {
    native = _Resources();
    CallNetworkActivity.debugSetActiveOverride = (active) async => active;
    CallNetworkActivity.debugRetireOverride = () async => native;
  });
  tearDown(() async {
    native.held = false;
    CallNetworkActivity.debugRetireOverride = () async => native;
    await CallNetworkActivity.shared.retireForErasure();
    CallNetworkActivity.debugReset();
  });

  test(
    'retirement joins an accepted acquisition and seals old controllers',
    () async {
      final entered = Completer<void>(), release = Completer<bool>();
      final calls = <bool>[];
      CallNetworkActivity.debugSetActiveOverride = (active) async {
        calls.add(active);
        if (!entered.isCompleted) {
          entered.complete();
          return release.future;
        }
        return active;
      };
      final old = CallNetworkActivity.shared;
      final owner = Object();
      final start = old.acquire(owner);
      await entered.future;
      final retiring = old.retireForErasure();
      try {
        expect(await old.acquire(Object()), isFalse);
        expect(native.verified, 0);
      } finally {
        release.complete(true);
        await start;
      }
      final receipt = await retiring;
      expect(native.verified, 1);
      await receipt.releaseNativeAdmission();
      receipt.publishFreshLifetime();
      final fresh = CallNetworkActivity.shared;
      expect(identical(fresh, old), isFalse);
      await old.release(owner);
      expect(calls, [true]);
      expect(await old.acquire(owner), isFalse);
      final next = Object();
      expect(await fresh.acquire(next), isTrue);
      await fresh.release(next);
      expect(calls, [true, true, false]);
      receipt.publishFreshLifetime();
      expect(identical(CallNetworkActivity.shared, fresh), isTrue);
    },
  );

  test(
    'native resource refusal cannot be inferred away from empty desired owners',
    () async {
      native.held = true;
      final old = CallNetworkActivity.shared;
      await expectLater(old.retireForErasure(), throwsStateError);
      expect(await old.acquire(Object()), isFalse);
      native.held = false;
      final receipt = await old.retireForErasure();
      expect(identical(await old.retireForErasure(), receipt), isTrue);
      await receipt.releaseNativeAdmission();
      receipt.publishFreshLifetime();
    },
  );

  test(
    'an injected coordinator without a native retirement port refuses',
    () async {
      final activity = CallNetworkActivity(setActive: (on) async => on);
      await expectLater(activity.retireForErasure(), throwsStateError);
    },
  );

  test(
    'lost native release reply does not publish admission until retry',
    () async {
      final old = CallNetworkActivity.shared;
      final receipt = await old.retireForErasure();
      native.loseRelease = true;
      await expectLater(receipt.releaseNativeAdmission(), throwsStateError);
      expect(receipt.publishFreshLifetime, throwsStateError);
      expect(identical(CallNetworkActivity.shared, old), isTrue);
      await receipt.releaseNativeAdmission();
      receipt.publishFreshLifetime();
      expect(native.releases, 2);
    },
  );

  test('foreign publication cannot replace a newer Dart facade', () async {
    final receipt = await CallNetworkActivity.shared.retireForErasure();
    await receipt.releaseNativeAdmission();
    CallNetworkActivity.debugReset();
    final fresh = CallNetworkActivity.shared;
    expect(receipt.publishFreshLifetime, throwsStateError);
    expect(identical(CallNetworkActivity.shared, fresh), isTrue);
  });

  test('invalid native retirement token refuses before verification', () async {
    const channel = MethodChannel('xveil/call_network');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return '';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    CallNetworkActivity.debugRetireOverride = null;
    await expectLater(
      CallNetworkActivity.shared.retireForErasure(),
      throwsStateError,
    );
    expect(calls, ['retire']);
  });
  test(
    'null platform release reply does not clear possible native ownership',
    () async {
      const channel = MethodChannel('xveil/call_network');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <bool>[];
      var held = false, releases = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'setActive');
        final active = (call.arguments as Map)['active'] as bool;
        calls.add(active);
        if (!active && ++releases == 1) return null;
        held = active;
        return active;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      CallNetworkActivity.debugSetActiveOverride = null;
      final old = CallNetworkActivity.shared;
      final owner = Object();
      try {
        expect(await old.acquire(owner), isTrue);
        await old.release(owner);
        expect(held, isTrue);
        await old.release(owner);
        expect(held, isFalse);
        expect(calls, [true, false, false]);
      } finally {
        if (held) {
          await old.release(owner);
          if (held) {
            await channel.invokeMethod<bool>('setActive', {'active': false});
          }
        }
      }
    },
    skip: !Platform.isAndroid && !Platform.isMacOS,
  );
}
