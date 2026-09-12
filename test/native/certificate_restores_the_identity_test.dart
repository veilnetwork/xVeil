// A device holding a RECOVERY CERTIFICATE gets its identity back — the same
// address, not a lookalike.
//
// This is what the certificate is offered for, and it did not work. An XVRC is
// re-wrapped under its own high-entropy code precisely so the exported file is
// not openable by the twenty-four words; every provisioning path opened
// credentials with the PHRASE. So a device that stored a certificate — exactly
// what the app writes when someone recovers — provisioned NOTHING and booted
// without a sovereign document, with the certificate sitting in its container.
//
// Found by probing this boot against the real library on 2026-09-12:
//
//     PROBE cert magic=XVRC
//     PROBE material=NULL — degenerate boot
//
// The bundle case is asserted alongside it, because the fix is a fork in the
// road and a fork is only right if BOTH ways still lead somewhere.
@Timeout(Duration(minutes: 5))
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;
import 'package:xveil/data/identity/veil_identity.dart';
import 'package:xveil/data/node/embedded_node.dart';
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
  Future<void> storeFile(String id, Uint8List b, {String? name}) async =>
      files[id] = Uint8List.fromList(b);
  @override
  Future<Uint8List?> loadFile(String id, {int? maxBytes}) async => files[id];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final skip = (dylib?.isNotEmpty ?? false)
      ? false
      : 'set VEIL_FFI_DYLIB to libveilclient_ffi';

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xveil-cert-restore-');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('a stored certificate provisions the identity it names', () async {
    final lib = DynamicLibrary.open(dylib!);
    final phrase = veilGeneratePhrase()!;
    final toml = EmbeddedNode.configFromPhrase(phrase, lib: lib);

    // The identity as the app creates it, then the artefact it exports.
    final bundle = EmbeddedNode.createHybridSovereignBundle(phrase, lib: lib);
    final code = veil.generateSovereignRecoveryCode();
    final certificate = veil.exportSovereignRecoveryCertificate(
      bundle,
      phrase,
      code,
    );
    expect(
      isRecoveryCertificate(certificate),
      isTrue,
      reason: 'the fixture has to be a certificate or this proves nothing',
    );
    expect(isRecoveryCertificate(bundle), isFalse);

    // What the app stores on recovery: the certificate, and the code is the
    // secret that opens it.
    final recovered = _Mem()..config = toml;
    await recovered.storeFile(kSovereignBundleSetting, certificate);
    final files = await RealVeilStack.ensureSovereignIdentity(
      recovered,
      stagingBase: tmp.path,
      identityPhrase: code,
      lib: lib,
    );
    expect(
      files,
      isNotNull,
      reason:
          'a device holding its certificate must come up WITH its identity; '
          'null here is the degenerate boot this test exists for',
    );
    expect(missingSovereignIdentityFiles(files!), isEmpty);

    // THE POINT: the address the certificate names, not a lookalike.
    final restoredId = EmbeddedNode.identityDocumentNodeId(
      files[kIdentityDocumentFile]!,
      lib: lib,
    );

    // The same identity provisioned the ordinary way, to compare against.
    final origin = _Mem()..config = toml;
    await origin.storeFile(kSovereignBundleSetting, bundle);
    final originFiles = await RealVeilStack.ensureSovereignIdentity(
      origin,
      stagingBase: tmp.path,
      identityPhrase: phrase,
      lib: lib,
    );
    expect(
      originFiles,
      isNotNull,
      reason: 'the bundle path must keep working — this fix is a fork, not a '
          'replacement',
    );
    expect(
      EmbeddedNode.identityDocumentNodeId(
        originFiles![kIdentityDocumentFile]!,
        lib: lib,
      ),
      orderedEquals(restoredId),
      reason:
          'the certificate has to restore the SAME address — recovering to a '
          'lookalike is exactly what makes saving it pointless',
    );
  }, skip: skip);

  test('the phrase does not open a certificate, and that is not silent', () async {
    // The control. Before the fork existed this was the whole story: the
    // phrase was handed to an XVRC, the native side refused, and the boot fell
    // through to no identity at all rather than saying so.
    final lib = DynamicLibrary.open(dylib!);
    final phrase = veilGeneratePhrase()!;
    final toml = EmbeddedNode.configFromPhrase(phrase, lib: lib);
    final bundle = EmbeddedNode.createHybridSovereignBundle(phrase, lib: lib);
    final code = veil.generateSovereignRecoveryCode();
    final certificate = veil.exportSovereignRecoveryCertificate(
      bundle,
      phrase,
      code,
    );

    expect(
      () => EmbeddedNode.provisionIdentityFromCertificate(
        certificate,
        phrase, // the WORDS, where the code belongs
        veilDir: '${tmp.path}/wrong',
        instanceLabel: 'wrong',
        nodeConfigToml: toml,
        lib: lib,
      ),
      throwsA(isA<StateError>()),
      reason:
          'the words must not open a certificate: if they did, the code it is '
          'wrapped under would be protecting nothing',
    );
  }, skip: skip);
}
