// A platform with no tunnel has not failed to stop one.
//
// Reported from the field: wiping every trace on macOS ended on "Часть данных
// осталась на устройстве — сетевая часть не подтвердила остановку, туннель или
// узел могут работать". There is no tunnel in that build at all: the ad-hoc
// macOS build drops the PacketTunnel extension, because signing the
// networkextension entitlement needs a paid Apple account.
//
// The boundary was answering honestly — `MissingPluginException` becomes
// `unsupported`, "there is no packet engine here" — and `stop()` folded that
// into `error`, which the teardown counted as a leg that did not finish. The
// result was a false alarm on the one screen in the app that has to be
// believed: the one that says whether the data is really gone.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('network.veil.xveil/vpn');

  void answerStopWith(Object? Function() reply) {
    TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'stop') return reply();
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
  }

  test('a build with no packet engine reports unsupported, not error', () async {
    // A handler that is absent raises MissingPluginException, which is exactly
    // what a build without the tunnel extension produces.
    TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);

    final state = await MethodChannelVpnBackend().stop();
    expect(
      state.phase,
      VpnBackendPhase.unsupported,
      reason: 'no engine to stop is not a stop that failed',
    );
  });

  test('a tunnel that refuses to stop is still an error', () async {
    // The control. Without this the test above would pass just as well over a
    // backend that had stopped reporting failures altogether.
    answerStopWith(
      () => <Object?, Object?>{'phase': 'running', 'detail': 'still up'},
    );
    final state = await MethodChannelVpnBackend().stop();
    expect(
      state.phase,
      VpnBackendPhase.error,
      reason: 'a live tunnel after a stop is the case the alarm exists for',
    );
  });

  test('an unreadable answer is an error, not a shrug', () async {
    answerStopWith(() => 'not a map');
    final state = await MethodChannelVpnBackend().stop();
    expect(state.phase, VpnBackendPhase.error);
  });
}
