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

    // AND IT IS THE ADDRESS THE FILE NAMES. Bytes 6..38 of an XVRC are the
    // node id in the clear — that is what a person compares the file against,
    // and what the restore has to land on. Asserting it here and not only
    // against a second provisioning is the difference between "the two agree"
    // and "the two agree with what was promised".
    expect(
      restoredId,
      orderedEquals(certificate.sublist(6, 38)),
      reason:
          'the certificate header names the address; a restore that lands '
          'anywhere else is a lookalike',
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

  test('a code that does not open the certificate fails the boot, loudly', () async {
    // The second field report: "код восстановления могу ввести любой (первый
    // раз ввел фразу и получил другую личность)". The screen accepted any
    // string, the native side refused it here — and `ensureSovereignIdentity`
    // answered null, which the caller reads as "no master behind this
    // identity". The node then came up on the device key mined a few lines
    // earlier: a working app, a brand new address, and nothing said.
    //
    // Null is the right answer for an identity nobody was trying to
    // reproduce. It is the wrong one when a CERTIFICATE named which identity
    // this is supposed to be.
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

    final held = _Mem()..config = toml;
    await held.storeFile(kSovereignBundleSetting, certificate);
    await expectLater(
      RealVeilStack.ensureSovereignIdentity(
        held,
        stagingBase: tmp.path,
        // The words, where the code belongs — long enough to clear the
        // native length floor, so this reaches the AEAD and is refused there.
        identityPhrase: phrase,
        lib: lib,
        restoringIdentity: true,
      ),
      throwsA(isA<SovereignRestoreRefused>()),
      reason:
          'a refused certificate must take the ceremony down with it — '
          'continuing produces a different identity at a different address',
    );

    // The vacuity guard: the same call with the RIGHT code still succeeds, so
    // the assertion above is about the code and not about the path being dead.
    final ok = _Mem()..config = toml;
    await ok.storeFile(kSovereignBundleSetting, certificate);
    final files = await RealVeilStack.ensureSovereignIdentity(
      ok,
      stagingBase: tmp.path,
      identityPhrase: code,
      lib: lib,
      restoringIdentity: true,
    );
    expect(files, isNotNull);
    expect(missingSovereignIdentityFiles(files!), isEmpty);
  }, skip: skip);
}
