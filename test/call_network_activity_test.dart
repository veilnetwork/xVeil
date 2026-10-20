import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_network_activity.dart';

void main() {
  test(
    'repeated acquisition owns one platform activity until the last release',
    () async {
      final calls = <bool>[];
      final activity = CallNetworkActivity(
        setActive: (on) async {
          calls.add(on);
          return on;
        },
      );
      final owner = Object();
      expect(await activity.acquire(owner), isTrue);
      expect(await activity.acquire(owner), isTrue);
      expect(calls, [true]);
      await activity.release(owner);
      await activity.release(owner);
      expect(calls, [true, false]);
      expect(activity.heldBy(owner), isFalse);
    },
  );

  test(
    'late teardown cannot release a newer owner while acquisition is pending',
    () async {
      final entered = Completer<void>();
      final grant = Completer<bool>();
      final calls = <bool>[];
      final activity = CallNetworkActivity(
        setActive: (on) async {
          calls.add(on);
          if (on) {
            entered.complete();
            return grant.future;
          }
          return false;
        },
      );
      final old = Object(), current = Object();
      final first = activity.acquire(old);
      await entered.future;
      final second = activity.acquire(current);
      final retire = activity.release(old);
      grant.complete(true);
      expect(await first, isTrue);
      expect(await second, isTrue);
      await retire;
      expect(activity.heldBy(old), isFalse);
      expect(activity.heldBy(current), isTrue);
      expect(calls, [true]);
      await activity.release(current);
      expect(calls, [true, false]);
    },
  );

  test(
    'cancellation during initial acquisition releases a late native grant',
    () async {
      final entered = Completer<void>();
      final grant = Completer<bool>();
      final calls = <bool>[];
      final activity = CallNetworkActivity(
        setActive: (on) async {
          calls.add(on);
          if (on) {
            entered.complete();
            return grant.future;
          }
          return false;
        },
      );
      final owner = Object();
      final opening = activity.acquire(owner);
      await entered.future;
      final closing = activity.release(owner);
      grant.complete(true);
      await opening;
      await closing;
      expect(activity.heldBy(owner), isFalse);
      expect(calls, [true, false]);
    },
  );

  test(
    'unsupported and failed acquisition retain no owner and can retry',
    () async {
      final calls = <bool>[];
      var attempt = 0;
      final activity = CallNetworkActivity(
        setActive: (on) async {
          calls.add(on);
          if (on && ++attempt == 1) throw StateError('platform unavailable');
          if (on && attempt == 2) return false;
          return on;
        },
      );
      final owner = Object();
      for (var n = 0; n < 2; n++) {
        expect(await activity.acquire(owner), isFalse);
        await activity.release(owner);
      }
      expect(calls, [true, true]);
      expect(await activity.acquire(owner), isTrue);
      await activity.release(owner);
      expect(calls, [true, true, true, false]);
    },
  );

  test(
    'owners use identity and a failed release cannot poison the queue',
    () async {
      final calls = <bool>[];
      var releases = 0;
      final activity = CallNetworkActivity(
        setActive: (on) async {
          calls.add(on);
          if (!on && ++releases == 1) throw StateError('channel closed');
          return on;
        },
      );
      final owner = _EqualOwner(), stranger = _EqualOwner();
      expect(await activity.acquire(owner), isTrue);
      await activity.release(stranger);
      expect(activity.heldBy(owner), isTrue);
      expect(calls, [true]);
      await activity.release(owner);
      expect(await activity.acquire(stranger), isTrue);
      await activity.release(stranger);
      expect(calls, [true, false, true, false]);
    },
  );
}

class _EqualOwner {
  @override
  bool operator ==(Object other) => other is _EqualOwner;
  @override
  int get hashCode => 0;
}
