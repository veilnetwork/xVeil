import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/state/messaging_core.dart';

/// The six-hour backoff ceiling, and the one thing that makes it safe.
///
/// The unresolved-peer ceiling was raised from thirty minutes to six hours
/// because a blind re-check of a device that cannot be sealed for was the
/// largest single line in an idle phone's traffic: three siblings away for
/// days, 274 frames queued for them, and every expiry drove the lot — bursts
/// of ~120 sends in six seconds, ~93% of the phone's send events, each one a
/// DHT lookup for a device that is not there.
///
/// A six-hour ceiling is only tolerable because it is NOT how long a returning
/// peer waits: an authenticated delivery ends the backoff outright. Nothing
/// pinned that, and nothing pinned the pairing with the frame lifetime either
/// — the comment beside the constant says so: "Dart has no compile-time assert
/// to hold those two numbers together; they are joined here by name only."
void main() {
  SpaceOpener memOpener() {
    final store = FakeKvLogStore();
    return ({required password, required bool create}) => store;
  }

  test('a frame gets at most ONE blind re-check inside its own lifetime', () {
    expect(
      MessagingService.debugPeerUnresolvedCap,
      MessagingService.debugReplicationMaxAge,
      reason:
          'the ceiling and the frame lifetime are joined by name only. A '
          'ceiling SHORTER than the lifetime buys back the burst this raise '
          'removed; a longer one lets a frame expire without ever being '
          'retried',
    );
    // And the number itself, so a silent drift back to thirty minutes is loud.
    expect(MessagingService.debugPeerUnresolvedCap, const Duration(hours: 6));
  });

  test('an authenticated delivery ends the backoff, however deep it is', () {
    final transport = LoopbackTransport();
    final storage = HiddenVolumeStorage(memOpener());
    final messaging = MessagingService(transport, storage);
    addTearDown(messaging.dispose);

    const peer = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
        'deadbeefdeadbeefdeadbeefdeadbeef';

    // A peer at the ceiling: the deepest the ladder goes.
    messaging.debugArmPeerBackoff(peer, MessagingService.debugPeerUnresolvedCap);
    expect(
      messaging.debugDepositSuppressed(peer),
      isTrue,
      reason: 'the fixture must actually be suppressed, or the clear below '
          'proves nothing',
    );

    messaging.debugNotePeerReachable(peer);

    expect(
      messaging.debugDepositSuppressed(peer),
      isFalse,
      reason:
          'a peer that has just spoken is still being held off. This is what '
          'turns the six-hour ceiling from an admission control into a '
          'six-hour silence toward a peer that is demonstrably back',
    );
  });

  test('hearing from an unrelated peer clears nothing', () {
    final transport = LoopbackTransport();
    final storage = HiddenVolumeStorage(memOpener());
    final messaging = MessagingService(transport, storage);
    addTearDown(messaging.dispose);

    final held = 'aa' * 32;
    final other = 'bb' * 32;

    messaging.debugArmPeerBackoff(held, const Duration(hours: 6));
    messaging.debugNotePeerReachable(other);

    expect(
      messaging.debugDepositSuppressed(held),
      isTrue,
      reason: 'the clear must be about the peer that spoke, not a broadcast',
    );
  });
}
