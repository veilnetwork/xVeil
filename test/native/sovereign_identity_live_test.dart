@Timeout(Duration(minutes: 10))
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/identity/veil_identity.dart';
import 'package:xveil/data/node/embedded_node.dart';
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
  String? config;

  @override
  Future<String?> loadNodeConfig() async => config;

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
  // Mined ONCE for the whole file. `configFromPhrase` runs the anti-sybil PoW,
  // which is tens of seconds on a desktop — per test it blows the 30 s default
  // and the timeout then lands as a pile of unrelated-looking failures from the
  // teardown that has already removed the directory underneath.
  String? minePhrase;
  String? mineToml;
  String? strangerToml;

  setUpAll(() {
    if (!hasDylib) return;
    final lib = DynamicLibrary.open(dylib!);
    minePhrase = veilGeneratePhrase()!;
    mineToml = EmbeddedNode.configFromPhrase(minePhrase!, lib: lib);
    strangerToml = EmbeddedNode.configFromPhrase(
      veilGeneratePhrase()!,
      lib: lib,
    );
  });

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

  // THE MERGE. Two devices restored from one phrase each hold a document with
  // one key and the SAME node_id — both published under that id, the later
  // publisher displacing the earlier, the displaced device online and
  // unreachable. One of them has to end up carrying both keys.
  test(
    'a restored device can add itself to the other one\'s document',
    () async {
      final lib = DynamicLibrary.open(dylib!);
      final phrase = veilGeneratePhrase()!;
      final a = '${tmp.path}/a';
      final b = '${tmp.path}/b';
      EmbeddedNode.provisionSovereignIdentity(
        phrase,
        veilDir: a,
        instanceLabel: 'desktop',
        lib: lib,
      );
      EmbeddedNode.provisionSovereignIdentity(
        phrase,
        veilDir: b,
        instanceLabel: 'phone',
        lib: lib,
      );
      final aDoc = await File('$a/$kIdentityDocumentFile').readAsBytes();
      final bDocBefore = await File('$b/$kIdentityDocumentFile').readAsBytes();
      expect(aDoc, isNot(orderedEquals(bDocBefore)), reason: 'two devices');

      // B receives A's document over the linking channel and adopts it, then
      // adds itself. It cannot sign with A's subkey — that secret is on A.
      await File('$b/$kIdentityDocumentFile').writeAsBytes(aDoc, flush: true);
      EmbeddedNode.delegateDeviceFromPhrase(phrase, veilDir: b, lib: lib);

      final merged = await File('$b/$kIdentityDocumentFile').readAsBytes();
      // A second delegated key is roughly a pubkey, a device id, two timestamps
      // and a 64-byte signature. The document cannot have merely been rewritten.
      expect(
        merged.length,
        greaterThan(aDoc.length + 100),
        reason: 'the merged document carries a second key',
      );
      expect(merged, isNot(orderedEquals(aDoc)));
    },
    skip: skip,
  );

  // A wrong phrase must be refused here, not produce a document that verifies
  // against a different identity and fails much later as peers refusing a node
  // they cannot resolve.
  test('a phrase from another identity is refused', () async {
    final lib = DynamicLibrary.open(dylib!);
    final mine = veilGeneratePhrase()!;
    final stranger = veilGeneratePhrase()!;
    final dir = '${tmp.path}/mine';
    EmbeddedNode.provisionSovereignIdentity(
      mine,
      veilDir: dir,
      instanceLabel: 'desktop',
      lib: lib,
    );
    final before = await File('$dir/$kIdentityDocumentFile').readAsBytes();
    expect(
      () => EmbeddedNode.delegateDeviceFromPhrase(
        stranger,
        veilDir: dir,
        devicePubkey: Uint8List.fromList(List.filled(32, 3)),
        lib: lib,
      ),
      throwsA(isA<StateError>()),
    );
    // And it left the document alone.
    expect(
      await File('$dir/$kIdentityDocumentFile').readAsBytes(),
      orderedEquals(before),
    );
  }, skip: skip);

  // THE CALL THE LIVE PATH MAKES. By the time a second device is linked the
  // phrase is long gone — consumed at setup, never stored — so delegation has
  // to work from what the app kept: its node config, whose private key IS the
  // master secret for a phrase-provisioned identity.
  test(
    'the stored config carries enough authority to admit a device',
    () async {
      final lib = DynamicLibrary.open(dylib!);
      final phrase = minePhrase!;
      final toml = mineToml!;
      final a = '${tmp.path}/ca';
      final b = '${tmp.path}/cb';
      EmbeddedNode.provisionSovereignIdentity(
        phrase,
        veilDir: a,
        instanceLabel: 'desktop',
        lib: lib,
      );
      EmbeddedNode.provisionSovereignIdentity(
        phrase,
        veilDir: b,
        instanceLabel: 'phone',
        lib: lib,
      );

      final aDoc = await File('$a/$kIdentityDocumentFile').readAsBytes();
      await File('$b/$kIdentityDocumentFile').writeAsBytes(aDoc, flush: true);
      EmbeddedNode.delegateDeviceFromConfig(toml, veilDir: b, lib: lib);

      final merged = await File('$b/$kIdentityDocumentFile').readAsBytes();
      expect(
        merged.length,
        greaterThan(aDoc.length + 100),
        reason: 'the merged document carries a second key',
      );
    },
    skip: skip,
  );

  test('a config from another identity is refused', () async {
    final lib = DynamicLibrary.open(dylib!);
    final mine = minePhrase!;
    final dir = '${tmp.path}/cmine';
    EmbeddedNode.provisionSovereignIdentity(
      mine,
      veilDir: dir,
      instanceLabel: 'desktop',
      lib: lib,
    );
    final before = await File('$dir/$kIdentityDocumentFile').readAsBytes();
    expect(
      () => EmbeddedNode.delegateDeviceFromConfig(
        strangerToml!,
        veilDir: dir,
        devicePubkey: Uint8List.fromList(List.filled(32, 3)),
        lib: lib,
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      await File('$dir/$kIdentityDocumentFile').readAsBytes(),
      orderedEquals(before),
    );
  }, skip: skip);

  // THE WHOLE DEFECT, END TO END, through the app's own API.
  //
  // Two devices set up from one master phrase. Before this each held a document
  // naming only itself while both carried the same node_id, so both published
  // under that id, the later publisher displaced the earlier, and the displaced
  // device stayed online believing it was reachable. Linking answered "self
  // device" because they were, at the identity layer, one node.
  test(
    'two devices from one phrase end up as one identity with two keys',
    () async {
      final lib = DynamicLibrary.open(dylib!);
      final phrase = minePhrase!;
      final toml = mineToml!;

      final desktop = _MemStorage()..config = toml;
      final phone = _MemStorage()..config = toml;
      final deskMat = await RealVeilStack.ensureSovereignIdentity(
        desktop,
        stagingBase: tmp.path,
        identityPhrase: phrase,
        lib: lib,
      );
      final phoneMat = await RealVeilStack.ensureSovereignIdentity(
        phone,
        stagingBase: tmp.path,
        identityPhrase: phrase,
        lib: lib,
      );
      expect(deskMat, isNotNull);
      expect(phoneMat, isNotNull);
      expect(
        deskMat![kDeviceIdentitySkFile],
        isNot(orderedEquals(phoneMat![kDeviceIdentitySkFile]!)),
      );

      // The phone receives the desktop's document over the linking channel and
      // adds itself.
      final merged = await RealVeilStack.adoptSovereignDocument(
        phone,
        document: deskMat[kIdentityDocumentFile]!,
        stagingBase: tmp.path,
        lib: lib,
      );
      expect(merged, isTrue, reason: 'the phone appends itself');

      // The desktop receives the merged document back. It is already named in
      // it, so there is nothing to append — but it MUST record its own subkey
      // index, or it signs with the phone's key and comes up with no identity.
      final phoneNow = decodeSovereignIdentity(
        phone.settings[kSovereignIdentitySetting]!,
      )!;
      final adopted = await RealVeilStack.adoptSovereignDocument(
        desktop,
        document: phoneNow[kIdentityDocumentFile]!,
        stagingBase: tmp.path,
        lib: lib,
      );
      expect(adopted, isTrue, reason: 'the desktop adopts');

      final deskNow = decodeSovereignIdentity(
        desktop.settings[kSovereignIdentitySetting]!,
      )!;
      // One document, held by both.
      expect(
        deskNow[kIdentityDocumentFile],
        orderedEquals(phoneNow[kIdentityDocumentFile]!),
      );
      // Two devices: each keeps its own key and its own subkey index, and the
      // indices differ — that file is what stops each from signing as the other.
      expect(
        deskNow[kDeviceIdentitySkFile],
        isNot(orderedEquals(phoneNow[kDeviceIdentitySkFile]!)),
      );
      expect(deskNow[kDeviceSigKeyIdxFile], isNotNull);
      expect(phoneNow[kDeviceSigKeyIdxFile], isNotNull);
      expect(
        deskNow[kDeviceSigKeyIdxFile],
        isNot(orderedEquals(phoneNow[kDeviceSigKeyIdxFile]!)),
      );
    },
    skip: skip,
  );

  test(
    'a document from another identity is refused and changes nothing',
    () async {
      final lib = DynamicLibrary.open(dylib!);
      final mine = _MemStorage()..config = mineToml!;
      await RealVeilStack.ensureSovereignIdentity(
        mine,
        stagingBase: tmp.path,
        identityPhrase: minePhrase!,
        lib: lib,
      );
      final before = mine.settings[kSovereignIdentitySetting];

      final stranger = _MemStorage()..config = strangerToml!;
      final strangerMat = await RealVeilStack.ensureSovereignIdentity(
        stranger,
        stagingBase: tmp.path,
        identityPhrase: veilGeneratePhrase()!,
        lib: lib,
      );

      final ok = await RealVeilStack.adoptSovereignDocument(
        mine,
        document: strangerMat![kIdentityDocumentFile]!,
        stagingBase: tmp.path,
        lib: lib,
      );
      expect(ok, isFalse);
      expect(mine.settings[kSovereignIdentitySetting], before);
    },
    skip: skip,
  );

  // The authority an app keeps once its config is a per-device transport key
  // rather than the master. Same 32 bytes the config used to carry, obtained
  // without mining and without touching disk.
  test('the master key alone can merge two devices', () async {
    final lib = DynamicLibrary.open(dylib!);
    final phrase = minePhrase!;
    final master = EmbeddedNode.masterKeyFromPhrase(phrase, lib: lib);
    expect(master, hasLength(32));

    final a = '${tmp.path}/ma';
    final b = '${tmp.path}/mb';
    EmbeddedNode.provisionSovereignIdentity(
      phrase,
      veilDir: a,
      instanceLabel: 'desktop',
      lib: lib,
    );
    EmbeddedNode.provisionSovereignIdentity(
      phrase,
      veilDir: b,
      instanceLabel: 'phone',
      lib: lib,
    );

    final aDoc = await File('$a/$kIdentityDocumentFile').readAsBytes();
    final bIdx = EmbeddedNode.adoptIdentityDocumentWithMaster(
      master,
      veilDir: b,
      document: aDoc,
      lib: lib,
    );
    final merged = await File('$b/$kIdentityDocumentFile').readAsBytes();
    final aIdx = EmbeddedNode.adoptIdentityDocumentWithMaster(
      master,
      veilDir: a,
      document: merged,
      lib: lib,
    );

    expect(bIdx, isNot(aIdx), reason: 'the two devices are different subkeys');
    // Each recorded its own index — without that file a device signs with the
    // other's key and comes up with no identity at all.
    expect(await File('$a/$kDeviceSigKeyIdxFile').exists(), isTrue);
    expect(await File('$b/$kDeviceSigKeyIdxFile').exists(), isTrue);
    expect(
      await File('$a/$kIdentityDocumentFile').readAsBytes(),
      orderedEquals(merged),
      reason: 'one document, held by both',
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
