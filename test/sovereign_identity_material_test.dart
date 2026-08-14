// The identity material that has to outlive the runtime directory.
//
// The node reads its identity from `veil_dir`, and ours is created fresh under
// a random name on every boot and deleted on the way down. The document and the
// device key cannot live there: the document is published under this identity's
// node_id and names this device's key, so re-minting either one each boot would
// orphan every peer's copy. They are provisioned once, stored in the container,
// and laid back out before each start.
//
// Which makes the encoding load-bearing in a quiet way. A stored entry that
// silently decodes to "almost everything" is worse than one that fails: the
// node does not complain about a missing document, it builds a DEGENERATE one
// where master == device — and that is exactly the state in which two devices
// restored from one phrase collapse into a single node.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';

Map<String, Uint8List> _material({
  Uint8List? document,
  Uint8List? deviceSk,
  Uint8List? instanceId,
  Uint8List? sigKeyIdx,
}) => {
  kIdentityDocumentFile: document ?? Uint8List.fromList([1, 2, 3]),
  kDeviceIdentitySkFile: deviceSk ?? Uint8List.fromList(List.filled(32, 7)),
  kInstanceIdFile: instanceId ?? Uint8List.fromList([9, 9]),
  kDeviceSigKeyIdxFile: ?sigKeyIdx,
};

void main() {
  group('encode/decode', () {
    test('round-trips arbitrary bytes', () {
      // Real material is a signed document and a 32-byte key seed: binary,
      // including bytes that are not valid UTF-8. Anything that goes through a
      // string on the way to the container has to survive them.
      final files = _material(
        document: Uint8List.fromList([0, 255, 128, 0xC3, 0x28, 10, 13]),
        deviceSk: Uint8List.fromList(List.generate(32, (i) => i * 8 % 256)),
      );
      final decoded = decodeSovereignIdentity(encodeSovereignIdentity(files));
      expect(decoded, isNotNull);
      for (final name in files.keys) {
        expect(decoded![name], orderedEquals(files[name]!), reason: name);
      }
    });

    test('carries a file this build does not know about', () {
      // The whole reason for a self-describing map: a later veil that writes a
      // fourth file must not shift the meaning of the first three.
      final withExtra = {
        ..._material(),
        'something_new.bin': Uint8List.fromList([4, 2]),
      };
      final decoded = decodeSovereignIdentity(
        encodeSovereignIdentity(withExtra),
      );
      expect(decoded!['something_new.bin'], orderedEquals([4, 2]));
    });

    test('encodes deterministically so a re-save is a no-op write', () {
      // The container shields byte-identical writes; that shield only works if
      // the same material encodes to the same string, whatever order the map
      // was built in.
      final a = <String, Uint8List>{
        kInstanceIdFile: Uint8List.fromList([9]),
        kIdentityDocumentFile: Uint8List.fromList([1]),
        kDeviceIdentitySkFile: Uint8List.fromList([2]),
      };
      final b = <String, Uint8List>{
        kDeviceIdentitySkFile: Uint8List.fromList([2]),
        kIdentityDocumentFile: Uint8List.fromList([1]),
        kInstanceIdFile: Uint8List.fromList([9]),
      };
      expect(encodeSovereignIdentity(a), encodeSovereignIdentity(b));
    });

    // A corrupt entry must not come back as a half-populated directory: the
    // node would take the missing document as "not provisioned" and mint a
    // degenerate identity without a word.
    test('refuses anything that is not a map of base64', () {
      expect(decodeSovereignIdentity('not json at all'), isNull);
      expect(decodeSovereignIdentity('[1,2,3]'), isNull);
      expect(decodeSovereignIdentity('"a string"'), isNull);
      expect(decodeSovereignIdentity(jsonEncode({'a': 5})), isNull);
      expect(decodeSovereignIdentity(jsonEncode({'a': '!!not base64!!'})), isNull);
    });

    test('an empty map decodes to nothing, not to null', () {
      // Distinct from corruption: it decodes, and then fails the completeness
      // check below. Collapsing the two would report a decode error for a
      // truthful "nothing was provisioned".
      final decoded = decodeSovereignIdentity(jsonEncode(<String, String>{}));
      expect(decoded, isNotNull);
      expect(missingSovereignIdentityFiles(decoded!), hasLength(3));
    });
  });

  group('missingSovereignIdentityFiles', () {
    test('complete material is missing nothing', () {
      expect(missingSovereignIdentityFiles(_material()), isEmpty);
    });

    test('the subkey index is optional', () {
      // Absent while this device is the only one; written once a delegation
      // puts another device's key in the document. Requiring it would refuse
      // every freshly provisioned device.
      expect(
        missingSovereignIdentityFiles(_material()),
        isEmpty,
        reason: 'material without device_sig_key_idx.bin is complete',
      );
      expect(kSovereignIdentityFiles, contains(kDeviceSigKeyIdxFile));
      expect(kRequiredSovereignIdentityFiles, isNot(contains(kDeviceSigKeyIdxFile)));
    });

    test('names each required file that is absent', () {
      final files = _material()..remove(kDeviceIdentitySkFile);
      expect(missingSovereignIdentityFiles(files), [kDeviceIdentitySkFile]);
      files.remove(kIdentityDocumentFile);
      expect(
        missingSovereignIdentityFiles(files),
        containsAll([kIdentityDocumentFile, kDeviceIdentitySkFile]),
      );
    });

    // An empty file is the shape a truncated write leaves behind, and the node
    // treats it as a broken document rather than as an absent one — which is a
    // hard failure, not a fallback. Catch it here instead.
    test('an empty file counts as missing', () {
      final files = _material(document: Uint8List(0));
      expect(missingSovereignIdentityFiles(files), [kIdentityDocumentFile]);
    });
  });

  group('collect and materialise', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('xveil-sovereign-test-');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('a laid-out directory reads back as what was written', () async {
      final files = _material(sigKeyIdx: Uint8List.fromList([0, 1]));
      await materialiseSovereignIdentity(tmp.path, files);
      final read = await collectSovereignIdentity(tmp.path);
      expect(read.keys, unorderedEquals(files.keys));
      for (final name in files.keys) {
        expect(read[name], orderedEquals(files[name]!), reason: name);
      }
    });

    // The runtime directory also holds sockets and the deployment PSK. Sweeping
    // it wholesale into the container would put per-launch ephemera — and a
    // deployment secret — into permanent storage.
    test('collect takes only the identity files', () async {
      await materialiseSovereignIdentity(tmp.path, _material());
      await File('${tmp.path}/obfs4_psk.b64').writeAsString('a-shared-secret');
      await File('${tmp.path}/veil.sock').writeAsString('');
      final read = await collectSovereignIdentity(tmp.path);
      expect(read.keys, unorderedEquals(kRequiredSovereignIdentityFiles));
    });

    test('materialise writes only the identity files', () async {
      await materialiseSovereignIdentity(tmp.path, {
        ..._material(),
        'obfs4_psk.b64': Uint8List.fromList(utf8.encode('nope')),
      });
      expect(await File('${tmp.path}/obfs4_psk.b64').exists(), isFalse);
      expect(await File('${tmp.path}/$kIdentityDocumentFile').exists(), isTrue);
    });

    test('creates the directory when it is not there yet', () async {
      final nested = '${tmp.path}/not/created/yet';
      await materialiseSovereignIdentity(nested, _material());
      expect(await File('$nested/$kIdentityDocumentFile').exists(), isTrue);
    });

    test('an absent directory collects to nothing rather than throwing',
        () async {
      expect(await collectSovereignIdentity('${tmp.path}/never-made'), isEmpty);
    });

    // The device key is a secret sitting in a directory the node also fills
    // with sockets. It gets 0600 rather than whatever the umask hands out.
    test('the device key is not readable by anyone else', () async {
      if (Platform.isWindows) return;
      await materialiseSovereignIdentity(tmp.path, _material());
      final mode = await Process.run('stat', [
        '-f',
        '%Lp',
        '${tmp.path}/$kDeviceIdentitySkFile',
      ]);
      expect((mode.stdout as String).trim(), '600');
    });
  });

  test('the container key is versioned', () {
    // A later layout must not be read as a corrupt copy of this one.
    expect(kSovereignIdentitySetting, endsWith('.v1'));
  });
}
