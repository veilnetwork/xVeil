import 'package:crypto/crypto.dart' as crypto;
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'local_authentication.dart';
import 'storage_unlock_scope.dart';
import '../data/storage/managed_directory_catalog.dart'
    show
        ManagedRootErasure,
        ManagedErasureBinding,
        ManagedErasureRelease,
        ManagedErasureSnapshot;
import '../data/storage/async_kv_log_store.dart' show ManagedErasureScopeLease;

part 'quick_unlock_retirement_impl.dart';

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
            // Native storage initializes fresh namespaces through its
            // marker-less migration path. Keep its target AES-GCM cipher and
            // strong-biometric requirement; a failure must never reset data.
            migrateOnAlgorithmChange: true,
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
  Future<String?> readAuthenticated(
    String key,
    String reason,
    LocalScreenAuthentication authentication,
  ) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      // The native bridge unwraps through a fresh CryptoObject on EVERY read.
      // The plugin's ordinary read caches its unwrapped key in this process.
      return const MethodChannel(
        'xveil/quick_unlock',
      ).invokeMethod<String>('read', {'key': key, 'reason': reason});
    }
    if (!await authentication.authenticate(reason)) return null;
    return read(key, biometric: true);
  }

  Future<void> write(String key, String value, {bool biometric = false}) async {
    await _store(biometric, key).write(key: key, value: value);
    await _persist(key, biometric);
  }

  Future<void> delete(String key, {bool biometric = false}) async {
    await _store(biometric, key).delete(key: key);
    await _persist(key, biometric);
  }

  Future<void> _persist(String key, bool biometric) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    // FSS 10.3.4 uses SharedPreferences.apply(): its reply and subsequent
    // readback only observe RAM. Keep cleanup intents and accepted operations
    // alive until the corresponding native disk writes are confirmed too.
    final confirmed = await const MethodChannel(
      'xveil/quick_unlock',
    ).invokeMethod<bool>('flush', {'key': key, 'biometric': biometric});
    if (confirmed != true) {
      throw StateError('Saved sign-in persistence not confirmed');
    }
  }

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

/// Wrappers recreated by identity/provider changes share the accepted work for
/// the SAME backend instance and scope. Weak entries retain no obsolete scope
/// after all wrappers/jobs disappear. This is UI-isolate coordination; profile
/// file admission remains the cross-process lifetime boundary.
final class _QuickUnlockScopeState {
  int generation = 0;
  bool retired = false, detached = false;
  // Live erasure witnesses only: deleting the public record also removes its
  // biometric-slot address. Retain addresses, never secret values, until this
  // old lifetime detaches so read-only retry can still verify protected slots.
  final erasureBiometricKeys = <String>{};
  int pending = 0;
  Future<void> tail = Future<void>.value();
  static final _backends =
      Expando<Map<String, WeakReference<_QuickUnlockScopeState>>>();
  static _QuickUnlockScopeState forScope(
    QuickUnlockSecretStore store,
    String scope,
  ) {
    final scopes = _backends[store] ??= {};
    final current = scopes[scope]?.target;
    if (current != null) return current;
    scopes.removeWhere((_, reference) => reference.target == null);
    final state = _QuickUnlockScopeState();
    scopes[scope] = WeakReference(state);
    return state;
  }
}

class QuickUnlockVault {
  QuickUnlockVault(this.store, this.scope, this.authentication)
    : _scopeState = _QuickUnlockScopeState.forScope(store, scope);
  final QuickUnlockSecretStore store;
  final String scope;
  final LocalScreenAuthentication authentication;
  final _QuickUnlockScopeState _scopeState;
  int get _generation => _scopeState.generation;
  set _generation(int value) => _scopeState.generation = value;
  String get _key => 'xveil.quick.v1.$scope';
  String _bioKey(String slot) => '$_key.bio.$slot';
  String _random(int n) =>
      base64Encode(List.generate(n, (_) => Random.secure().nextInt(256)));

  Future<T> _serial<T>(Future<T> Function() action) {
    if (_scopeState.detached) {
      return Future.error(StateError('Saved sign-in lifetime retired'));
    }
    _scopeState.pending++;
    final next = _scopeState.tail.then((_) => action()).whenComplete(() {
      _scopeState.pending--;
    });
    _scopeState.tail = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  Future<Map<String, dynamic>?> _read({bool forRemoval = false}) async {
    if (_scopeState.detached) {
      if (forRemoval) throw StateError('Saved sign-in lifetime retired');
      return null;
    }
    final raw = await store.read(_key);
    if (_scopeState.detached) {
      if (forRemoval) throw StateError('Saved sign-in lifetime retired');
      return null;
    }
    if (raw == null) return null;
    try {
      if (raw.length > 16000) throw const FormatException();
      final record = jsonDecode(raw);
      if (record is! Map<String, dynamic> ||
          record['v'] != 1 ||
          record['id'] is! String) {
        throw const FormatException();
      }
      if (forRemoval) {
        // Absence is the only empty answer that authorizes cleanup/replacement.
        // Losing an unreadable record could orphan a protected password slot.
        const fields = {
          'v',
          'id',
          'grid',
          'pattern',
          'system',
          'bioPending',
          'bioSlot',
          'tries',
          'after',
        };
        final slot = record['bioSlot'];
        if (record['v'] is! int ||
            (record['id'] as String).isEmpty ||
            (record['id'] as String).length > 64 ||
            !record.keys.every(fields.contains) ||
            record['system'] is! bool ||
            record.containsKey('bioPending') && record['bioPending'] is! bool ||
            ((record['system'] == true ||
                    record['bioPending'] == true ||
                    slot != null) &&
                (slot is! String || slot.isEmpty || slot.length > 64))) {
          throw const FormatException();
        }
      }
      return record;
    } catch (_) {
      if (forRemoval) throw StateError('Saved sign-in record is unreadable');
      return null;
    }
  }

  Future<StartupUnlockOptions> options() async {
    if (_scopeState.retired) return const StartupUnlockOptions();
    final generation = _generation;
    final r = await _read();
    if (_scopeState.retired || generation != _generation) {
      return const StartupUnlockOptions();
    }
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
    if (_scopeState.retired) {
      return Future.error(StateError('Saved sign-in scope retired'));
    }
    final generation = ++_generation;
    return _serial(() async {
      final previous = await _read(forRemoval: true);
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
          generation == _generation &&
          !_scopeState.retired &&
          (stillCurrent?.call() ?? true);
      if (!current()) throw StateError('Unlock configuration superseded');
      try {
        // Retire the previous authenticated slot before publishing a fresh
        // one. Its new namespace creates a fresh Keystore key even after the
        // old key was invalidated by a change of enrolled biometrics.
        if (previous?['system'] == true ||
            previous?['bioPending'] == true ||
            previous?['bioSlot'] != null) {
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
    if (_scopeState.retired) return Future.value(null);
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
    if (_scopeState.retired) return null;
    final generation = _generation;
    final r = await _read();
    if (_scopeState.retired ||
        generation != _generation ||
        r?['system'] != true) {
      return null;
    }
    final slot = r?['bioSlot'];
    if (slot is! String || slot.length > 64) return null;
    final raw = await store.readAuthenticated(
      _bioKey(slot),
      reason,
      authentication,
    );
    if (raw == null || _scopeState.retired || generation != _generation) {
      return null;
    }
    final current = await _read();
    if (_scopeState.retired ||
        generation != _generation ||
        current?['id'] != r!['id']) {
      return null;
    }
    final secret = jsonDecode(raw);
    return secret is Map &&
            secret['id'] == r['id'] &&
            secret['password'] is String
        ? secret['password'] as String
        : null;
  }

  Future<void> _eraseRecords({void Function()? requireAuthority}) async {
    requireAuthority?.call();
    final record = await _read(forRemoval: true);
    requireAuthority?.call();
    if (record?['bioSlot'] != null) {
      final slot = record?['bioSlot'];
      if (slot is! String || slot.length > 64) {
        throw StateError('Incomplete saved sign-in');
      }
      if (_scopeState.retired) {
        _scopeState.erasureBiometricKeys.add(_bioKey(slot));
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
      requireAuthority?.call();
      await store.delete(_bioKey(slot), biometric: true);
      requireAuthority?.call();
      if (await store.contains(_bioKey(slot), biometric: true)) {
        throw StateError('Saved sign-in removal not verified');
      }
      requireAuthority?.call();
    }
    await store.delete(_key);
    requireAuthority?.call();
    if (await store.contains(_key)) {
      throw StateError('Saved sign-in removal not verified');
    }
    requireAuthority?.call();
  }

  // Bound erasure must still own its removing operation when queued work runs
  // and after every OS await. An already-issued platform call is joined, but
  // loss of ownership cannot authorize another mutation or successful cleanup.
  Future<void> _retireBoundForErasure(void Function() requireAuthority) {
    try {
      requireAuthority();
    } catch (error, trace) {
      return Future.error(error, trace);
    }
    _scopeState.retired = true;
    ++_generation;
    return _serial(() => _eraseRecords(requireAuthority: requireAuthority));
  }

  /// Only after a durable profile-erasure intent. Existing wrappers cannot
  /// re-enroll this scope after verified deletion. The enclosing wipe keeps its
  /// retirement owner alive until finalization; fresh-profile reopening needs
  /// a separate completion protocol, not an ordinary forget/configure cycle.
  Future<void> retireForErasure() {
    _scopeState.retired = true;
    return forget();
  }

  Future<void> forget() {
    ++_generation;
    return _serial(_eraseRecords);
  }
}
