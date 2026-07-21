import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/call_audio_route.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('audio calls use earpiece and video calls use speaker', () async {
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
    final router = CallAudioRouter(channel: channel, hasNativePhoneRoute: true);

    expect(await router.useDefaultFor(const CallMedia(audio: true)), isTrue);
    expect(router.route.value, CallAudioRoute.earpiece);
    expect(calls.last.arguments, {'speaker': false});

    expect(
      await router.useDefaultFor(const CallMedia(audio: true, video: true)),
      isTrue,
    );
    expect(router.route.value, CallAudioRoute.speaker);
    expect(calls.last.arguments, {'speaker': true});

    await router.toggle();
    expect(router.route.value, CallAudioRoute.earpiece);
    expect(calls.last.arguments, {'speaker': false});

    await router.release();
    expect(calls.last.method, 'release');
  });

  test('a rejected native route does not lie to the UI', () async {
    const channel = MethodChannel('xveil/test_call_audio_route_failure');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final router = CallAudioRouter(channel: channel, hasNativePhoneRoute: true);

    expect(await router.setRoute(CallAudioRoute.speaker), isFalse);
    expect(router.route.value, CallAudioRoute.earpiece);
  });
}
