import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/chat.dart' show SignaturePolicy;
import 'device_settings_sync.dart';
import 'providers.dart';

const _kSignaturePolicyKey = kSyncSignaturePolicy;

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
    _load();
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
