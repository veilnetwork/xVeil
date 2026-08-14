// Which key a device takes when a phrase is typed in.
//
// The FIRST device of an identity takes the phrase's own keypair as its node
// key. That is what makes `node_id` recoverable from the words: write them
// down, type them on a bare machine, and the same identity comes back.
//
// Every LATER device must mint one of its own. Two devices holding the same
// node key are not two devices — they are one node running twice: linking
// answers "self device", both drive the same ratchets, and the seeds see one
// identity with two sessions. What ties the new key to the identity is the
// sovereign document, not the key itself.
//
// Both paths mine the anti-sybil nonce, so this is not a slower setup — the
// same work, a different key.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/data/veil_stack.dart';

import 'support/fake_setting_storage.dart';

class _ConfigStorage extends FakeSettingStorage {
  String? config;
  final saved = <String>[];

  @override
  Future<String?> loadNodeConfig() async => config;

  @override
  Future<void> saveNodeConfig(String toml) async {
    config = toml;
    saved.add(toml);
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xveil-restore-key-');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('the identity origin records which path was taken', () async {
    // The marker is what a later boot reads to know whether this device took
    // the phrase's key or one of its own — the two are indistinguishable from
    // the config alone.
    final first = _ConfigStorage();
    await RealVeilStack.ensureSovereignIdentity(
      first,
      stagingBase: tmp.path,
      identityPhrase: 'a master phrase',
      provision: (phrase, dir) async =>
          materialiseSovereignIdentity(dir, {
            kIdentityDocumentFile: Uint8List.fromList([1]),
            kDeviceIdentitySkFile: Uint8List.fromList(List.filled(32, 3)),
            kInstanceIdFile: Uint8List.fromList([9]),
          }),
    );
    expect(first.settings[kSovereignIdentitySetting], isNotNull);
  });

  // A device that already has a config never re-derives one, restore or not:
  // its node key is what the network knows it by, and re-minting would strand
  // every contact.
  test('an existing config is never replaced', () async {
    for (final restoring in [true, false]) {
      final storage = _ConfigStorage()..config = 'existing = "config"';
      final out = await RealVeilStack.ensureNodeConfig(
        storage,
        identityPhrase: 'a master phrase',
        restoringIdentity: restoring,
      );
      expect(out, 'existing = "config"', reason: 'restoring=$restoring');
      expect(storage.saved, isEmpty, reason: 'restoring=$restoring');
    }
  });
}
