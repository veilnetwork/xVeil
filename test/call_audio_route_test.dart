import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/call_audio_route.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
