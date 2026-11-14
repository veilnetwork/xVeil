import 'dart:async';
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/core/quick_unlock_vault.dart';

class RetirementAuthentication extends LocalScreenAuthentication {
  @override
  Future<bool> authenticate(String reason) async => true;
}

/// In-memory OS port. Never delegates any operation to Keychain/Keystore.
class RetirementSecretStore extends QuickUnlockSecretStore {
  final values = <String, String>{};
  final deniedScopes = <String>{};
  String? heldScope;
  Completer<void>? writeEntered, writeRelease;
  int reads = 0;
  String _key(String key, bool biometric) => '$biometric:$key';
  @override
  Future<String?> read(String key, {bool biometric = false}) async {
    reads++;
    return values[_key(key, biometric)];
  }

  @override
  Future<String?> readAuthenticated(
    String key,
    String reason,
    LocalScreenAuthentication authentication,
  ) => read(key, biometric: true);
  @override
  Future<void> write(String key, String value, {bool biometric = false}) async {
    if (biometric && heldScope != null && key.contains(heldScope!)) {
      if (!writeEntered!.isCompleted) writeEntered!.complete();
      await writeRelease!.future;
    }
    values[_key(key, biometric)] = value;
  }

  @override
  Future<void> delete(String key, {bool biometric = false}) async {
    if (deniedScopes.any(key.contains)) return; // Lying success must not pass.
    values.remove(_key(key, biometric));
  }

  @override
  Future<bool> contains(String key, {bool biometric = false}) async =>
      values.containsKey(_key(key, biometric));
}
