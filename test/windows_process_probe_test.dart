import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/vpn/windows_process_probe.dart';

class _Calls implements WindowsProcessCalls {
  int opens = 0, polls = 0, closes = 0;
  int handle = 17, error = 0, waited = 258;
  bool closed = true, failOpen = false, failPoll = false, failClose = false;
  @override
  ({int handle, int error}) open(int pid) {
    opens++;
    if (failOpen) throw StateError('synthetic open refusal');
    expect(pid, 77);
    return (handle: handle, error: error);
  }

  @override
  int poll(int handle) {
    polls++;
    expect(handle, 17);
    if (failPoll) throw StateError('synthetic wait refusal');
    return waited;
  }

  @override
  bool close(int handle) {
    closes++;
    expect(handle, 17);
    if (failClose) throw StateError('synthetic close refusal');
    return closed;
  }
}

void main() {
  for (final invalid in [-1, 0, 0x100000000]) {
    test('invalid process id $invalid never reaches native calls', () {
      final calls = _Calls();
      expect(
        WindowsProcessProbe.withCallsForTesting(calls).read(invalid),
        WindowsProcessState.unknown,
      );
      expect(calls.opens, 0);
    });
  }
  for (final error in [0, 5, 6, 87, 299]) {
    test('open result error=$error distinguishes missing PID from unknown', () {
      final calls = _Calls()
        ..handle = 0
        ..error = error;
      expect(
        WindowsProcessProbe.withCallsForTesting(calls).read(77),
        error == 87 ? WindowsProcessState.exited : WindowsProcessState.unknown,
      );
      expect(calls.opens, 1);
      expect(calls.polls, 0);
      expect(calls.closes, 0);
    });
  }
  for (final waited in [0, 258, 128, 0xffffffff, 13]) {
    test(
      'kernel wait $waited closes its one handle and preserves uncertainty',
      () {
        final calls = _Calls()..waited = waited;
        expect(
          WindowsProcessProbe.withCallsForTesting(calls).read(77),
          waited == 0
              ? WindowsProcessState.exited
              : waited == 258
              ? WindowsProcessState.running
              : WindowsProcessState.unknown,
        );
        expect(calls.opens, 1);
        expect(calls.polls, 1);
        expect(calls.closes, 1);
      },
    );
  }
  test('failed native wait still closes the handle exactly once', () {
    final calls = _Calls()..failPoll = true;
    expect(
      WindowsProcessProbe.withCallsForTesting(calls).read(77),
      WindowsProcessState.unknown,
    );
    expect(calls.closes, 1);
  });
  for (final throws in [false, true]) {
    test('unconfirmed handle close throws=$throws cannot issue exit proof', () {
      final calls = _Calls()
        ..waited = 0
        ..closed = false
        ..failClose = throws;
      expect(
        WindowsProcessProbe.withCallsForTesting(calls).read(77),
        WindowsProcessState.unknown,
      );
      expect(calls.closes, 1);
    });
  }
  test('failed native bootstrap is unknown without a fabricated handle', () {
    final calls = _Calls()..failOpen = true;
    expect(
      WindowsProcessProbe.withCallsForTesting(calls).read(77),
      WindowsProcessState.unknown,
    );
    expect(calls.polls, 0);
    expect(calls.closes, 0);
  });
}
