// Provisioning happens ONCE per device, and the reason is not tidiness.
//
// The identity document is published under this identity's node_id and names
// this device's key. Minting a second device key replaces the key the network
// has already been told about, so every peer holding the earlier document is
// pointing at a device that no longer signs. The material is therefore
// provisioned once, stored, and only ever laid back out.
//
// Which makes "was the native call reached?" the thing to assert, not "did the
// result look right" — a run that re-provisions and then happens to produce
// usable material passes every check on the returned value.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/data/veil_stack.dart';

import 'support/fake_setting_storage.dart';

/// The shared fake answers settings and nothing else, on purpose. Adoption also
/// reads the node config — the master authority it delegates with — so this one
/// adds exactly that and no more.
class _ConfigStorage extends FakeSettingStorage {
  String? config;

  @override
  Future<String?> loadNodeConfig() async => config;
}

Map<String, Uint8List> _material({int keyByte = 7}) => {
  kIdentityDocumentFile: Uint8List.fromList([1, 2, 3]),
  kDeviceIdentitySkFile: Uint8List.fromList(List.filled(32, keyByte)),
  kInstanceIdFile: Uint8List.fromList([9, 9]),
};

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xveil-provision-test-');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// A stand-in for the native call that records how often it ran and lays out
  /// material the way `identity restore` does.
  ({Future<void> Function(String, String) fn, List<String> dirs}) recorder({
    int keyByte = 7,
    bool writeNothing = false,
  }) {
    final dirs = <String>[];
    return (
      dirs: dirs,
      fn: (phrase, dir) async {
        dirs.add(dir);
        if (writeNothing) return;
        await materialiseSovereignIdentity(dir, _material(keyByte: keyByte));
      },
    );
  }

  test('provisions once and stores what it made', () async {
    final storage = FakeSettingStorage();
    final rec = recorder();
    final out = await RealVeilStack.ensureSovereignIdentity(
      storage,
      stagingBase: tmp.path,
      identityPhrase: 'a master phrase',
      provision: rec.fn,
    );
    expect(rec.dirs, hasLength(1));
    expect(missingSovereignIdentityFiles(out!), isEmpty);
    expect(storage.settings[kSovereignIdentitySetting], isNotNull);
  });

  // THE INVARIANT. A second boot must read, never re-mint.
  test('a second call does not touch the native side', () async {
    final storage = FakeSettingStorage();
    final first = recorder(keyByte: 7);
    await RealVeilStack.ensureSovereignIdentity(
      storage,
      stagingBase: tmp.path,
      identityPhrase: 'a master phrase',
      provision: first.fn,
    );
    final stored = storage.settings[kSovereignIdentitySetting];

    // Same phrase, same container, second boot — and a provisioner that would
    // mint a DIFFERENT key if it were reached, so a re-provision cannot hide
    // behind material that happens to look the same.
    final second = recorder(keyByte: 42);
    final out = await RealVeilStack.ensureSovereignIdentity(
      storage,
      stagingBase: tmp.path,
      identityPhrase: 'a master phrase',
      provision: second.fn,
    );
    expect(second.dirs, isEmpty, reason: 'the native call must not be reached');
    expect(out![kDeviceIdentitySkFile], everyElement(7));
    expect(storage.settings[kSovereignIdentitySetting], stored);
  });

  // A container entry that will not decode is NOT a licence to start over:
  // the published document is not recoverable from a fresh key, whereas the
  // material itself is recoverable from the phrase.
  test(
    'a corrupt entry boots without a document rather than re-minting',
    () async {
      final storage = FakeSettingStorage();
      storage.settings[kSovereignIdentitySetting] = 'not json at all';
      final rec = recorder();
      final out = await RealVeilStack.ensureSovereignIdentity(
        storage,
        stagingBase: tmp.path,
        identityPhrase: 'a master phrase',
        provision: rec.fn,
      );
      expect(out, isNull);
      expect(rec.dirs, isEmpty);
      expect(storage.settings[kSovereignIdentitySetting], 'not json at all');
    },
  );

  test('material missing a required file is treated the same way', () async {
    final storage = FakeSettingStorage();
    final partial = _material()..remove(kDeviceIdentitySkFile);
    storage.settings[kSovereignIdentitySetting] = encodeSovereignIdentity(
      partial,
    );
    final rec = recorder();
    final out = await RealVeilStack.ensureSovereignIdentity(
      storage,
      stagingBase: tmp.path,
      identityPhrase: 'a master phrase',
      provision: rec.fn,
    );
    expect(out, isNull);
    expect(rec.dirs, isEmpty);
  });

  // A mined identity has no master behind it, so there is nothing to provision
  // and the degenerate document the node builds is the truthful description of
  // a single device. Every identity already in the field takes this path.
  test('no phrase means no provisioning and no complaint', () async {
    final storage = FakeSettingStorage();
    final rec = recorder();
    for (final phrase in [null, '']) {
      final out = await RealVeilStack.ensureSovereignIdentity(
        storage,
        stagingBase: tmp.path,
        identityPhrase: phrase,
        provision: rec.fn,
      );
      expect(out, isNull, reason: 'phrase=$phrase');
    }
    expect(rec.dirs, isEmpty);
    expect(storage.settings, isEmpty);
  });

  // Provisioning that produces nothing usable must not be stored: a stored
  // half-set would be read on the next boot as "already provisioned" and the
  // device would never get a document at all.
  test('incomplete provisioning is not stored', () async {
    final storage = FakeSettingStorage();
    final rec = recorder(writeNothing: true);
    final out = await RealVeilStack.ensureSovereignIdentity(
      storage,
      stagingBase: tmp.path,
      identityPhrase: 'a master phrase',
      provision: rec.fn,
    );
    expect(rec.dirs, hasLength(1));
    expect(out, isNull);
    expect(storage.settings[kSovereignIdentitySetting], isNull);
  });

  // The staging directory holds MASTER-derived material for as long as it
  // exists. It is this call's to create and this call's to remove — on the
  // failure paths too, which is where a leftover would otherwise sit.
  test('the staging directory never outlives the call', () async {
    final storage = FakeSettingStorage();
    final rec = recorder();
    await RealVeilStack.ensureSovereignIdentity(
      storage,
      stagingBase: tmp.path,
      identityPhrase: 'a master phrase',
      provision: rec.fn,
    );
    expect(await Directory(rec.dirs.single).exists(), isFalse);

    final storage2 = FakeSettingStorage();
    final dirs = <String>[];
    await RealVeilStack.ensureSovereignIdentity(
      storage2,
      stagingBase: tmp.path,
      identityPhrase: 'a master phrase',
      provision: (phrase, dir) async {
        dirs.add(dir);
        await materialiseSovereignIdentity(dir, _material());
        throw StateError('native side failed after writing the key');
      },
    );
    expect(await Directory(dirs.single).exists(), isFalse);
    expect(storage2.settings[kSovereignIdentitySetting], isNull);
  });

  // ── adopting another device's document ──────────────────────────────────
  //
  // The half of multi-device that cannot be done alone. Two devices set up from
  // one phrase each hold a document naming only themselves and BOTH carry the
  // same node_id, because node_id is BLAKE3 of the master key they both
  // derived. Both publish under it, the later publisher displaces the earlier,
  // and the displaced device stays online believing it is reachable.

  group('adoptSovereignDocument', () {
    Future<_ConfigStorage> provisioned({int keyByte = 7}) async {
      final storage = _ConfigStorage()..config = 'unused by the fake delegate';
      storage.settings[kSovereignIdentitySetting] = encodeSovereignIdentity(
        _material(keyByte: keyByte),
      );
      return storage;
    }

    test('merges and keeps what the delegation produced', () async {
      final storage = await provisioned();
      final seen = <String>[];
      final ok = await RealVeilStack.adoptSovereignDocument(
        storage,
        document: Uint8List.fromList([4, 5, 6, 7]),
        stagingBase: tmp.path,
        merge: (toml, dir, doc) async {
          seen.add(dir);
          // What the native side does: rewrite the document in place.
          await materialiseSovereignIdentity(dir, {
            ..._material(),
            kIdentityDocumentFile: Uint8List.fromList(List.filled(200, 1)),
          });
        },
      );
      expect(ok, isTrue);
      expect(seen, hasLength(1));
      final kept = decodeSovereignIdentity(
        storage.settings[kSovereignIdentitySetting]!,
      )!;
      expect(kept[kIdentityDocumentFile], hasLength(200));
    });

    // THE SAFETY PROPERTY. A delegation that fails — a document from another
    // identity, a truncated transfer — must leave this device exactly as it
    // was. A device left holding a document it cannot sign with is off the
    // network entirely.
    test('a refused document changes nothing', () async {
      final storage = await provisioned();
      final before = storage.settings[kSovereignIdentitySetting];
      final ok = await RealVeilStack.adoptSovereignDocument(
        storage,
        document: Uint8List.fromList([9, 9]),
        stagingBase: tmp.path,
        merge: (toml, dir, doc) async =>
            throw StateError('delegate_device: master does not match'),
      );
      expect(ok, isFalse);
      expect(storage.settings[kSovereignIdentitySetting], before);
    });

    test('the staging copy never outlives the call', () async {
      final storage = await provisioned();
      final dirs = <String>[];
      await RealVeilStack.adoptSovereignDocument(
        storage,
        document: Uint8List.fromList([1]),
        stagingBase: tmp.path,
        merge: (toml, dir, doc) async => dirs.add(dir),
      );
      expect(await Directory(dirs.single).exists(), isFalse);
    });

    // A mined identity has no master behind it, so there is nothing to
    // delegate under and no honest merge to make.
    test('a device with no material of its own declines', () async {
      final storage = _ConfigStorage()..config = 'a config';
      var called = false;
      final ok = await RealVeilStack.adoptSovereignDocument(
        storage,
        document: Uint8List.fromList([1, 2]),
        stagingBase: tmp.path,
        merge: (toml, dir, doc) async => called = true,
      );
      expect(ok, isFalse);
      expect(called, isFalse);
    });

    test('no config means no authority, and nothing is attempted', () async {
      final storage = _ConfigStorage();
      storage.settings[kSovereignIdentitySetting] = encodeSovereignIdentity(
        _material(),
      );
      var called = false;
      final ok = await RealVeilStack.adoptSovereignDocument(
        storage,
        document: Uint8List.fromList([1, 2]),
        stagingBase: tmp.path,
        merge: (toml, dir, doc) async => called = true,
      );
      expect(ok, isFalse);
      expect(called, isFalse);
    });

    // A delegation that returns without leaving usable material must not be
    // stored: half a set reads on the next boot as "already provisioned", and
    // the device would go on without a document it can sign with.
    test(
      'a merge that produced nothing usable keeps the old material',
      () async {
        final storage = await provisioned();
        final before = storage.settings[kSovereignIdentitySetting];
        final ok = await RealVeilStack.adoptSovereignDocument(
          storage,
          document: Uint8List.fromList([1, 2, 3, 4]),
          stagingBase: tmp.path,
          merge: (toml, dir, doc) async {
            // Wipes the staging copy instead of rewriting the document.
            await Directory(dir).delete(recursive: true);
            await Directory(dir).create(recursive: true);
          },
        );
        expect(ok, isFalse);
        expect(storage.settings[kSovereignIdentitySetting], before);
      },
    );

    test('an empty document is not a merge', () async {
      final storage = await provisioned();
      var called = false;
      final ok = await RealVeilStack.adoptSovereignDocument(
        storage,
        document: Uint8List(0),
        stagingBase: tmp.path,
        merge: (toml, dir, doc) async => called = true,
      );
      expect(ok, isFalse);
      expect(called, isFalse);
    });
  });
}
