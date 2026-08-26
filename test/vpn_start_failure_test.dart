import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/network/vpn_failure_text.dart';
import 'package:xveil/l10n/app_localizations_ru.dart';
import 'package:xveil/data/vpn/packet_tunnel_ffi.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';

/// The packet engine answers a refusal with a DISTINCT code — already running,
/// bad argument, closed — and the app tested only `!= 0`, then asked
/// `veil_packet_tunnel_last_error()`. That error slot belongs to the tunnel
/// OBJECT, so every refusal that happens before the object exists reads back
/// null and the app printed "could not start packet tunnel": a sentence naming
/// nothing, in English, on a Russian screen.
///
/// It mattered on a real phone. Repeated start attempts failed while a tunnel
/// from the previous attempt was still tearing down — which the engine reports
/// as `VEIL_ERR_REENTRANT`, i.e. "wait a moment and try again". Told only that
/// the engine had failed, I went looking at exit chains instead.
void main() {
  test('every engine code the app can meet is named', () {
    expect(
      PacketTunnelFfi.failureFor(0),
      isNull,
      reason: 'success is not a failure',
    );
    expect(
      PacketTunnelFfi.failureFor(PacketTunnelFfi.errReentrant),
      VpnStartFailure.alreadyRunning,
      reason: 'the one where waiting IS the fix must be distinguishable',
    );
    expect(
      PacketTunnelFfi.failureFor(PacketTunnelFfi.errInvalidArgument),
      VpnStartFailure.invalidArgument,
    );
    expect(
      PacketTunnelFfi.failureFor(PacketTunnelFfi.errClosed),
      VpnStartFailure.closed,
    );
    expect(
      PacketTunnelFfi.failureFor(PacketTunnelFfi.errGeneric),
      VpnStartFailure.refused,
    );
  });

  test('a code this build has not heard of is still a refusal', () {
    // Never null for a non-zero code: "it refused, cause unknown" beats
    // silence, and silence is what the old path produced.
    expect(PacketTunnelFfi.failureFor(-99), VpnStartFailure.refused);
    expect(PacketTunnelFfi.failureFor(7), VpnStartFailure.refused);
  });

  test('the four codes do not collapse into one answer', () {
    // Vacuity guard: a mapping that returned `refused` for everything would
    // satisfy every assertion above except this one.
    final named = {
      PacketTunnelFfi.failureFor(PacketTunnelFfi.errReentrant),
      PacketTunnelFfi.failureFor(PacketTunnelFfi.errInvalidArgument),
      PacketTunnelFfi.failureFor(PacketTunnelFfi.errClosed),
      PacketTunnelFfi.failureFor(PacketTunnelFfi.errGeneric),
    };
    expect(named.length, 4);
  });

  test('the state carries the reason alongside the log line', () {
    const state = VpnBackendState(
      VpnBackendPhase.error,
      detail: 'packet engine refused to start (code -4)',
      failure: VpnStartFailure.alreadyRunning,
    );
    expect(state.failure, VpnStartFailure.alreadyRunning);
    expect(
      state.detail,
      contains('-4'),
      reason: 'the raw code stays for a log; the named reason is for a person',
    );
  });

  /// Naming the reason was meant to ADD to what a person is told. The tunnel
  /// that dies AFTER starting records why it died, and that message is
  /// readable because its object still exists — so the branch with no named
  /// reason must keep showing it rather than replacing it with a generic
  /// sentence. (Caught on myself: the first version of this fix hid it.)
  group('a real message is never replaced by a generic one', () {
    final l = AppL10nRu();

    test('a named reason wins', () {
      const state = VpnBackendState(
        VpnBackendPhase.error,
        detail: 'packet engine refused to start (code -4)',
        failure: VpnStartFailure.alreadyRunning,
      );
      expect(vpnStartFailureText(l, state), l.vpnStartAlreadyRunning);
    });

    test('without one, the engine words are still shown', () {
      const state = VpnBackendState(
        VpnBackendPhase.error,
        detail: 'packet tunnel failed: no route to exit node',
      );
      expect(
        vpnStartFailureText(l, state),
        'packet tunnel failed: no route to exit node',
        reason: 'the worker recorded WHY it died; hiding that helps nobody',
      );
    });

    test('with neither, a generic sentence is all there is', () {
      const state = VpnBackendState(VpnBackendPhase.error);
      expect(vpnStartFailureText(l, state), l.vpnStatusError);
    });
  });
}
