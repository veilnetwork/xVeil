import 'package:crypto/crypto.dart' as crypto;
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'local_authentication.dart';

/// Separate namespaces prevent changing cipher policy for an existing key.
/// This port also makes cancellation, write refusal and restart testable without
/// touching a developer's real Keychain/Keystore.
class QuickUnlockSecretStore {
  const QuickUnlockSecretStore();
  FlutterSecureStorage _store(
    bool biometric,
    String key,
  ) => FlutterSecureStorage(
    aOptions: biometric
        ? AndroidOptions.biometric(
            storageNamespace:
                'xveil_quick_bio_v1_${crypto.sha256.convert(utf8.encode(key)).toString().substring(0, 24)}',
            enforceBiometrics: true,
            biometricType: AndroidBiometricType.strongBiometricOnly,
            resetOnError: false,
            migrateOnAlgorithmChange: false,
          )
        : const AndroidOptions(
            storageNamespace: 'xveil_quick_pattern_v1',
            resetOnError: false,
          ),
    iOptions: IOSOptions(
      accountName: biometric ? 'xveil.quick.bio.v1' : 'xveil.quick.pattern.v1',
      accessibility: KeychainAccessibility.unlocked_this_device,
      accessControlFlags: biometric
          ? const [AccessControlFlag.biometryCurrentSet]
          : const [],
    ),
    // Classic macOS Keychain supports the distributed ad-hoc build too.
    // Touch ID is checked explicitly before each read; unlike iOS/Android,
    // the Keychain item itself is protected by the OS account's access control.
    mOptions: MacOsOptions(
      accountName: biometric ? 'xveil.quick.bio.v1' : 'xveil.quick.pattern.v1',
      usesDataProtectionKeychain: false,
      synchronizable: false,
    ),
  );
  Future<String?> read(String key, {bool biometric = false}) =>
      _store(biometric, key).read(key: key);
  Future<void> write(String key, String value, {bool biometric = false}) =>
      _store(biometric, key).write(key: key, value: value);
  Future<void> delete(String key, {bool biometric = false}) =>
      _store(biometric, key).delete(key: key);
  // Darwin containsKey probes synchronizable=true even for a local-only
  // classic Keychain item; macOS rejects that query. A bounded read verifies
  // actual absence using the exact same namespace/options as the write.
  Future<bool> contains(String key, {bool biometric = false}) async =>
      await _store(biometric, key).read(key: key) != null;
}

class StartupUnlockOptions {
  const StartupUnlockOptions({
    this.grid,
    this.system = false,
    this.patternBlocked = false,
  });
  final int? grid;
  final bool system;
  final bool patternBlocked;
  bool get enabled => grid != null || system;
}

/// The short pattern is combined with a random secret in the OS vault and a slow
/// KDF. The resulting authenticated wrapper contains the ORIGINAL strong
/// container password. The container itself is never rekeyed to a short pattern.
/// Both the device secret and wrapper live solely in the OS secret store.
Future<List<int>> _patternKey(Map<String, Object> args) async {
  final kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 210000,
    bits: 256,
  );
  final key = await kdf.deriveKey(
    secretKey: SecretKey([
      ...base64Decode(args['device'] as String),
      ...utf8.encode(args['pattern'] as String),
    ]),
    nonce: base64Decode(args['salt'] as String),
  );
  try {
    return List<int>.from(await key.extractBytes());
  } finally {
    key.destroy();
  }
}

class QuickUnlockVault {
  QuickUnlockVault(this.store, this.scope, this.authentication);
  final QuickUnlockSecretStore store;
  final String scope;
  final LocalScreenAuthentication authentication;
  int _generation = 0;
  Future<void> _tail = Future<void>.value();
  String get _key => 'xveil.quick.v1.$scope';
  String _bioKey(String slot) => '$_key.bio.$slot';
  String _random(int n) =>
      base64Encode(List.generate(n, (_) => Random.secure().nextInt(256)));

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  Future<Map<String, dynamic>?> _read() async {
    final raw = await store.read(_key);
    if (raw == null || raw.length > 16000) return null;
    try {
      final record = jsonDecode(raw);
      if (record is! Map<String, dynamic> ||
          record['v'] != 1 ||
          record['id'] is! String) {
        return null;
      }
      return record;
    } catch (_) {
      return null;
    }
  }

  Future<StartupUnlockOptions> options() async {
    final r = await _read();
    final grid = r?['grid'];
    return StartupUnlockOptions(
      grid: grid == 3 || grid == 4 || grid == 5 ? grid as int : null,
      system: r?['system'] == true,
      patternBlocked: (r?['tries'] as int? ?? 0) >= 10,
    );
  }

  Future<void> configure({
    required String password,
    int? grid,
    List<int>? nodes,
    required bool system,
    bool Function()? stillCurrent,
  }) {
    final generation = ++_generation;
    return _serial(() async {
      final previous = await _read();
      Map<String, dynamic>? pattern;
      if (grid != null) {
        if (nodes == null || nodes.isEmpty) {
          if (previous?['grid'] != grid || previous?['pattern'] is! Map) {
            throw StateError('Pattern confirmation required');
          }
          pattern = Map<String, dynamic>.from(previous!['pattern'] as Map);
          if (pattern['check'] !=
              _passwordCheck(pattern['device'] as String, password)) {
            throw StateError('Fresh pattern confirmation required');
          }
          // An unchanged wrapper still opens the same password. If the caller
          // changed that password, a fresh pattern must be explicitly supplied.
        } else {
          if (!_valid(grid, nodes)) throw ArgumentError('Invalid pattern');
          final device = _random(32), salt = _random(16);
          final key = await compute(_patternKey, <String, Object>{
            'device': device,
            'salt': salt,
            'pattern': '$grid:${nodes.join(',')}',
          });
          try {
            final box = await AesGcm.with256bits().encrypt(
              utf8.encode(password),
              secretKey: SecretKey(key),
              aad: utf8.encode(_key),
            );
            pattern = {
              'device': device,
              'salt': salt,
              'check': _passwordCheck(device, password),
              'n': base64Encode(box.nonce),
              'c': base64Encode(box.cipherText),
              'm': base64Encode(box.mac.bytes),
            };
          } finally {
            key.fillRange(0, key.length, 0);
          }
        }
      }
      if (generation != _generation) {
        throw StateError('Unlock configuration superseded');
      }
      final id = _random(16);
      var published = false;
      bool current() =>
          generation == _generation && (stillCurrent?.call() ?? true);
      if (!current()) throw StateError('Unlock configuration superseded');
      try {
        // Retire the previous authenticated slot before publishing a fresh
        // one. Its new namespace creates a fresh Keystore key even after the
        // old key was invalidated by a change of enrolled biometrics.
        if (previous?['system'] == true || previous?['bioPending'] == true) {
          await _eraseRecords();
        }
        if (!current()) throw StateError('Unlock configuration superseded');
        if (system) {
          // Retain cleanup intent before the protected write. A crash here
          // must not leave an undiscoverable OS credential outside the volume.
          published = true;
          await store.write(
            _key,
            jsonEncode({
              'v': 1,
              'id': id,
              'grid': null,
              'pattern': null,
              'system': false,
              'bioPending': true,
              'bioSlot': id,
            }),
          );
          if ((await _read())?['id'] != id) {
            throw StateError('Cleanup intent not saved');
          }
          final encoded = jsonEncode({'id': id, 'password': password});
          await store.write(_bioKey(id), encoded, biometric: true);
          if (await store.read(_bioKey(id), biometric: true) != encoded) {
            throw StateError('Saved sign-in not verified');
          }
        }
        if (!current()) {
          throw StateError('Unlock configuration superseded');
        }
        published = true;
        await store.write(
          _key,
          jsonEncode({
            'v': 1,
            'id': id,
            'grid': grid,
            'pattern': pattern,
            'system': system,
            if (system) 'bioSlot': id,
            'tries': 0,
            'after': 0,
          }),
        );
        if ((await _read())?['id'] != id) {
          throw StateError('Saved sign-in not verified');
        }
        if (!current()) throw StateError('Unlock configuration superseded');
      } catch (_) {
        if (published) await _eraseRecords();
        rethrow;
      }
    });
  }

  String _passwordCheck(String device, String password) => base64Encode(
    crypto.Hmac(
      crypto.sha256,
      base64Decode(device),
    ).convert(utf8.encode(password)).bytes,
  );

  static bool _valid(int grid, List<int> nodes) =>
      [3, 4, 5].contains(grid) &&
      nodes.length >= 4 &&
      nodes.length <= grid * grid &&
      nodes.toSet().length == nodes.length &&
      nodes.every((n) => n >= 0 && n < grid * grid);

  Future<String?> openPattern(List<int> nodes) {
    final generation = _generation;
    return _serial(() async {
      final r = await _read();
      if (generation != _generation ||
          r == null ||
          r['grid'] is! int ||
          !_valid(r['grid'], nodes) ||
          r['pattern'] is! Map ||
          (r['tries'] as int? ?? 0) >= 10 ||
          (r['after'] as int? ?? 0) > DateTime.now().millisecondsSinceEpoch) {
        return null;
      }
      // Reserve before derivation: killing the app cannot reset the attempt.
      final tries = (r['tries'] as int? ?? 0) + 1;
      r['tries'] = tries;
      r['after'] =
          DateTime.now().millisecondsSinceEpoch +
          (tries < 3
              ? 0
              : (250 * (1 << (tries - 3).clamp(0, 7))).clamp(0, 30000));
      await store.write(_key, jsonEncode(r));
      final p = r['pattern'] as Map;
      final key = await compute(_patternKey, <String, Object>{
        'device': p['device'] as String,
        'salt': p['salt'] as String,
        'pattern': '${r['grid']}:${nodes.join(',')}',
      });
      try {
        final plain = await AesGcm.with256bits().decrypt(
          SecretBox(
            base64Decode(p['c']),
            nonce: base64Decode(p['n']),
            mac: Mac(base64Decode(p['m'])),
          ),
          secretKey: SecretKey(key),
          aad: utf8.encode(_key),
        );
        try {
          if (generation != _generation) return null;
          r['tries'] = 0;
          r['after'] = 0;
          await store.write(_key, jsonEncode(r));
          return generation == _generation ? utf8.decode(plain) : null;
        } finally {
          if (plain is SensitiveBytes) {
            plain.destroy();
          } else {
            plain.fillRange(0, plain.length, 0);
          }
        }
      } on SecretBoxAuthenticationError {
        return null;
      } finally {
        key.fillRange(0, key.length, 0);
      }
    });
  }

  Future<String?> openSystem(String reason) async {
    final generation = _generation;
    final r = await _read();
    if (r?['system'] != true) return null;
    // Windows DPAPI and macOS Keychain protect storage at rest; OS consent is
    // checked separately. Android/iOS also enforce auth on the secret read.
    if (!await authentication.authenticate(reason)) {
      return null;
    }
    final slot = r?['bioSlot'];
    if (slot is! String || slot.length > 64) return null;
    final raw = await store.read(_bioKey(slot), biometric: true);
    if (raw == null ||
        generation != _generation ||
        (await _read())?['id'] != r!['id']) {
      return null;
    }
    final secret = jsonDecode(raw);
    return secret is Map &&
            secret['id'] == r['id'] &&
            secret['password'] is String
        ? secret['password'] as String
        : null;
  }

  Future<void> _eraseRecords() async {
    final record = await _read();
    if (record?['system'] == true || record?['bioPending'] == true) {
      final slot = record?['bioSlot'];
      if (slot is! String || slot.length > 64) {
        throw StateError('Incomplete saved sign-in');
      }
      // Leave a cleanup intent until protected deletion is verified. Even if
      // delete/auth fails, the next wipe still knows that this slot exists.
      await store.write(
        _key,
        jsonEncode({
          'v': 1,
          'id': _random(16),
          'system': false,
          'grid': null,
          'pattern': null,
          'bioPending': true,
          'bioSlot': slot,
        }),
      );
      await store.delete(_bioKey(slot), biometric: true);
      if (await store.contains(_bioKey(slot), biometric: true)) {
        throw StateError('Saved sign-in removal not verified');
      }
    }
    await store.delete(_key);
    if (await store.contains(_key)) {
      throw StateError('Saved sign-in removal not verified');
    }
  }

  Future<void> forget() {
    ++_generation;
    return _serial(_eraseRecords);
  }
}
