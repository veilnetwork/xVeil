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

  test('a share works on a bounded number of requests at once', () async {
    // The nonce cache stops a datagram being replayed and the egress budget
    // stops a big reply being reflected; neither bounds how many requests are
    // IN PROGRESS. Many small ones, each with a fresh nonce, pass both — and
    // the endpoint listener starts every MAC-valid datagram unawaited, so each
    // carries a container read, an AEAD seal and a send over an anonymous
    // circuit with the byte budget barely touched.
    final fixture = await buildFolder(fileCount: 1);
    final hostToClient = StreamController<Uint8List>.broadcast();
    // The host's outbound never lands, so every serve that reaches it holds
    // its place — which is what makes "at once" observable at all.
    final wedged = Completer<void>();
    final host = CloudFolderShareHost(
      capability: fixture.capability,
      storage: fixture.storage,
      listing: fixture.listing,
      maxConcurrentServes: 3,
      send:
          ({
            required servicePublicKey,
            required targetAppId,
            required targetEndpointId,
            required data,
          }) => wedged.future,
    );
    addTearDown(() => wedged.complete());

    final client = CloudFolderShareClient(
      capability: fixture.capability,
      returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
      returnAppId: Uint8List.fromList(List.filled(32, 4)),
      returnEndpointId: 48,
      incoming: hostToClient.stream,
      send: (data) async => unawaited(host.serve(data)),
      randomBytes: _counterBytes(),
    );

    // Twenty distinct, MAC-valid requests. Not awaited: with the host's send
    // wedged no reply ever comes back, which is the point.
    for (var i = 0; i < 20; i++) {
      unawaited(
        client.fetchListing().then<void>((_) {}, onError: (Object _) {}),
      );
    }
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(
      host.servesInFlight,
      lessThanOrEqualTo(3),
      reason: 'twenty fresh requests must not become twenty live operations',
    );
    expect(
      host.servesInFlight,
      greaterThan(0),
      reason: 'a ceiling that admits nothing is not a ceiling',
    );
  });

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

  test('a request whose MAC does not verify is never answered', () async {
    // Found by break-checking: removing the MAC comparison from the host let
    // any request through and NOTHING in the suite noticed. The MAC is the
    // whole authorisation on this path — the share names no recipient — so a
    // request that cannot produce it must get silence, not a chunk.
    final fixture = await buildFolder(fileCount: 1);
    var answers = 0;
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
          }) async => answers++,
    );
    Uint8List? captured;
    // An OPEN stream that never delivers: Stream.empty() closes at once and
    // the client bails before it has asked anything.
    final silence = StreamController<Uint8List>.broadcast();
    addTearDown(silence.close);
    final client = CloudFolderShareClient(
      capability: fixture.capability,
      returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
      returnAppId: Uint8List.fromList(List.filled(32, 4)),
      returnEndpointId: 48,
      incoming: silence.stream,
      send: (data) async => captured ??= Uint8List.fromList(data),
      randomBytes: _counterBytes(),
    );
    // Let it emit exactly one request; nothing answers, so the fetch itself
    // never completes and is deliberately abandoned.
    unawaited(client.fetchListing().then((_) {}, onError: (_) {}));
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(captured, isNotNull, reason: 'the client must have asked');

    // The MAC occupies the tail of the request, so the last byte is part of
    // it and nothing else.
    final forged = Uint8List.fromList(captured!);
    forged[forged.length - 1] ^= 0xff;
    await host.serve(forged);
    expect(answers, 0, reason: 'a forged MAC gets silence');

    // The sanity half: the untouched request IS answered, so "silence" above
    // cannot mean the host was inert all along.
    await host.serve(captured!);
    expect(answers, 1);
  });

  test('a dropped listing request is asked for again, not abandoned', () async {
    final fixture = await buildFolder(fileCount: 1);
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
    // The listing is asked for FIRST, so losing it loses the whole download
    // before a byte moves.
    var droppedOne = false;
    final client = CloudFolderShareClient(
      capability: fixture.capability,
      returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
      returnAppId: Uint8List.fromList(List.filled(32, 4)),
      returnEndpointId: 48,
      incoming: hostToClient.stream,
      timeout: const Duration(milliseconds: 200),
      send: (data) async {
        final isListing = String.fromCharCodes(data.sublist(0, 4)) == 'XLR1';
        if (isListing && !droppedOne) {
          droppedOne = true;
          return; // silently lost in transit
        }
        unawaited(host.serve(data));
      },
      randomBytes: _counterBytes(),
    );

    final listing = await client.fetchListing();
    expect(droppedOne, isTrue, reason: 'the drop must actually have happened');
    expect(listing.entries, isNotEmpty);

    await hostToClient.close();
  });

  /// The manifest is the downloader's only integrity anchor here: bytes come
  /// from a host it does not trust, and nothing re-checks the assembled file —
  /// there is no whole-file hash after the pieces. A host that serves the right
  /// LENGTH of wrong bytes has to be refused per piece.
  test(
    'a folder host serving bytes that do not match the manifest is refused',
    () async {
      final fixture = await buildFolder(fileCount: 1);
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
        timeout: const Duration(milliseconds: 200),
        send: (data) async => unawaited(host.serve(data)),
        randomBytes: _counterBytes(),
      );

      final listing = await client.fetchListing();
      final file = listing.entries.firstWhere((e) => !e.isFolder);
      final contentId = file.manifest!.contentId;

      // Same length, different content: the listing (and so the manifest the
      // client verifies against) is already published and unchanged.
      final honest = fixture.storage.files[contentId]!;
      fixture.storage.files[contentId] = Uint8List.fromList(
        List.generate(honest.length, (i) => (honest[i] + 1) & 0xff),
      );

      await expectLater(client.fetchFile(file), throwsA(isA<Object>()));

      await hostToClient.close();
    },
  );

  test('a dropped chunk request is asked for again, not abandoned', () async {
    final fixture = await buildFolder(fileCount: 1);
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
    // The anonymous path sometimes swallows a request with no error to see.
    // Drop the first file-chunk request and answer everything after it.
    var droppedOne = false;
    final client = CloudFolderShareClient(
      capability: fixture.capability,
      returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
      returnAppId: Uint8List.fromList(List.filled(32, 4)),
      returnEndpointId: 48,
      incoming: hostToClient.stream,
      timeout: const Duration(milliseconds: 200),
      send: (data) async {
        final isChunk = String.fromCharCodes(data.sublist(0, 4)) == 'XFR1';
        if (isChunk && !droppedOne) {
          droppedOne = true;
          return; // silently lost in transit
        }
        unawaited(host.serve(data));
      },
      randomBytes: _counterBytes(),
    );

    final listing = await client.fetchListing();
    final file = listing.entries.firstWhere((e) => !e.isFolder);
    final bytes = await client.fetchFile(file);

    expect(droppedOne, isTrue, reason: 'the drop must actually have happened');
    expect(
      bytes,
      fixture.plaintext[file.manifest!.contentId],
      reason: 'one lost request must not discard the whole file',
    );

    await hostToClient.close();
  });

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

  group('the reply address is the requester\'s to choose (audit XV-07)', () {
    // A listing request is ~150 B and the reply is up to 256 KiB, and the
    // request NAMES the endpoint the reply goes to. The MAC does not help:
    // its key is the folder link, which every holder has and any of them may
    // pass on. Nothing counted the bytes and nothing remembered a nonce, so
    // one datagram could be replayed at whatever rate the attacker liked,
    // aimed wherever they liked, and the host did the sending.
    //
    // Binding the reply to an authenticated sender — the report's remedy — is
    // declined on purpose: a folder link is a bearer capability on a
    // deliberately anonymous path.

    /// One MAC-valid listing request, exactly as a real client emits it.
    Future<Uint8List> askedListing(
      CloudFolderCapability capability,
      Uint8List Function(int) nonces,
    ) async {
      Uint8List? asked;
      final silence = StreamController<Uint8List>.broadcast();
      addTearDown(silence.close);
      final prober = CloudFolderShareClient(
        capability: capability,
        returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
        returnAppId: Uint8List.fromList(List.filled(32, 4)),
        returnEndpointId: 48,
        incoming: silence.stream,
        send: (data) async => asked ??= Uint8List.fromList(data),
        randomBytes: nonces,
      );
      unawaited(prober.fetchListing().then((_) {}, onError: (_) {}));
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return asked!;
    }

    test('one authentic request is answered once, however often it is '
        'resent', () async {
      final fixture = await buildFolder(fileCount: 1);
      var answers = 0;
      var bytes = 0;
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
            }) async {
              answers++;
              bytes += data.length;
            },
      );
      await host.ready;
      // ONE generator across both asks: `_counterBytes` restarts, so two of
      // them would hand out the same nonce and the "different request" half
      // below would be testing nothing.
      final nonces = _counterBytes();
      final request = await askedListing(fixture.capability, nonces);

      await host.serve(request);
      expect(answers, 1, reason: 'the first ask is legitimate and is answered');
      final firstReply = bytes;
      expect(
        firstReply,
        greaterThan(request.length),
        reason:
            'this op only matters because the reply is the bigger half. This '
            'fixture is a two-entry folder; at the 256 KiB ceiling the ratio '
            'against a 150-byte request is about 1700 to 1',
      );

      for (var i = 0; i < 200; i++) {
        await host.serve(request);
      }
      expect(
        answers,
        1,
        reason:
            'the same 150-byte datagram was reflected 200 more times, at an '
            'address the sender of it chose',
      );
      expect(bytes, firstReply);

      // The sanity half: a DIFFERENT authentic request is still served, so
      // "answered once" cannot mean the host stopped answering.
      final second = await askedListing(fixture.capability, nonces);
      expect(second, isNot(request));
      await host.serve(second);
      expect(answers, 2);
    });

    test('a share stops emitting once its budget for the window is spent',
        () async {
      // The nonce cache stops a replay; it cannot stop a link holder minting
      // fresh authentic requests, because minting them is what holding the
      // link means. The budget is the ceiling on THAT — set here far below the
      // production one so the test does not have to move 32 MiB.
      final fixture = await buildFolder(fileCount: 1);
      var clock = DateTime(2030);
      var answers = 0;
      final host = CloudFolderShareHost(
        capability: fixture.capability,
        storage: fixture.storage,
        listing: fixture.listing,
        now: () => clock,
        egressBudgetBytes: 2000,
        egressWindow: const Duration(minutes: 1),
        send:
            ({
              required servicePublicKey,
              required targetAppId,
              required targetEndpointId,
              required data,
            }) async => answers++,
      );
      await host.ready;
      final nonces = _counterBytes();
      for (var i = 0; i < 40; i++) {
        await host.serve(await askedListing(fixture.capability, nonces));
      }
      final spent = answers;
      expect(
        spent,
        greaterThan(0),
        reason: 'a budget that refuses everything is not a budget',
      );
      expect(
        spent,
        lessThan(40),
        reason:
            'forty authentic requests emptied the share with nothing counting '
            'the bytes going out',
      );

      // The window turns over and the share serves again — this is a
      // ceiling on a rate, not a share that breaks the first time it is
      // leaned on.
      clock = clock.add(const Duration(minutes: 2));
      await host.serve(await askedListing(fixture.capability, nonces));
      expect(answers, spent + 1);
    });
  });

  group('a listing that will not seal (audit XV-18)', () {
    // Structurally impeccable — the entry cap exactly, every name inside its
    // own limit — and far past the 256 KiB ceiling, which lives on the
    // CIPHERTEXT and so is invisible to every check that runs before the seal.
    CloudFolderListing bloated(ContentManifest manifest, int revision) =>
        CloudFolderListing(
          name: 'Проекты',
          revision: revision,
          entries: [
            for (var i = 0; i < CloudFolderListing.maxTotalEntries; i++)
              CloudFolderListingEntry.file(
                name: '${'w' * 500}$i',
                manifest: manifest,
              ),
          ],
        );

    test('the host goes on serving the listing it already published', () async {
      final fixture = await buildFolder(fileCount: 1);
      final hostToClient = StreamController<Uint8List>.broadcast();
      addTearDown(hostToClient.close);
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
      CloudFolderShareClient client() => CloudFolderShareClient(
        capability: fixture.capability,
        returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
        returnAppId: Uint8List.fromList(List.filled(32, 4)),
        returnEndpointId: 48,
        incoming: hostToClient.stream,
        send: (data) async => unawaited(host.serve(data)),
        randomBytes: _counterBytes(),
        timeout: const Duration(seconds: 2),
      );
      expect((await client().fetchListing()).revision, 2);

      await expectLater(
        host.setListing(
          bloated(fixture.listing.entries.first.manifest!, 3),
        ),
        throwsA(anything),
        reason: 'a listing past the sealed ceiling must be refused',
      );

      // The refusal used to be reported through the SAME future serve waits
      // on, so a listing the host never accepted silenced the one it had been
      // publishing all along — and no restart brought it back.
      final still = await client().fetchListing();
      expect(still.revision, 2);
      expect(still.totalEntries, fixture.listing.totalEntries);
    });

    test('a host that could not seal its FIRST listing still takes a later '
        'one', () async {
      final fixture = await buildFolder(fileCount: 1);
      final hostToClient = StreamController<Uint8List>.broadcast();
      addTearDown(hostToClient.close);
      var answers = 0;
      final host = CloudFolderShareHost(
        capability: fixture.capability,
        storage: fixture.storage,
        listing: bloated(fixture.listing.entries.first.manifest!, 3),
        send:
            ({
              required servicePublicKey,
              required targetAppId,
              required targetEndpointId,
              required data,
            }) async {
              answers++;
              hostToClient.add(data);
            },
      );
      await expectLater(host.ready, throwsA(anything));

      // Nothing was ever published, so the honest answer is silence — not an
      // empty sealed body, which is not a listing.
      final silence = StreamController<Uint8List>.broadcast();
      addTearDown(silence.close);
      Uint8List? asked;
      final prober = CloudFolderShareClient(
        capability: fixture.capability,
        returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
        returnAppId: Uint8List.fromList(List.filled(32, 4)),
        returnEndpointId: 48,
        incoming: silence.stream,
        send: (data) async => asked ??= Uint8List.fromList(data),
        randomBytes: _counterBytes(),
      );
      unawaited(prober.fetchListing().then((_) {}, onError: (_) {}));
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(asked, isNotNull, reason: 'the prober must have asked');
      await host.serve(asked!);
      expect(answers, 0, reason: 'an unpublished share answers nothing');

      // …and it is REPAIRABLE. This is the whole point: the share used to be
      // dead in exactly this state, because the failure was permanent.
      await host.setListing(
        CloudFolderListing(
          name: 'Проекты',
          revision: 4,
          entries: fixture.listing.entries,
        ),
      );
      final client = CloudFolderShareClient(
        capability: fixture.capability,
        returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
        returnAppId: Uint8List.fromList(List.filled(32, 4)),
        returnEndpointId: 48,
        incoming: hostToClient.stream,
        send: (data) async => unawaited(host.serve(data)),
        randomBytes: _counterBytes(),
        timeout: const Duration(seconds: 2),
      );
      final listing = await client.fetchListing();
      expect(listing.revision, 4);
      expect(listing.totalEntries, fixture.listing.totalEntries);
      expect(answers, 1);
    });
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
