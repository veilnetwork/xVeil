import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/identity/veil_identity.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/veil_stack.dart';

/// Provisioning against the REAL library, because everything else about this
/// mechanism can be green while the one thing that matters is not.
///
/// The unit tests hand `ensureSovereignIdentity` a stand-in provisioner, so
/// they prove the policy — provision once, never re-mint, store only complete
/// material — and say nothing about whether
/// `veil_restore_identity_from_phrase_zeroize` is exported at all, whether the
/// binding's ABI matches, or whether the call leaves the three files behind.
/// A missing symbol throws at lookup; a wrong signature corrupts the stack.
/// Neither shows up in a suite that never loads the dylib.
///
/// Env-gated on VEIL_FFI_DYLIB, like the other live tests here.
class _MemStorage implements Storage {
  final settings = <String, String>{};

  @override
  Future<void> putSetting(String key, String value) async =>
      settings[key] = value;
  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final hasDylib = dylib?.isNotEmpty ?? false;
  final skip = hasDylib ? false : 'set VEIL_FFI_DYLIB to libveilclient_ffi';

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xveil-sovereign-live-');
  });

  tearDown(() async {
    // The staging directory is removed by the call itself; this is the base it
    // was made under, plus anything a failed assertion left behind. It holds
    // MASTER-derived material either way, so it does not outlive the test.
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('provisioning leaves a real document, key and instance id', () async {
    final lib = DynamicLibrary.open(dylib!);
    final storage = _MemStorage();
    final files = await RealVeilStack.ensureSovereignIdentity(
      storage,
      stagingBase: tmp.path,
      identityPhrase: veilGeneratePhrase()!,
      lib: lib,
    );

    expect(files, isNotNull, reason: 'the native call must have run');
    expect(missingSovereignIdentityFiles(files!), isEmpty);
    // A 32-byte seed is the shape the loader expects; anything else means the
    // binding read the wrong bytes back.
    expect(files[kDeviceIdentitySkFile], hasLength(32));
    // A signed document with a master key, a subkey and a delegation over both
    // cannot be a handful of bytes. This is a floor, not a format check.
    expect(files[kIdentityDocumentFile]!.length, greaterThan(64));
    expect(files[kInstanceIdFile], isNotEmpty);
    expect(storage.settings[kSovereignIdentitySetting], isNotNull);
  }, skip: skip);

  test('two devices on one phrase get different keys', () async {
    // THE POINT OF THE WHOLE MECHANISM. Before this, one phrase on two devices
    // derived one keypair and produced one node — linking answered "self
    // device". The identity is shared; the device key must not be.
    final lib = DynamicLibrary.open(dylib!);
    final phrase = veilGeneratePhrase()!;
    final first = await RealVeilStack.ensureSovereignIdentity(
      _MemStorage(),
      stagingBase: tmp.path,
      identityPhrase: phrase,
      lib: lib,
    );
    final second = await RealVeilStack.ensureSovereignIdentity(
      _MemStorage(),
      stagingBase: tmp.path,
      identityPhrase: phrase,
      lib: lib,
    );

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(
      second![kDeviceIdentitySkFile],
      isNot(orderedEquals(first![kDeviceIdentitySkFile]!)),
      reason: 'each device signs with its own key',
    );
    expect(
      second[kInstanceIdFile],
      isNot(orderedEquals(first[kInstanceIdFile]!)),
      reason: 'each device is its own instance',
    );
    // Different devices, and therefore different documents — each names its
    // own subkey under the same master.
    expect(
      second[kIdentityDocumentFile],
      isNot(orderedEquals(first[kIdentityDocumentFile]!)),
    );
  }, skip: skip);

  test('an unusable phrase provisions nothing and stores nothing', () async {
    // The failure has to stay quiet and empty: a half-written entry would be
    // read on the next boot as "already provisioned", and the device would
    // never get a document at all.
    final lib = DynamicLibrary.open(dylib!);
    final storage = _MemStorage();
    final files = await RealVeilStack.ensureSovereignIdentity(
      storage,
      stagingBase: tmp.path,
      identityPhrase: 'not a bip39 phrase at all',
      lib: lib,
    );
    expect(files, isNull);
    expect(storage.settings[kSovereignIdentitySetting], isNull);
    // And nothing was left lying about under the base.
    expect(await tmp.list().isEmpty, isTrue);
  }, skip: skip);
}
