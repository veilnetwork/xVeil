import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/cloud_capability.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/state/cloud_folder_share.dart';

class _SequenceRandom implements Random {
  _SequenceRandom(this._seed);
  int _seed;
  @override
  bool nextBool() => nextInt(2) == 1;
  @override
  double nextDouble() => nextInt(1 << 24) / (1 << 24);
  @override
  int nextInt(int max) {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return _seed % max;
  }
}

/// In-memory storage that serves ranges of a few content ids.
class _Storage implements CloudFolderShareStorage {
  final Map<String, Uint8List> files = {};

  @override
  Future<Uint8List?> readFileRange(
    String contentId,
    int offset,
    int length,
  ) async {
    final bytes = files[contentId];
    if (bytes == null || offset < 0 || offset + length > bytes.length) {
      return null;
    }
    return Uint8List.sublistView(bytes, offset, offset + length);
  }
}

void main() {
  Future<
    ({
      CloudFolderCapability capability,
      _Storage storage,
      CloudFolderListing listing,
      Map<String, Uint8List> plaintext,
    })
  >
  buildFolder({int fileCount = 2}) async {
    final rng = _SequenceRandom(3);
    final storage = _Storage();
    final entries = <CloudFolderListingEntry>[];
    final plaintext = <String, Uint8List>{};
    for (var i = 0; i < fileCount; i++) {
      final bytes = Uint8List.fromList(
        List.generate(600 + i * 130, (j) => (j * (i + 3)) & 0xff),
      );
      final manifest = ContentManifest.fromBytes(
        'file$i.bin',
        bytes,
        pieceSize: 256,
      );
      storage.files[manifest.contentId] = bytes;
      plaintext[manifest.contentId] = bytes;
      entries.add(
        CloudFolderListingEntry.file(name: 'file$i.bin', manifest: manifest),
      );
    }
    // One nested folder holding the last file too, to exercise recursion.
    final listing = CloudFolderListing(
      name: 'Проекты',
      revision: 2,
      entries: [
        entries.first,
        CloudFolderListingEntry.folder(
          name: 'вложенная',
          entries: entries.skip(1).toList(),
        ),
      ],
    );
    final link = await CloudCapabilityCodec.createFolder(
      folderName: 'Проекты',
      listingRevision: 2,
      expiresAtMs: DateTime(2035).millisecondsSinceEpoch,
      servicePublicKey: Uint8List.fromList(List.filled(32, 0x51)),
      appId: Uint8List.fromList(List.filled(32, 0xA7)),
      endpointId: 40,
      random: rng,
    );
    final capability =
        ((await CloudCapabilityCodec.parseLink(link)) as ParsedCloudFolderLink)
            .capability;
    return (
      capability: capability,
      storage: storage,
      listing: listing,
      plaintext: plaintext,
    );
  }

  test(
    'client fetches the listing and every file through the folder share',
    () async {
      final fixture = await buildFolder(fileCount: 2);
      final hostToClient = StreamController<Uint8List>.broadcast();
      final host = CloudFolderShareHost(
        capability: fixture.capability,
        storage: fixture.storage,
        listing: fixture.listing,
        send:
            ({
              required servicePublicKey,
              required targetAppId,
              required targetEndpointId,
              required data,
            }) async => hostToClient.add(data),
      );
      final client = CloudFolderShareClient(
        capability: fixture.capability,
        returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
        returnAppId: Uint8List.fromList(List.filled(32, 4)),
        returnEndpointId: 48,
        incoming: hostToClient.stream,
        send: (data) async => unawaited(host.serve(data)),
        randomBytes: _counterBytes(),
      );

      final listing = await client.fetchListing();
      expect(listing.revision, 2);
      expect(listing.name, 'Проекты');
      expect(listing.totalEntries, 3);

      // Fetch a top-level file and a nested file; both must verify.
      final topFile = listing.entries.firstWhere((e) => !e.isFolder);
      final nestedFile = listing.entries
          .firstWhere((e) => e.isFolder)
          .entries!
          .single;
      final topBytes = await client.fetchFile(topFile);
      final nestedBytes = await client.fetchFile(nestedFile);
      expect(topBytes, fixture.plaintext[topFile.manifest!.contentId]);
      expect(nestedBytes, fixture.plaintext[nestedFile.manifest!.contentId]);

      await hostToClient.close();
    },
  );

  test(
    'a removed file stops being served after the listing is replaced',
    () async {
      final fixture = await buildFolder(fileCount: 2);
      final hostToClient = StreamController<Uint8List>.broadcast();
      final host = CloudFolderShareHost(
        capability: fixture.capability,
        storage: fixture.storage,
        listing: fixture.listing,
        send:
            ({
              required servicePublicKey,
              required targetAppId,
              required targetEndpointId,
              required data,
            }) async => hostToClient.add(data),
      );
      final client = CloudFolderShareClient(
        capability: fixture.capability,
        returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
        returnAppId: Uint8List.fromList(List.filled(32, 4)),
        returnEndpointId: 48,
        incoming: hostToClient.stream,
        send: (data) async => unawaited(host.serve(data)),
        randomBytes: _counterBytes(),
        timeout: const Duration(milliseconds: 400),
      );

      final nestedFile = fixture.listing.entries
          .firstWhere((e) => e.isFolder)
          .entries!
          .single;
      // Replace the listing with only the top-level file (revision bumped).
      await host.setListing(
        CloudFolderListing(
          name: 'Проекты',
          revision: 3,
          entries: [fixture.listing.entries.first],
        ),
      );
      // The removed nested file no longer serves — the fetch times out silently.
      await expectLater(
        client.fetchFile(nestedFile),
        throwsA(isA<TimeoutException>()),
      );
      // The retained file still fetches.
      final topFile = fixture.listing.entries.first;
      expect(
        await client.fetchFile(topFile),
        fixture.plaintext[topFile.manifest!.contentId],
      );
      await hostToClient.close();
    },
  );

  test(
    'an expired folder share serves the same silence as a bad MAC',
    () async {
      final fixture = await buildFolder(fileCount: 1);
      final sent = <Uint8List>[];
      // A capability that expired in the past: the host must refuse to serve
      // even a MAC-valid request from a bearer who still holds the folder key.
      final expiredCap = CloudFolderCapability(
        shareId: fixture.capability.shareId,
        key: fixture.capability.key,
        servicePublicKey: fixture.capability.servicePublicKey,
        appId: fixture.capability.appId,
        endpointId: fixture.capability.endpointId,
        expiresAtMs: DateTime(2000).millisecondsSinceEpoch,
        folderName: fixture.capability.folderName,
        listingRevision: fixture.capability.listingRevision,
      );
      final host = CloudFolderShareHost(
        capability: expiredCap,
        storage: fixture.storage,
        listing: fixture.listing,
        now: () => DateTime(2030),
        send:
            ({
              required servicePublicKey,
              required targetAppId,
              required targetEndpointId,
              required data,
            }) async => sent.add(data),
      );
      await host.ready;
      final incoming = StreamController<Uint8List>.broadcast();
      final client = CloudFolderShareClient(
        capability: expiredCap,
        returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
        returnAppId: Uint8List.fromList(List.filled(32, 4)),
        returnEndpointId: 48,
        incoming: incoming.stream,
        send: (data) async => unawaited(host.serve(data)),
        randomBytes: _counterBytes(),
        timeout: const Duration(milliseconds: 200),
      );
      await expectLater(
        client.fetchListing(),
        throwsA(isA<TimeoutException>()),
      );
      expect(sent, isEmpty, reason: 'an expired share never answers');
      await incoming.close();
    },
  );

  test('a rollback listing revision is rejected by the client', () async {
    final fixture = await buildFolder(fileCount: 1);
    final hostToClient = StreamController<Uint8List>.broadcast();
    // Capability minted at revision 2; a host answering revision 1 is a
    // rollback and must be rejected before it can hide newer content.
    final host = CloudFolderShareHost(
      capability: fixture.capability,
      storage: fixture.storage,
      listing: CloudFolderListing(
        name: 'Проекты',
        revision: 1,
        entries: fixture.listing.entries,
      ),
      send:
          ({
            required servicePublicKey,
            required targetAppId,
            required targetEndpointId,
            required data,
          }) async => hostToClient.add(data),
    );
    final client = CloudFolderShareClient(
      capability: fixture.capability,
      returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
      returnAppId: Uint8List.fromList(List.filled(32, 4)),
      returnEndpointId: 48,
      incoming: hostToClient.stream,
      send: (data) async => unawaited(host.serve(data)),
      randomBytes: _counterBytes(),
    );
    await expectLater(
      client.fetchListing(),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('rollback'),
        ),
      ),
    );
    await hostToClient.close();
  });
}

/// A deterministic non-repeating nonce generator for the client (each call
/// yields distinct bytes so concurrent in-flight requests never collide).
Uint8List Function(int count) _counterBytes() {
  var counter = 0;
  return (count) {
    counter++;
    final out = Uint8List(count);
    for (var i = 0; i < count; i++) {
      out[i] = (counter + i) & 0xff;
    }
    return out;
  };
}
