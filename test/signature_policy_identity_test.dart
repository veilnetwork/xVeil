import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/domain/chat.dart' show SignaturePolicy;
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/signature_policy_controller.dart';

/// Auto-signing must not follow the user from one identity to the next.
///
/// This policy decides whether the device answers "please sign this message"
/// without asking. An `auto` inherited across a switch makes the NEW identity
/// emit a non-repudiable claim of authorship its owner never agreed to — in
/// an app whose point is that authorship stays deniable. No attacker is
/// needed for it; the user switches identity.
///
/// `identityScopedPrefKey` returns the key unchanged: separation comes from
/// which profile's preference file is open. So nothing in the key spelling
/// protects this, and the provider has to follow the identity itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a switch drops the previous identity auto-sign choice', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(activeIdentityProvider.notifier).state = 'alice';
    expect(container.read(signaturePolicyProvider), SignaturePolicy.ask);

    await container
        .read(signaturePolicyProvider.notifier)
        .set(SignaturePolicy.auto);
    expect(container.read(signaturePolicyProvider), SignaturePolicy.auto);

    container.read(activeIdentityProvider.notifier).state = 'bob';
    expect(
      container.read(signaturePolicyProvider),
      SignaturePolicy.ask,
      reason:
          'the second identity would auto-sign an attestation request on a '
          'choice the first identity made',
    );
  });

  /// The reset has to be synchronous. The load is a future, and an
  /// attestation request can arrive in the same turn as the switch.
  test('the safe answer is there before any load completes', () {
    SharedPreferences.setMockInitialValues({'signature_policy': 'auto'});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(activeIdentityProvider.notifier).state = 'alice';
    expect(
      container.read(signaturePolicyProvider),
      SignaturePolicy.ask,
      reason: 'a stored auto was answered before it had been read back',
    );
  });

  /// The user-set flag has to be cleared on a rebuild, or the new identity
  /// could never restore a choice of its OWN.
  ///
  /// Riverpod reuses the notifier across a rebuild, so the flag survives. The
  /// preference store in a test is shared by every identity — in the app each
  /// profile has its own file — so what this can show is that the load runs
  /// again after a switch and applies what it finds. Left set, it declines,
  /// and the setting becomes unreadable for the rest of the session.
  test('a switch lets the load run again', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(activeIdentityProvider.notifier).state = 'alice';
    await container
        .read(signaturePolicyProvider.notifier)
        .set(SignaturePolicy.refuse);

    container.read(activeIdentityProvider.notifier).state = 'bob';
    expect(container.read(signaturePolicyProvider), SignaturePolicy.ask);
    await pumpEventQueue();
    expect(
      container.read(signaturePolicyProvider),
      SignaturePolicy.refuse,
      reason:
          'the load declined because the flag from the previous identity was '
          'still set, so no stored choice can ever be read again',
    );
  });

  /// Vacuity: within one identity the choice must still stick, or the test
  /// above would pass against a controller that always answers `ask`.
  test('within one identity the choice sticks', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(activeIdentityProvider.notifier).state = 'alice';
    await container
        .read(signaturePolicyProvider.notifier)
        .set(SignaturePolicy.refuse);
    expect(container.read(signaturePolicyProvider), SignaturePolicy.refuse);
    // A rebuild for an unrelated reason must not drop it either.
    container.read(activeIdentityProvider.notifier).state = 'alice';
    expect(container.read(signaturePolicyProvider), SignaturePolicy.refuse);
  });
}
