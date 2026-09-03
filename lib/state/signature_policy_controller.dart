import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/chat.dart' show SignaturePolicy;
import 'device_settings_sync.dart';
import 'identity_scoped_prefs.dart';
import 'providers.dart';

/// PER PROFILE, and it always should have been (audit XV-15). This one decides
/// whether the device answers a "please sign this message" request without
/// asking, so a value inherited from the real profile makes the decoy emit
/// NON-REPUDIABLE proof of authorship — the exact thing the app exists to make
/// deniable. No attacker is needed for that; the user simply switches profile.
String get _kSignaturePolicyKey => identityScopedPrefKey(kSyncSignaturePolicy);

/// Default for [signaturePolicyProvider] and the value used when prefs are
/// unavailable (tests): prompt each time.
const kSignaturePolicyDefault = SignaturePolicy.ask;

/// How this device answers incoming "please sign this message" requests (the
/// author side of the attestation feature). Persisted; default [ask].
///
/// Layout-and-preference only in spirit, but it governs whether we produce a
/// non-repudiable signature, so it lives with the other per-device settings and
/// is read by the messaging service via a resolver callback.
class SignaturePolicyController extends Notifier<SignaturePolicy> {
  bool _userSet = false;

  @override
  SignaturePolicy build() {
    // FOLLOW THE IDENTITY. `identityScopedPrefKey` is the identity function
    // now, and it returns the key unchanged: separation comes from which
    // profile's preference file is open, not from the spelling. So a provider
    // that does not rebuild on a switch simply keeps answering with the
    // previous identity's choice.
    //
    // What that answer decides is whether this device signs an attestation
    // request without asking. A `auto` inherited by B means B's key produces
    // NON-REPUDIABLE proof of authorship for a message its owner never agreed
    // to sign — in a messenger whose whole point is that authorship stays
    // deniable. No attacker is needed; the user switches identity.
    ref.watch(activeIdentityProvider);
    // Riverpod reuses the notifier across a rebuild, so this has to be
    // cleared by hand. Left set, the load below would decline to overwrite
    // the value the PREVIOUS identity chose, which is the whole defect.
    _userSet = false;
    _load();
    // Synchronously the safe answer, until the new profile's file is read.
    return kSignaturePolicyDefault;
  }

  Future<void> _load() async {
    try {
      final prefs = await ref.read(prefsProvider.future);
      if (_userSet) return;
      final raw = prefs.getString(_kSignaturePolicyKey);
      state = SignaturePolicy.values.firstWhere(
        (p) => p.name == raw,
        orElse: () => kSignaturePolicyDefault,
      );
    } catch (_) {
      // No prefs (tests) — keep the default.
    }
  }

  Future<void> set(SignaturePolicy value) async {
    _userSet = true;
    state = value;
    // Device sync: the attestation answer policy is an identity-level choice.
    ref
        .read(deviceSettingsSyncHubProvider)
        .notifyLocalSet(kSyncSignaturePolicy, value.name);
    try {
      final prefs = await ref.read(prefsProvider.future);
      await prefs.setString(_kSignaturePolicyKey, value.name);
    } catch (_) {
      // Persist best-effort.
    }
  }
}

final signaturePolicyProvider =
    NotifierProvider<SignaturePolicyController, SignaturePolicy>(
      SignaturePolicyController.new,
    );
