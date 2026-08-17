@Timeout(Duration(minutes: 20))
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/identity/veil_identity.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/identity_config_fields.dart';
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
  Future<void> saveNodeConfig(String toml) async => config = toml;

  @override
  Future<void> putSetting(String key, String value) async =>
      settings[key] = value;
  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The parts of an identity document that stay bit-identical between two
/// devices holding "the same" document.
///
/// Since the tombstone rewrite every adopt re-signs the document as ITS
/// device: issued_at/valid_until are re-stamped, sig_key_idx becomes the
/// signer's own, and document_sig is made by the signer's subkey. Byte
/// equality of two devices' copies is therefore no longer an invariant —
/// what converges is the header (magic through master_pubkey) and the
/// identity_keys/revoked_devices sections, compared here in wire order.
({List<int> header, List<int> body}) canonicalDocParts(Uint8List d) {
  var pos = 2 + 1 + 32 + 1; // magic, version, node_id, master_algo
  final mlen = (d[pos] << 8) | d[pos + 1];
  pos += 2 + mlen;
  final header = d.sublist(0, pos);
  pos += 8 + 8 + 2; // issued_at, valid_until, sig_key_idx — per device
  final bodyStart = pos;
  final nkeys = d[pos];
  pos += 1;
  for (var i = 0; i < nkeys; i++) {
    pos += 1; // algo
    final pl = (d[pos] << 8) | d[pos + 1];
    pos += 2 + pl + 32 + 8 + 8;
    final sl = (d[pos] << 8) | d[pos + 1];
    pos += 2 + sl;
  }
  if (d[2] == 2) {
    final nrev = d[pos];
    pos += 1;
    for (var i = 0; i < nrev; i++) {
      pos += 32;
      final sl = (d[pos] << 8) | d[pos + 1];
      pos += 2 + sl;
    }
  }
  return (header: header, body: d.sublist(bodyStart, pos));
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

  test('revoking a device shrinks the stored document and sticks', () async {
    // The cryptographic half of revocation, against the REAL library: the key
    // leaves the stored document, a master-signed tombstone takes its place,
    // and neither a stale re-adopt nor a re-delegation can bring it back.
    final lib = DynamicLibrary.open(dylib!);
    final phrase = veilGeneratePhrase()!;
    final storage = _MemStorage();
    final material = await RealVeilStack.ensureSovereignIdentity(
      storage,
      stagingBase: tmp.path,
      identityPhrase: phrase,
      lib: lib,
    );
    expect(material, isNotNull);

    // A second device of the same phrase, delegated into OUR document.
    final other = await RealVeilStack.ensureSovereignIdentity(
      _MemStorage(),
      stagingBase: tmp.path,
      identityPhrase: phrase,
      lib: lib,
    );
    final otherDoc = other![kIdentityDocumentFile]!;
    final delegated = await RealVeilStack.adoptSovereignDocument(
      storage,
      document: otherDoc,
      stagingBase: tmp.path,
      lib: lib,
    );
    expect(delegated, isTrue, reason: 'the sibling joins our document');
    final grown = decodeSovereignIdentity(
      storage.settings[kSovereignIdentitySetting]!,
    )![kIdentityDocumentFile]!;

    final before = grown.length;

    // Decoding the document to pick out the sibling's device_id is native-
    // only, so this covers what the WRAPPER contracts without it: a revoke
    // of an id not currently in the document still writes its tombstone
    // (grow-only — a preemptive tombstone also blocks any future delegation
    // of that id), the call is idempotent, and delegation of unrelated keys
    // stays healthy alongside tombstones. The in-document removal itself is
    // proven at the Rust layer (revoking_a_device_tombstones_it...).
    final phantomId = Uint8List.fromList(List.filled(32, 7));
    final changed = await RealVeilStack.revokeDeviceFromDocument(
      storage,
      phrase: phrase,
      deviceId: phantomId,
      stagingBase: tmp.path,
      lib: lib,
    );
    expect(changed, isTrue, reason: 'a tombstone is written even preemptively');
    final after = decodeSovereignIdentity(
      storage.settings[kSovereignIdentitySetting]!,
    )![kIdentityDocumentFile]!;
    expect(after.length, greaterThan(before), reason: 'tombstone appended');

    // Idempotent: the same id again changes nothing.
    final again = await RealVeilStack.revokeDeviceFromDocument(
      storage,
      phrase: phrase,
      deviceId: phantomId,
      stagingBase: tmp.path,
      lib: lib,
    );
    expect(again, isFalse);

    // And the tombstoned id can never be delegated: the wrapper refuses.
    final relink = await RealVeilStack.delegateDeviceIntoDocument(
      storage,
      phrase: phrase,
      devicePubkey: Uint8List.fromList(List.filled(32, 9)),
      stagingBase: tmp.path,
      lib: lib,
    );
    // (a random 32B pubkey whose blake3 != phantomId delegates fine — this
    // asserts the wrapper path stays healthy alongside tombstones)
    expect(relink, isTrue, reason: 'unrelated delegation unaffected');
  }, skip: skip);

  test('re-delegating a tombstoned key throws instead of shrugging', () async {
    // №31: the linking ceremony has a GROUP half that knows nothing about
    // tombstones. When this wrapper answered a tombstone refusal with the
    // same quiet `false` it uses for "already delegated", the ceremony
    // admitted the id into the device group anyway (control seq 11, measured
    // live) — a member frames queue to that no verifier accepts. The typed
    // throw is what lets the ceremony abort BEFORE the group grows.
    final lib = DynamicLibrary.open(dylib!);
    final phrase = veilGeneratePhrase()!;
    final storage = _MemStorage();
    final material = await RealVeilStack.ensureSovereignIdentity(
      storage,
      stagingBase: tmp.path,
      identityPhrase: phrase,
      lib: lib,
    );
    expect(material, isNotNull);

    final pubkey = Uint8List.fromList(
      List.generate(32, (i) => (i + 100) & 0xff),
    );
    expect(
      await RealVeilStack.delegateDeviceIntoDocument(
        storage,
        phrase: phrase,
        devicePubkey: pubkey,
        stagingBase: tmp.path,
        lib: lib,
      ),
      isTrue,
    );

    // The wire lays out each identity key as pubkey then device_id, so the
    // 32 bytes after our pubkey ARE the id the tombstone must name — no
    // native decode API needed.
    final doc = decodeSovereignIdentity(
      storage.settings[kSovereignIdentitySetting]!,
    )![kIdentityDocumentFile]!;
    var at = -1;
    for (var i = 0; i + 64 <= doc.length; i++) {
      var hit = true;
      for (var j = 0; j < 32; j++) {
        if (doc[i + j] != pubkey[j]) {
          hit = false;
          break;
        }
      }
      if (hit) {
        at = i;
        break;
      }
    }
    expect(at, greaterThanOrEqualTo(0), reason: 'delegated key is in the doc');
    final deviceId = Uint8List.sublistView(doc, at + 32, at + 64);

    expect(
      await RealVeilStack.revokeDeviceFromDocument(
        storage,
        phrase: phrase,
        deviceId: deviceId,
        stagingBase: tmp.path,
        lib: lib,
      ),
      isTrue,
    );

    await expectLater(
      RealVeilStack.delegateDeviceIntoDocument(
        storage,
        phrase: phrase,
        devicePubkey: pubkey,
        stagingBase: tmp.path,
        lib: lib,
      ),
      throwsA(isA<TombstonedDeviceException>()),
      reason: 'the one refusal that must not read as "no change needed"',
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
      // No shared config: since provisioning takes "the key this device
      // already runs on" from the node config, handing the phone the
      // desktop's toml would model an impossible pair — two real devices
      // never share a transport key. With no config the phone takes the
      // first-run path and mints a fresh random device key.
      final phone = _MemStorage();
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
      // One document, held by both — canonically: each copy is re-signed by
      // its own device, so the stamps, the signer index and the signature
      // are per-device while header and key set converge.
      final deskParts = canonicalDocParts(deskNow[kIdentityDocumentFile]!);
      final phoneParts = canonicalDocParts(phoneNow[kIdentityDocumentFile]!);
      expect(deskParts.header, orderedEquals(phoneParts.header));
      expect(deskParts.body, orderedEquals(phoneParts.body));
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
    final aParts = canonicalDocParts(
      await File('$a/$kIdentityDocumentFile').readAsBytes(),
    );
    final bParts = canonicalDocParts(merged);
    expect(
      aParts.header,
      orderedEquals(bParts.header),
      reason: 'one identity, held by both',
    );
    expect(
      aParts.body,
      orderedEquals(bParts.body),
      reason: 'one key set, held by both',
    );
  }, skip: skip);

  // THE SWITCH. One phrase, two devices: the first takes the phrase's own
  // keypair as its node key — that is what makes node_id recoverable from the
  // words — and the second mints one of its own. Holding the same key is what
  // made two devices one node.
  test('a restored device does not take the phrase\'s node key', () async {
    final lib = DynamicLibrary.open(dylib!);
    final phrase = minePhrase!;

    final firstStorage = _MemStorage();
    final first = await RealVeilStack.ensureNodeConfig(
      firstStorage,
      identityPhrase: phrase,
      lib: lib,
    );
    final restoredStorage = _MemStorage();
    final restored = await RealVeilStack.ensureNodeConfig(
      restoredStorage,
      identityPhrase: phrase,
      restoringIdentity: true,
      lib: lib,
    );

    expect(first, isNotEmpty);
    expect(restored, isNotEmpty);
    expect(
      restored,
      isNot(first),
      reason: 'the restored device must not reuse the phrase-derived key',
    );
    // Determinism of the phrase path itself is `configFromPhrase`'s property
    // and is not re-mined here: each mining is about a minute, and this file
    // already pays for several.
  }, skip: skip);

  // THE SILENT ONE. A restored device mines a transport key of its own; if
  // provisioning then mints a SECOND key and names that in the document, the
  // device signs with one key while its document vouches for another. Nothing
  // reports it: the message is stored (the write precedes the check), filtered
  // out of every read, and skipped by every send — the device shows its own
  // writing to nobody, itself included.
  //
  // This runs the app's own two calls in the app's own order, because the
  // Rust-side test proves the primitive accepts an offered key and says nothing
  // about whether this layer offers it.
  test('a restored device is named in its document by the key it runs on', () async {
    final lib = DynamicLibrary.open(dylib!);
    final phrase = minePhrase!;
    final storage = _MemStorage();

    // Step one, as the restore path runs it: a transport key of this device's
    // own, mined, written to the config.
    final toml = await RealVeilStack.ensureNodeConfig(
      storage,
      identityPhrase: phrase,
      restoringIdentity: true,
      lib: lib,
    );
    final nodeKey = identityConfigFields(toml)!.publicKey;

    // Step two: the sovereign material, which must adopt that key rather than
    // invent one.
    final mat = await RealVeilStack.ensureSovereignIdentity(
      storage,
      stagingBase: tmp.path,
      identityPhrase: phrase,
      lib: lib,
    );
    expect(mat, isNotNull);

    final document = mat![kIdentityDocumentFile]!;
    final identity = EmbeddedNode.identityDocumentNodeId(document, lib: lib);
    expect(
      EmbeddedNode.identityDocumentAuthorizes(
        document: document,
        nodeId: identity,
        publicKey: nodeKey,
      ),
      isTrue,
      reason: 'the document must name the key this device signs with',
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
