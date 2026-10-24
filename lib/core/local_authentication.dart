import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

/// OS authentication only. No password, container key or biometric template is
/// stored by this adapter. Used for the session cover and before OS-vault reads.
class LocalScreenAuthentication {
  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> available() async {
    try {
      // Windows Hello chooses the OS mechanism; the other implementations can
      // require an enrolled biometric rather than a device PIN fallback.
      if (defaultTargetPlatform == TargetPlatform.windows) {
        return await _auth.isDeviceSupported();
      }
      return await _auth.canCheckBiometrics &&
          (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: defaultTargetPlatform != TargetPlatform.windows,
        persistAcrossBackgrounding: false,
      );
    } catch (_) {
      return false; // cancelled, locked out, unavailable: password still works
    }
  }
}

final localScreenAuthenticationProvider = Provider<LocalScreenAuthentication>(
  (_) => LocalScreenAuthentication(),
);
final localScreenAuthenticationAvailableProvider = FutureProvider<bool>(
  (ref) => ref.watch(localScreenAuthenticationProvider).available(),
);
