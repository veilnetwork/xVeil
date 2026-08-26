import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/vpn/packet_tunnel_ffi.dart';

/// The engine holds ONE tunnel slot. A start that finds it occupied answers
/// `VEIL_ERR_REENTRANT`, which the app showed as "the previous run's tunnel is
/// still closing, try again in a moment".
///
/// On a phone that sentence was false. The VPN was stopped from the UI, and
/// every start after it was refused the same way for five minutes: the stop had
/// left a worker in the slot, and nothing on any later path took it out. The
/// person is told to wait for something that already finished, on a screen
/// where waiting is the only thing offered.
void main() {
  test('a start that succeeds is not retried', () {
    var starts = 0;
    var stops = 0;
    final code = startEngineRecoveringStaleSlot(
      start: () {
        starts += 1;
        return 0;
      },
      stop: () {
        stops += 1;
        return 0;
      },
    );

    expect(code, 0);
    expect(starts, 1);
    expect(stops, 0, reason: 'a working engine must never be stopped');
  });

  test('a refusal that is NOT the stale slot is reported as it came', () {
    var stops = 0;
    for (final refusal in [
      PacketTunnelFfi.errGeneric,
      PacketTunnelFfi.errInvalidArgument,
      PacketTunnelFfi.errClosed,
    ]) {
      final code = startEngineRecoveringStaleSlot(
        start: () => refusal,
        stop: () {
          stops += 1;
          return 0;
        },
      );
      expect(code, refusal);
    }
    expect(stops, 0, reason: 'only an occupied slot is something to clear');
  });

  test('an occupied slot is cleared and the start tried again', () {
    final calls = <String>[];
    var starts = 0;
    final code = startEngineRecoveringStaleSlot(
      start: () {
        calls.add('start');
        starts += 1;
        return starts == 1 ? PacketTunnelFfi.errReentrant : 0;
      },
      stop: () {
        calls.add('stop');
        return 0;
      },
    );

    expect(code, 0, reason: 'the retry is what makes the VPN startable again');
    // Order matters: stopping AFTER the second start would clear the tunnel we
    // just made.
    expect(calls, ['start', 'stop', 'start']);
  });

  test('a slot that stays occupied is reported, not spun on', () {
    var starts = 0;
    var stops = 0;
    final code = startEngineRecoveringStaleSlot(
      start: () {
        starts += 1;
        return PacketTunnelFfi.errReentrant;
      },
      stop: () {
        stops += 1;
        return 0;
      },
    );

    expect(code, PacketTunnelFfi.errReentrant);
    expect(starts, 2, reason: 'one retry, not a loop');
    expect(stops, 1);
  });

  test('the reentrant code still has its own name for the screen', () {
    // Vacuity guard for the tests above: if recovery ever swallowed the code,
    // the sentence a person reads would go back to being unnamed.
    expect(
      PacketTunnelFfi.failureFor(PacketTunnelFfi.errReentrant),
      isNotNull,
    );
  });
}
