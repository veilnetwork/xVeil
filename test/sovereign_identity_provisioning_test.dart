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

    /// THE CEREMONY RULE, which is a different question from the merge's own.
    ///
    /// A refusal used to be the same `false` as "we already hold this
    /// document", and all three link paths read it that way and carried on. A
    /// device could finish linking to a family whose document it does not
    /// hold: publishing a registry naming itself alone, sealing for nobody.
    /// The usual reason for a refusal is that the document does not name this
    /// device's key, or is not this family's document at all — which is what a
    /// substituted ceremony produces.
    test('a refused document ends the ceremony', () async {
      final storage = await provisioned();
      await expectLater(
        adoptCeremonyDocument(
          storage,
          document: Uint8List.fromList([4, 5, 6, 7]),
          stagingBase: tmp.path,
          // The native side's refusal: it wipes the staging copy rather than
          // writing a document, so nothing usable comes back.
          merge: (toml, dir, doc) async {
            await Directory(dir).delete(recursive: true);
            await Directory(dir).create(recursive: true);
          },
        ),
        throwsA(isA<SovereignDocumentRefused>()),
      );
    });

    test('a document already held lets the ceremony go on', () async {
      final storage = await provisioned();
      final held = decodeSovereignIdentity(
        storage.settings[kSovereignIdentitySetting]!,
      )!;
      final onward = await adoptCeremonyDocument(
        storage,
        document: Uint8List.fromList([4, 5, 6, 7]),
        stagingBase: tmp.path,
        // Writes back exactly what this device already holds.
        merge: (toml, dir, doc) async =>
            materialiseSovereignIdentity(dir, held),
      );
      expect(
        onward,
        isFalse,
        reason: 'nothing changed, so the node has nothing to be handed — but '
            'the ceremony is not stopped either',
      );
    });

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
      expect(ok, SovereignDocumentAdoption.adopted);
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
      expect(ok, SovereignDocumentAdoption.refused);
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

    // A mined identity has no master behind it — but a document that already
    // NAMES this device carries the master's authority inside it, so the
    // named adopt is what runs, not the merge. This is the freshly linked
    // device's only way in: before this path existed the call declined
    // silently and the device stayed on documentBytes:0 forever.
    test('a device with no material adopts a document naming it', () async {
      final storage = _ConfigStorage()..config = 'a device config';
      var mergeCalled = false;
      final seen = <String>[];
      final ok = await RealVeilStack.adoptSovereignDocument(
        storage,
        document: Uint8List.fromList([1, 2]),
        stagingBase: tmp.path,
        merge: (toml, dir, doc) async => mergeCalled = true,
        adoptNamed: (toml, dir, doc) async {
          seen.add(dir);
          // What the native side does: write the full material set.
          await materialiseSovereignIdentity(dir, _material());
        },
      );
      expect(ok, SovereignDocumentAdoption.adopted);
      expect(mergeCalled, isFalse, reason: 'no master to merge under');
      expect(seen, hasLength(1));
      expect(storage.settings[kSovereignIdentitySetting], isNotNull);
      expect(await Directory(seen.single).exists(), isFalse);
    });

    test('no material and no config still declines', () async {
      final storage = _ConfigStorage();
      var called = false;
      final ok = await RealVeilStack.adoptSovereignDocument(
        storage,
        document: Uint8List.fromList([1, 2]),
        stagingBase: tmp.path,
        merge: (toml, dir, doc) async => called = true,
        adoptNamed: (toml, dir, doc) async => called = true,
      );
      expect(ok, SovereignDocumentAdoption.refused);
      expect(called, isFalse);
    });

    // The named adopt's own safety property: a document that does not name
    // this device (or is not this family's at all) is refused natively, and a
    // refusal must store nothing — half a set reads on the next boot as
    // "already provisioned".
    test('a refused named adopt stores nothing', () async {
      final storage = _ConfigStorage()..config = 'a device config';
      final ok = await RealVeilStack.adoptSovereignDocument(
        storage,
        document: Uint8List.fromList([1, 2]),
        stagingBase: tmp.path,
        adoptNamed: (toml, dir, doc) async =>
            throw StateError('document does not name this device'),
      );
      expect(ok, SovereignDocumentAdoption.refused);
      expect(storage.settings[kSovereignIdentitySetting], isNull);
    });

    test('a named adopt that leaves incomplete material stores nothing', () async {
      final storage = _ConfigStorage()..config = 'a device config';
      final ok = await RealVeilStack.adoptSovereignDocument(
        storage,
        document: Uint8List.fromList([1, 2]),
        stagingBase: tmp.path,
        adoptNamed: (toml, dir, doc) async {
          final partial = _material()..remove(kInstanceIdFile);
          await materialiseSovereignIdentity(dir, partial);
        },
      );
      expect(ok, SovereignDocumentAdoption.refused);
      expect(storage.settings[kSovereignIdentitySetting], isNull);
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
      expect(ok, SovereignDocumentAdoption.refused);
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
        expect(ok, SovereignDocumentAdoption.refused);
        expect(storage.settings[kSovereignIdentitySetting], before);
      },
    );

    // THE LOOP-BREAKER. Two devices answer each other's announcements; the
    // moment one receives a document it already holds, nothing changes and it
    // must fall quiet. Reporting success here instead would have them trading
    // identical documents for as long as both are running.
    test(
      'a merge that yields what we already hold reports no change',
      () async {
        final storage = await provisioned();
        final before = storage.settings[kSovereignIdentitySetting];
        final ok = await RealVeilStack.adoptSovereignDocument(
          storage,
          document: Uint8List.fromList([1, 2, 3]),
          stagingBase: tmp.path,
          // What the native side does when the incoming document already names
          // this device and matches: writes back exactly what was there.
          merge: (toml, dir, doc) async =>
              materialiseSovereignIdentity(dir, _material()),
        );
        expect(ok, SovereignDocumentAdoption.alreadyHeld, reason: 'nothing changed, so nothing to announce');
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
      expect(ok, SovereignDocumentAdoption.nothingOffered);
      expect(called, isFalse);
    });
  });

  // ── the address this identity receives under ─────────────────────────────
  //
  // The node speaks on the wire under its config key; a sender seals mail to
  // the IDENTITY. Today those are the same 32 bytes for everyone, which is
  // exactly why the distinction has to exist before the change that parts them:
  // a device still receiving under its transport id would wait where nobody
  // sends, looking reachable from every angle.
  group('sovereignReceiveAddress', () {
    test('is the address the document names', () async {
      final storage = FakeSettingStorage();
      storage.settings[kSovereignIdentitySetting] = encodeSovereignIdentity(
        _material(),
      );
      final addr = await RealVeilStack.sovereignReceiveAddress(
        storage,
        readNodeId: (doc) => Uint8List.fromList(List.filled(32, 5)),
      );
      expect(addr, everyElement(5));
      expect(addr, hasLength(32));
    });

    // A mined identity has no master: its node's degenerate document names only
    // itself and the config id is the whole story. Null says so, rather than
    // inventing an address.
    test('a device with no document has no separate address', () async {
      expect(
        await RealVeilStack.sovereignReceiveAddress(FakeSettingStorage()),
        isNull,
      );
    });

    test('a corrupt entry falls back rather than guessing', () async {
      final storage = FakeSettingStorage();
      storage.settings[kSovereignIdentitySetting] = 'not json at all';
      expect(await RealVeilStack.sovereignReceiveAddress(storage), isNull);
    });

    // A document that will not read must not take the identity off the air:
    // the caller falls back to the config id, which is what every identity
    // without a document uses anyway.
    test('a document that cannot be read falls back', () async {
      final storage = FakeSettingStorage();
      storage.settings[kSovereignIdentitySetting] = encodeSovereignIdentity(
        _material(),
      );
      final addr = await RealVeilStack.sovereignReceiveAddress(
        storage,
        readNodeId: (doc) => throw StateError('decode failed'),
      );
      expect(addr, isNull);
    });
  });
}
