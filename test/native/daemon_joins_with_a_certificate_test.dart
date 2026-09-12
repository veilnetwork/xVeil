// A daemon can join an identity with its CERTIFICATE and nothing else.
//
// `--identity-credential-file` gives it the certificate; the secret that opens
// one is the certificate's own high-entropy code, not the twenty-four words.
// The node config step did not know that: restoring mined the device's own key
// AND a master config from the secret, and `decode_master_seed_from_phrase`
// refuses a code. Measured on a daemon's first run:
//
//     phrase decode failed: master phrase must be 24 words, got 1
//
// It took the whole boot down for a value the boot no longer needs — the
// invite is named by the DOCUMENT now, not by that config.
@Timeout(Duration(minutes: 10))
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;
import 'package:xveil/data/identity/veil_identity.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/identity_config_fields.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/veil_stack.dart';

class _Mem implements Storage {
  final settings = <String, String>{};
  final files = <String, Uint8List>{};
  String? config;

  @override
  Future<String?> loadNodeConfig() async => config;
  @override
  Future<void> saveNodeConfig(String t) async => config = t;
  @override
  Future<void> putSetting(String k, String v) async => settings[k] = v;
  @override
  Future<String?> getSetting(String k) async => settings[k];
  @override
  Future<void> storeFile(String i, Uint8List b, {String? name}) async =>
      files[i] = Uint8List.fromList(b);
  @override
  Future<Uint8List?> loadFile(String i, {int? maxBytes}) async => files[i];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final skip = (dylib?.isNotEmpty ?? false)
      ? false
      : 'set VEIL_FFI_DYLIB to libveilclient_ffi';

  test('the node config comes up on a code, without a phrase', () async {
    final lib = DynamicLibrary.open(dylib!);
    final code = veil.generateSovereignRecoveryCode();

    // A daemon's FIRST run: no config yet, and the only secret it was given is
    // the certificate's code.
    final s = _Mem();
    final toml = await RealVeilStack.ensureNodeConfig(
      s,
      identityPhrase: code,
      restoringIdentity: true,
      lib: lib,
    );

    expect(
      identityConfigFields(toml)?.publicKey,
      hasLength(32),
      reason: 'the device still has to come up on a key of its own',
    );
    expect(
      s.settings[kMasterConfigSetting],
      isNull,
      reason:
          'a code cannot produce a master config, and the boot must not die '
          'trying — the invite is named by the document',
    );
  }, skip: skip);

  test('a real phrase still stores one, so nothing was traded away', () async {
    final lib = DynamicLibrary.open(dylib!);
    final phrase = veilGeneratePhrase()!;
    final s = _Mem();
    await RealVeilStack.ensureNodeConfig(
      s,
      identityPhrase: phrase,
      restoringIdentity: true,
      lib: lib,
    );
    expect(
      s.settings[kMasterConfigSetting],
      isNotNull,
      reason:
          'the fallback still exists for the case it was built for: a boot '
          'that ends with no document at all',
    );
  }, skip: skip);
}
