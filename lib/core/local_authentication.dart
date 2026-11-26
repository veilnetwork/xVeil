import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

enum LocalAuthenticationFailure {
  cancelled,
  notEnrolled,
  lockedOut,
  unavailable,
  failed,
}

LocalAuthenticationFailure? classifyLocalAuthenticationFailure(Object error) {
  if (error is! LocalAuthException) return null;
  return switch (error.code) {
    LocalAuthExceptionCode.userCanceled ||
    LocalAuthExceptionCode.systemCanceled ||
    LocalAuthExceptionCode.userRequestedFallback ||
    LocalAuthExceptionCode.timeout => LocalAuthenticationFailure.cancelled,
    LocalAuthExceptionCode.noBiometricsEnrolled ||
    LocalAuthExceptionCode.noCredentialsSet =>
      LocalAuthenticationFailure.notEnrolled,
    LocalAuthExceptionCode.temporaryLockout ||
    LocalAuthExceptionCode.biometricLockout =>
      LocalAuthenticationFailure.lockedOut,
    LocalAuthExceptionCode.noBiometricHardware ||
    LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable ||
    LocalAuthExceptionCode.uiUnavailable =>
      LocalAuthenticationFailure.unavailable,
    _ => LocalAuthenticationFailure.failed,
  };
}

/// OS authentication only. No password, container key or biometric template is
/// stored by this adapter. Used for the session cover and before OS-vault reads.
class LocalScreenAuthentication {
  final LocalAuthentication _auth = LocalAuthentication();
  LocalAuthenticationFailure? lastFailure;

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
    lastFailure = null;
    try {
      final accepted = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: defaultTargetPlatform != TargetPlatform.windows,
        persistAcrossBackgrounding: false,
      );
      if (!accepted) lastFailure = LocalAuthenticationFailure.cancelled;
      return accepted;
    } catch (error) {
      lastFailure =
          classifyLocalAuthenticationFailure(error) ??
          LocalAuthenticationFailure.failed;
      return false;
    }
  }
}

final localScreenAuthenticationProvider = Provider<LocalScreenAuthentication>(
  (_) => LocalScreenAuthentication(),
);
final localScreenAuthenticationAvailableProvider = FutureProvider<bool>(
  (ref) => ref.watch(localScreenAuthenticationProvider).available(),
);
