import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/call_audio_route.dart';
import 'package:xveil/core/diagnostic_journal.dart';

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();
}

class _RoutePort {
  static const channel = MethodChannel('xveil/route_lifetime_test');
  static final unspecified = Object();
  final calls = <String>[];
  final gates = <_Gate>[];
  _Gate? nextSet;
  _Gate? nextRelease;
  Object? nextReply = unspecified;
  Object? nextFailure;
  CallAudioRoute? hardware;

  _RoutePort() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handle);
  }

  _Gate holdSet() {
    final gate = _Gate();
    gates.add(gate);
    return nextSet = gate;
  }

  _Gate holdRelease() {
    final gate = _Gate();
    gates.add(gate);
    return nextRelease = gate;
  }

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    final failure = nextFailure;
    nextFailure = null;
    final gate = call.method == 'setRoute' ? nextSet : nextRelease;
    Object? reply;
    if (call.method == 'setRoute') {
      nextSet = null;
      final args = call.arguments as Map;
      final wanted = args['speaker'] == true
          ? CallAudioRoute.speaker
          : CallAudioRoute.earpiece;
      reply = identical(nextReply, unspecified) ? wanted.name : nextReply;
      nextReply = unspecified;
      if (failure == null) {
        if (reply == true) hardware = wanted;
        if (reply is String) {
          for (final route in CallAudioRoute.values) {
            if (route.name == reply) hardware = route;
          }
        }
      }
    } else {
      nextRelease = null;
      hardware = null;
    }
    if (gate != null) {
      gate.entered.complete();
      await gate.release.future;
    }
    if (failure != null) throw failure;
    return reply;
  }

  Future<void> dispose() async {
    for (final gate in gates) {
      if (!gate.release.isCompleted) gate.release.complete();
    }
    await pumpEventQueue();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final reply in [true, 'external']) {
    for (final terminal in ['release', 'replacement']) {
      test('late audio route reply=$reply respects $terminal', () async {
        final port = _RoutePort();
        final router = CallAudioRouter(
          channel: _RoutePort.channel,
          hasNativePhoneRoute: true,
        );
        final gate = port.holdSet();
        port.nextReply = reply;
        final pending = router.setRoute(CallAudioRoute.speaker);
        try {
          await gate.entered.future;
          if (terminal == 'release') {
            await router.release();
          } else {
            expect(await router.setRoute(CallAudioRoute.earpiece), isTrue);
          }
          final current = router.route.value;
          final hardware = port.hardware;
          gate.release.complete();
          expect(await pending, isFalse);
          expect(router.route.value, current);
          expect(port.hardware, hardware);
        } finally {
          if (!gate.release.isCompleted) gate.release.complete();
          await pending;
          await port.dispose();
        }
      });
    }
  }

  for (final next in [
    'speaker',
    'external',
    'audio-default',
    'video-default',
  ]) {
    test('late audio route release preserves $next setup', () async {
      final port = _RoutePort();
      final router = CallAudioRouter(
        channel: _RoutePort.channel,
        hasNativePhoneRoute: true,
      );
      expect(await router.setRoute(CallAudioRoute.speaker), isTrue);
      final gate = port.holdRelease();
      final ending = router.release();
      try {
        await gate.entered.future;
        final CallAudioRoute expected;
        if (next == 'speaker' || next == 'external') {
          expected = next == 'speaker'
              ? CallAudioRoute.speaker
              : CallAudioRoute.external;
          port.nextReply = expected.name;
          expect(await router.setRoute(expected), isTrue);
        } else {
          final video = next == 'video-default';
          expected = video ? CallAudioRoute.speaker : CallAudioRoute.earpiece;
          expect(
            await router.useDefaultFor(CallMedia(audio: true, video: video)),
            isTrue,
          );
        }
        final before = port.hardware;
        gate.release.complete();
        await ending;
        final routeAfter = router.route.value;
        final calls = port.calls.length;
        expect(
          await router.useDefaultFor(const CallMedia(audio: true)),
          isTrue,
        );
        expect(
          {
            'hardware_before_old_reply': before,
            'route_after_old_reply': routeAfter,
            'hardware_after_default': port.hardware,
            'setup_commands': calls,
            'commands_after_default': port.calls.length,
          },
          {
            'hardware_before_old_reply': expected,
            'route_after_old_reply': expected,
            'hardware_after_default': expected,
            'setup_commands': 3,
            'commands_after_default': 3,
          },
        );
      } finally {
        if (!gate.release.isCompleted) gate.release.complete();
        await ending;
        await port.dispose();
      }
    });
  }

  for (final native in [true, false]) {
    for (final action in ['release', 'default']) {
      test(
        'route notifier $action respects active state native=$native',
        () async {
          final port = _RoutePort();
          final router = CallAudioRouter(
            channel: _RoutePort.channel,
            hasNativePhoneRoute: native,
          );
          var handled = false;
          Future<void>? ending;
          Future<bool>? defaulting;
          void listener() {
            if (handled || router.route.value != CallAudioRoute.speaker) return;
            handled = true;
            if (action == 'release') {
              ending = router.release();
            } else {
              defaulting = router.useDefaultFor(const CallMedia(audio: true));
            }
          }

          router.route.addListener(listener);
          try {
            final result = await router.setRoute(CallAudioRoute.speaker);
            await ending;
            if (defaulting != null) expect(await defaulting, isTrue);
            final before = router.route.value;
            expect(
              await router.useDefaultFor(
                const CallMedia(audio: true, video: true),
              ),
              isTrue,
            );
            expect(
              {
                'original_result': result,
                'route_before_next_default': before,
                'route_after_next_default': router.route.value,
                'commands': port.calls,
              },
              {
                'original_result': action != 'release',
                'route_before_next_default': action == 'release'
                    ? CallAudioRoute.earpiece
                    : CallAudioRoute.speaker,
                'route_after_next_default': CallAudioRoute.speaker,
                'commands': native
                    ? (action == 'release'
                          ? ['setRoute', 'release', 'setRoute']
                          : ['setRoute'])
                    : <String>[],
              },
            );
          } finally {
            router.route.removeListener(listener);
            await ending;
            await defaulting;
            await port.dispose();
          }
        },
      );
    }
  }

  for (final failure in [false, true]) {
    test(
      'release notification queues a new route after release, failure=$failure',
      () async {
        final port = _RoutePort();
        final router = CallAudioRouter(
          channel: _RoutePort.channel,
          hasNativePhoneRoute: true,
        );
        expect(await router.setRoute(CallAudioRoute.speaker), isTrue);
        final gate = port.holdRelease();
        if (failure) {
          port.nextFailure = PlatformException(code: 'private-route');
        }
        var notified = false;
        Future<bool>? setting;
        void listener() {
          if (notified || router.route.value != CallAudioRoute.earpiece) return;
          notified = true;
          setting = router.setRoute(CallAudioRoute.speaker);
        }

        router.route.addListener(listener);
        final ending = router.release();
        try {
          await gate.entered.future;
          await pumpEventQueue();
          final before = port.hardware;
          final notifiedBefore = notified;
          gate.release.complete();
          await ending;
          if (setting != null) expect(await setting, isTrue);
          expect(
            {
              'notified_before_reply': notifiedBefore,
              'hardware_before_reply': before,
              'route_after_reply': router.route.value,
              'hardware_after_reply': port.hardware,
              'commands': port.calls,
            },
            {
              'notified_before_reply': true,
              'hardware_before_reply': CallAudioRoute.speaker,
              'route_after_reply': CallAudioRoute.speaker,
              'hardware_after_reply': CallAudioRoute.speaker,
              'commands': ['setRoute', 'release', 'setRoute'],
            },
          );
        } finally {
          if (!gate.release.isCompleted) gate.release.complete();
          router.route.removeListener(listener);
          await ending;
          await setting;
          await port.dispose();
        }
      },
    );
  }

  for (final missing in [false, true]) {
    test(
      'retired route error cannot replace current diagnostics missing=$missing',
      () async {
        final port = _RoutePort(), journal = DiagnosticJournal(enabled: true);
        final router = CallAudioRouter(
          channel: _RoutePort.channel,
          hasNativePhoneRoute: true,
          diagnostics: journal,
        );
        final gate = port.holdSet();
        port.nextFailure = missing
            ? MissingPluginException('private-route')
            : PlatformException(code: 'private-route');
        final pending = router.setRoute(CallAudioRoute.speaker);
        try {
          await gate.entered.future;
          port.nextReply = 'external';
          expect(await router.setRoute(CallAudioRoute.external), isTrue);
          final before = jsonEncode(journal.toJson());
          gate.release.complete();
          expect(await pending, isFalse);
          expect(jsonEncode(journal.toJson()), before);
          expect(router.route.value, CallAudioRoute.external);
        } finally {
          if (!gate.release.isCompleted) gate.release.complete();
          await pending;
          await port.dispose();
        }
      },
    );
  }

  test(
    'route reports contain an outcome and category, never a device label',
    () async {
      const channel = MethodChannel('xveil/test_route_diagnostics');
      var reply = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            if (reply == 0) return 'external';
            throw PlatformException(
              code: 'private-headset-name',
              message: 'private user',
            );
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final journal = DiagnosticJournal(enabled: true);
      final router = CallAudioRouter(
        channel: channel,
        hasNativePhoneRoute: true,
        diagnostics: journal,
      );
      expect(await router.useDefaultFor(const CallMedia(audio: true)), isTrue);
      reply = 1;
      expect(await router.setRoute(CallAudioRoute.speaker), isFalse);
      final rows = journal.toJson()['events'] as List;
      expect((rows.first as Map)['values'], {
        'supported': 1,
        'success': 1,
        'state': CallAudioRoute.external.index,
        'code': 0,
      });
      expect((rows.last as Map)['values'], {
        'supported': 1,
        'success': 0,
        'state': CallAudioRoute.external.index,
        'code': 1,
      });
      expect(journal.toJson().toString(), isNot(contains('private')));
    },
  );

  test(
    'camera upgrades keep audio route; a new video call uses speaker',
    () async {
      const channel = MethodChannel('xveil/test_call_audio_route');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'setRoute' ? true : null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final router = CallAudioRouter(
        channel: channel,
        hasNativePhoneRoute: true,
      );

      expect(await router.useDefaultFor(const CallMedia(audio: true)), isTrue);
      expect(router.route.value, CallAudioRoute.earpiece);
      expect(calls.last.arguments, {'speaker': false, 'preferExternal': true});

      expect(
        await router.useDefaultFor(const CallMedia(audio: true, video: true)),
        isTrue,
      );
      expect(router.route.value, CallAudioRoute.earpiece);
      expect(calls, hasLength(1)); // No device switch during the active call.

      await router.release();
      expect(calls.last.method, 'release');
      expect(
        await router.useDefaultFor(const CallMedia(audio: true, video: true)),
        isTrue,
      );
      expect(router.route.value, CallAudioRoute.speaker);
      expect(calls.last.arguments, {'speaker': true, 'preferExternal': true});

      await router.toggle();
      expect(router.route.value, CallAudioRoute.earpiece);
      expect(calls.last.arguments, {'speaker': false, 'preferExternal': true});

      await router.release();
      expect(calls.last.method, 'release');
    },
  );

  test(
    'headphones survive audio/video defaults and explicit speaker works',
    () async {
      const channel = MethodChannel('xveil/test_call_audio_headphones');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'release') return null;
            final args = call.arguments as Map;
            return args['preferExternal'] == true ? 'external' : 'speaker';
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final router = CallAudioRouter(
        channel: channel,
        hasNativePhoneRoute: true,
      );
      for (final media in [
        const CallMedia(audio: true),
        const CallMedia(audio: true, video: true),
        const CallMedia(audio: true, screen: true),
      ]) {
        expect(await router.useDefaultFor(media), isTrue);
        expect(router.route.value, CallAudioRoute.external);
      }
      expect(calls, hasLength(1));
      expect(await router.toggle(), isTrue);
      expect(router.route.value, CallAudioRoute.speaker);
      expect(calls.last.arguments, {'speaker': true});
      final routeCalls = calls.length;
      expect(
        await router.useDefaultFor(const CallMedia(audio: true, video: true)),
        isTrue,
      );
      expect(router.route.value, CallAudioRoute.speaker);
      expect(calls, hasLength(routeCalls)); // Preserve the user's selection.
      expect(await router.toggle(), isTrue);
      expect(router.route.value, CallAudioRoute.external);
      await router.release();
      expect(router.route.value, CallAudioRoute.earpiece);
    },
  );

  test('a rejected native route does not lie to the UI', () async {
    const channel = MethodChannel('xveil/test_call_audio_route_failure');
    var allowed = false;
    var attempts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          attempts++;
          return allowed;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final router = CallAudioRouter(channel: channel, hasNativePhoneRoute: true);

    expect(await router.setRoute(CallAudioRoute.speaker), isFalse);
    expect(router.route.value, CallAudioRoute.earpiece);
    allowed = true;
    expect(
      await router.useDefaultFor(const CallMedia(audio: true, video: true)),
      isTrue,
    );
    expect(attempts, 2); // Failed setup did not suppress the next attempt.
    expect(router.route.value, CallAudioRoute.speaker);
  });
}
