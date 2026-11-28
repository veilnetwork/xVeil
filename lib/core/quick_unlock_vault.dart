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
import 'saved_entry_addresses.dart';
import '../data/storage/managed_directory_catalog.dart'
    show
        ManagedRootErasure,
        ManagedErasureBinding,
        ManagedErasureRelease,
        ManagedErasureSnapshot;
import '../data/storage/async_kv_log_store.dart' show ManagedErasureScopeLease;

part 'quick_unlock_retirement_impl.dart';
part 'quick_unlock_absence_witness.dart';

enum QuickUnlockVaultFailure {
  cancelled,
  notEnrolled,
  lockedOut,
  protectionChanged,
  unavailable,
}

enum _EnrollmentStep {
  readPrevious('1'),
  removePrevious('2'),
  writeIntent('3'),
  verifyIntent('4'),
  writeBiometric('5'),
  verifyBiometric('6'),
  writeRecord('7'),
  verifyRecord('8');

  const _EnrollmentStep(this.code);
  final String code;
}

/// A diagnostic reference for the settings screen. It contains no values
/// supplied by the caller or free-form text from Android.
class QuickUnlockEnrollmentFailure implements Exception {
  QuickUnlockEnrollmentFailure._(
    _EnrollmentStep step,
    Object error, {
    required bool cleanupFailed,
  }) : reason = classifyQuickUnlockVaultFailure(error),
       reference =
           'QU-${step.code}-${_enrollmentErrorCode(error)}'
           '${cleanupFailed ? '-C' : ''}';

  final QuickUnlockVaultFailure? reason;
  final String reference;
}

final _androidPromptError = RegExp(
  r'Biometric authentication error \[(\d{1,2})\]:',
);

Match? _biometricPromptError(PlatformException error) {
  final prompt = _androidPromptError.matchAsPrefix(error.message ?? '');
  if (prompt != null) return prompt;
  final details = error.details;
  // The Android plugin wraps prompt errors when its fresh namespace takes
  // the migration path. Its stack text still contains the original cause.
  return details is String ? _androidPromptError.firstMatch(details) : null;
}

String _enrollmentErrorCode(Object error) {
  if (error is MissingPluginException) return 'BRIDGE';
  if (error is! PlatformException) return 'VERIFY';
  if (error.code == 'Exception encountered') {
    final number = _biometricPromptError(error)?[1];
    return number == null ? 'ANDROID' : 'B$number';
  }
  return switch (error.code) {
    'record_store_unreadable' => 'DATA',
    'record_operation_failed' => switch (error.details) {
      'FORMAT' => 'STORE-FORMAT',
      'WRAPPED' => 'STORE-WRAPPED',
      'KEY' => 'STORE-KEY',
      'KEY_UNAVAILABLE' => 'STORE-KEY-UNAVAILABLE',
      'PAYLOAD' => 'STORE-PAYLOAD',
      'CHANGED' => 'STORE-CHANGED',
      _ => 'STORE',
    },
    'persistence_failed' => 'DISK',
    'INIT_FAILED' => 'INIT',
    _ => 'OS',
  };
}

QuickUnlockVaultFailure? classifyQuickUnlockVaultFailure(Object error) {
  if (error is QuickUnlockEnrollmentFailure) return error.reason;
  if (error is! PlatformException) return null;
  if (error.code == 'Unexpected security result code') {
    return switch (error.details) {
      -128 => QuickUnlockVaultFailure.cancelled, // errSecUserCanceled
      -25291 || -25308 || -34018 => QuickUnlockVaultFailure.unavailable,
      _ => null,
    };
  }
  if (error.code == 'INIT_FAILED' ||
      error.code == 'record_store_unreadable' ||
      error.code == 'record_operation_failed') {
    return QuickUnlockVaultFailure.unavailable;
  }
  if (error.code != 'Exception encountered') return null;

  // flutter_secure_storage's Android backend forwards the prompt number in a
  // fixed prefix, followed by localized system text. Discard the latter.
  final message = error.message ?? '';
  final match = _biometricPromptError(error);
  if (match != null) {
    return switch (int.parse(match[1]!)) {
      3 || 5 || 10 || 13 => QuickUnlockVaultFailure.cancelled,
      7 || 9 => QuickUnlockVaultFailure.lockedOut,
      11 || 14 => QuickUnlockVaultFailure.notEnrolled,
      1 || 12 || 15 => QuickUnlockVaultFailure.unavailable,
      _ => null,
    };
  }
  if (message.startsWith(
    'BIOMETRIC_UNAVAILABLE: No fingerprint or face enrolled.',
  )) {
    return QuickUnlockVaultFailure.notEnrolled;
  }
  if (message.startsWith('BIOMETRIC_UNAVAILABLE:')) {
    return QuickUnlockVaultFailure.unavailable;
  }
  final details = error.details;
  if (details is String &&
      details.contains(
        'android.security.keystore.KeyPermanentlyInvalidatedException',
      )) {
    return QuickUnlockVaultFailure.protectionChanged;
  }
  return null;
}

/// Separate namespaces prevent changing cipher policy for an existing key.
/// This port also makes cancellation, write refusal and restart testable without
/// touching a developer's real Keychain/Keystore.
class QuickUnlockSecretStore {
  const QuickUnlockSecretStore();
  FlutterSecureStorage _store(
    bool biometric,
    String key, {
    String? publicNamespace,
  }) => FlutterSecureStorage(
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
        : AndroidOptions(
            storageNamespace: publicNamespace ?? 'xveil_quick_pattern_v1',
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
  Future<String?> read(String key, {bool biometric = false}) {
    if (defaultTargetPlatform == TargetPlatform.android && !biometric) {
      // Public metadata reads never initialize, reset or migrate Android keys.
      // An absent record is null; unavailable/corrupt storage is an error.
      return const MethodChannel(
        'xveil/quick_unlock',
      ).invokeMethod<String>('readPublic', {'key': key, 'biometric': false});
    }
    return _store(biometric, key).read(key: key);
  }

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
    String? namespace;
    if (defaultTargetPlatform == TargetPlatform.android && !biometric) {
      namespace = await const MethodChannel('xveil/quick_unlock')
          .invokeMethod<String>('publicWriteNamespace', {
            'key': key,
            'biometric': false,
          });
      final digest = crypto.sha256.convert(utf8.encode(key)).toString();
      final scope = digest.substring(0, 24);
      if (namespace != 'xveil_quick_pattern_v1' &&
          namespace != 'xveil_quick_pattern_v2_$scope' &&
          !RegExp(
            '^xveil_quick_pattern_v3_${scope}_[0-9a-f]{32}\$',
          ).hasMatch(namespace ?? '')) {
        throw StateError('Saved sign-in destination not confirmed');
      }
    }
    await _store(
      biometric,
      key,
      publicNamespace: namespace,
    ).write(key: key, value: value);
    await _persist(key, biometric, namespace);
  }

  Future<bool> repairAndroidRecord(String key) async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    return await const MethodChannel('xveil/quick_unlock').invokeMethod<bool>(
          'repairPublic',
          {'key': key, 'biometric': false},
        ) ==
        true;
  }

  Future<void> delete(String key, {bool biometric = false}) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final removed = await const MethodChannel(
        'xveil/quick_unlock',
      ).invokeMethod<bool>('remove', {'key': key, 'biometric': biometric});
      if (removed != true) {
        throw StateError('Saved sign-in removal not confirmed');
      }
      return;
    }
    await _store(biometric, key).delete(key: key);
  }

  Future<void> _persist(
    String key,
    bool biometric,
    String? publicNamespace,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    // FSS 10.3.4 uses SharedPreferences.apply(): its reply and subsequent
    // readback only observe RAM. Keep cleanup intents and accepted operations
    // alive until the corresponding native disk writes are confirmed too.
    final confirmed = await const MethodChannel('xveil/quick_unlock')
        .invokeMethod<bool>('flush', {
          'key': key,
          'biometric': biometric,
          'publicNamespace': ?publicNamespace,
        });
    if (confirmed != true) {
      throw StateError('Saved sign-in persistence not confirmed');
    }
  }

  Future<bool> contains(String key, {bool biometric = false}) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      // FSS initializes its cipher before containsKey/read/delete. Presence
      // and explicit removal need no plaintext or biometric authentication.
      final present = await const MethodChannel(
        'xveil/quick_unlock',
      ).invokeMethod<bool>('contains', {'key': key, 'biometric': biometric});
      if (present == null) {
        throw StateError('Saved sign-in presence not confirmed');
      }
      return present;
    }
    // Darwin containsKey probes synchronizable=true even for a local-only
    // classic Keychain item; macOS rejects that query. Keep the matching read.
    return await _store(biometric, key).read(key: key) != null;
  }
}

class StartupUnlockOptions {
  const StartupUnlockOptions({
    this.grid,
    this.system = false,
    this.patternBlocked = false,
    this.requiresReview = false,
  });
  final int? grid;
  final bool system;
  final bool patternBlocked;

  /// Consent exists, but there is no confirmed method for startup sign-in.
  final bool requiresReview;
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
    if (forRemoval) {
      final present = await store.contains(_key);
      if (_scopeState.detached) {
        throw StateError('Saved sign-in lifetime retired');
      }
      if (!present) return null;
    }
    final raw = await store.read(_key);
    if (_scopeState.detached) {
      if (forRemoval) throw StateError('Saved sign-in lifetime retired');
      return null;
    }
    if (raw == null) {
      if (forRemoval) {
        throw StateError('Saved sign-in record changed during removal');
      }
      return null;
    }
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
          'cleanupBioSlot',
          'tries',
          'after',
        };
        final slot = record['bioSlot'];
        final cleanup = record['cleanupBioSlot'];
        if (record['v'] is! int ||
            (record['id'] as String).isEmpty ||
            (record['id'] as String).length > 64 ||
            !record.keys.every(fields.contains) ||
            record['system'] is! bool ||
            record.containsKey('bioPending') && record['bioPending'] is! bool ||
            (record.containsKey('cleanupBioSlot') &&
                (cleanup is! String ||
                    cleanup.isEmpty ||
                    cleanup.length > 64 ||
                    cleanup == slot)) ||
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
    bool repairAndroidRecord = false,
    bool Function()? stillCurrent,
  }) {
    if (_scopeState.retired) {
      return Future.error(StateError('Saved sign-in scope retired'));
    }
    final generation = ++_generation;
    return _serial(() async {
      bool current() =>
          generation == _generation &&
          !_scopeState.retired &&
          (stillCurrent?.call() ?? true);
      Map<String, dynamic>? previous;
      try {
        previous = await _read(forRemoval: true);
      } catch (error, trace) {
        if (defaultTargetPlatform != TargetPlatform.android ||
            error is StateError) {
          rethrow;
        }
        var repaired = false;
        if (repairAndroidRecord &&
            _canRepairAndroidRecord(error) &&
            (grid == null || (nodes != null && _valid(grid, nodes))) &&
            current()) {
          try {
            repaired = await store.repairAndroidRecord(_key);
          } catch (error, trace) {
            Error.throwWithStackTrace(
              QuickUnlockEnrollmentFailure._(
                _EnrollmentStep.removePrevious,
                error,
                cleanupFailed: false,
              ),
              trace,
            );
          }
        }
        if (!repaired) {
          Error.throwWithStackTrace(
            QuickUnlockEnrollmentFailure._(
              _EnrollmentStep.readPrevious,
              error,
              cleanupFailed: false,
            ),
            trace,
          );
        }
        previous = null;
      }
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
      var step = _EnrollmentStep.removePrevious;
      if (!current()) throw StateError('Unlock configuration superseded');
      try {
        if (previous?['bioPending'] == true) {
          await _eraseRecords();
          previous = null;
        } else if (previous != null) {
          await _finishSlotCleanup(previous);
        }
        if (!current()) throw StateError('Unlock configuration superseded');
        final previousSlot = previous?['bioSlot'] as String?;
        if (system) {
          // Keep the old method usable until the replacement is on disk.
          // Persist the new slot address before asking for authentication.
          published = true;
          step = _EnrollmentStep.writeIntent;
          final intent = previous == null
              ? {
                  'v': 1,
                  'id': id,
                  'system': false,
                  'bioPending': true,
                  'bioSlot': id,
                }
              : {...previous, 'cleanupBioSlot': id};
          await store.write(_key, jsonEncode(intent));
          step = _EnrollmentStep.verifyIntent;
          final savedIntent = await _read();
          if (savedIntent?['id'] != intent['id'] ||
              !_biometricSlots(savedIntent).contains(id)) {
            throw StateError('Cleanup intent not saved');
          }
          final encoded = jsonEncode({'id': id, 'password': password});
          step = _EnrollmentStep.writeBiometric;
          await store.write(_bioKey(id), encoded, biometric: true);
          step = _EnrollmentStep.verifyBiometric;
          if (await store.read(_bioKey(id), biometric: true) != encoded ||
              (defaultTargetPlatform == TargetPlatform.android &&
                  !await store.contains(_bioKey(id), biometric: true))) {
            throw StateError('Saved sign-in not verified');
          }
        }
        if (!current()) {
          throw StateError('Unlock configuration superseded');
        }
        published = true;
        step = _EnrollmentStep.writeRecord;
        final record = <String, dynamic>{
          'v': 1,
          'id': id,
          'grid': grid,
          'pattern': pattern,
          'system': system,
          if (system) 'bioSlot': id,
          'cleanupBioSlot': ?previousSlot,
          'tries': 0,
          'after': 0,
        };
        await store.write(_key, jsonEncode(record));
        step = _EnrollmentStep.verifyRecord;
        if ((await _read())?['id'] != id) {
          throw StateError('Saved sign-in not verified');
        }
        if (!current()) throw StateError('Unlock configuration superseded');
        step = _EnrollmentStep.removePrevious;
        await _finishSlotCleanup(record);
      } catch (error, trace) {
        var cleanupFailed = false;
        if (published) {
          try {
            // If the final publication already won, keep the new working
            // entry and its cleanup address. Otherwise drop only the staged
            // slot and restore the old entry, including its lockout state.
            final record = await _read(forRemoval: true);
            if (record?['bioPending'] == true && record?['bioSlot'] == id) {
              await _eraseRecords();
            } else if (record?['cleanupBioSlot'] == id &&
                record?['id'] == previous?['id']) {
              await _finishSlotCleanup(record!);
            }
          } catch (_) {
            cleanupFailed = true;
          }
        }
        if (defaultTargetPlatform == TargetPlatform.android &&
            (current() || cleanupFailed)) {
          Error.throwWithStackTrace(
            QuickUnlockEnrollmentFailure._(
              step,
              error,
              cleanupFailed: cleanupFailed,
            ),
            trace,
          );
        }
        rethrow;
      }
    });
  }

  bool _canRepairAndroidRecord(Object error) =>
      defaultTargetPlatform == TargetPlatform.android &&
      error is PlatformException &&
      error.code == 'record_operation_failed' &&
      error.details == 'KEY';

  static Iterable<String> _biometricSlots(Map<String, dynamic>? record) sync* {
    if (record?['bioSlot'] case final String slot) yield slot;
    if (record?['cleanupBioSlot'] case final String slot) yield slot;
  }

  Future<void> _removeBiometricSlot(String slot) async {
    await store.delete(_bioKey(slot), biometric: true);
    if (await store.contains(_bioKey(slot), biometric: true)) {
      throw StateError('Saved sign-in removal not verified');
    }
  }

  Future<void> _finishSlotCleanup(Map<String, dynamic> record) async {
    if (record['cleanupBioSlot'] case final String slot) {
      await _removeBiometricSlot(slot);
      record.remove('cleanupBioSlot');
      await store.write(_key, jsonEncode(record));
      final verified = await _read(forRemoval: true);
      if (verified?['id'] != record['id'] ||
          verified?['cleanupBioSlot'] != null) {
        throw StateError('Saved sign-in cleanup not confirmed');
      }
    }
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

  Future<String?> openPattern(List<int> nodes, {int? grid}) {
    if (_scopeState.retired) return Future.value(null);
    final generation = _generation;
    return _serial(() async {
      final r = await _read();
      if (generation != _generation ||
          r == null ||
          r['grid'] is! int ||
          !_valid(grid ?? r['grid'], nodes) ||
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
        'pattern': '${grid ?? r['grid']}:${nodes.join(',')}',
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

  Future<void> _eraseRecords({
    void Function()? requireAuthority,
    Set<String>? capturedProtectedKeys,
  }) async {
    requireAuthority?.call();
    final record = await _read(forRemoval: true);
    requireAuthority?.call();
    final slots = _biometricSlots(record).toList();
    if (slots.isNotEmpty) {
      final keys = slots.map(_bioKey);
      if (capturedProtectedKeys != null &&
          !capturedProtectedKeys.containsAll(keys)) {
        throw StateError('Saved sign-in changed after capture');
      }
      if (_scopeState.retired) {
        _scopeState.erasureBiometricKeys.addAll(keys);
      }
      // Leave a cleanup intent until protected deletion is verified. Even if
      // delete/auth fails, the next wipe still knows that this slot exists.
      if (record?['bioPending'] != true ||
          record?['system'] != false ||
          record?['grid'] != null ||
          record?['pattern'] != null) {
        await store.write(
          _key,
          jsonEncode({
            'v': 1,
            'id': _random(16),
            'system': false,
            'grid': null,
            'pattern': null,
            'bioPending': true,
            'bioSlot': slots.first,
            if (slots.length > 1) 'cleanupBioSlot': slots.last,
          }),
        );
      }
      for (final key in keys) {
        requireAuthority?.call();
        await store.delete(key, biometric: true);
        requireAuthority?.call();
        if (await store.contains(key, biometric: true)) {
          throw StateError('Saved sign-in removal not verified');
        }
        requireAuthority?.call();
      }
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
  Future<List<String>> _captureForErasure(void Function()? requireAuthority) {
    try {
      requireAuthority?.call();
    } catch (error, trace) {
      return Future.error(error, trace);
    }
    _scopeState.retired = true;
    ++_generation;
    return _serial(() async {
      requireAuthority?.call();
      // Presence is read without cipher initialization on Android. An absent
      // public record must not initialize a new cipher while preparing erase.
      final present = await store.contains(_key);
      requireAuthority?.call();
      final record = present ? await _read(forRemoval: true) : null;
      requireAuthority?.call();
      if (present && record == null) {
        throw StateError('Saved sign-in record changed during capture');
      }
      _scopeState.erasureBiometricKeys.addAll(
        _biometricSlots(record).map(_bioKey),
      );
      return List<String>.unmodifiable(_scopeState.erasureBiometricKeys);
    });
  }

  Future<void> _retireCapturedForErasure(
    Set<String> protectedKeys,
    void Function()? requireAuthority,
  ) {
    try {
      requireAuthority?.call();
    } catch (error, trace) {
      return Future.error(error, trace);
    }
    _scopeState.retired = true;
    ++_generation;
    return _serial(
      () => _eraseRecords(
        requireAuthority: requireAuthority,
        capturedProtectedKeys: protectedKeys,
      ),
    );
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

  /// Only from settings after the current container password was verified.
  Future<void> forgetAfterPassword(bool Function() stillCurrent) {
    final generation = ++_generation;
    return _serial(() async {
      void requireCurrent() {
        if (generation != _generation ||
            _scopeState.retired ||
            !stillCurrent()) {
          throw StateError('Unlock configuration superseded');
        }
      }

      try {
        await _eraseRecords(requireAuthority: requireCurrent);
      } catch (error) {
        if (!_canRepairAndroidRecord(error)) rethrow;
        requireCurrent();
        if (!await store.repairAndroidRecord(_key)) rethrow;
        requireCurrent();
      }
    });
  }
}
