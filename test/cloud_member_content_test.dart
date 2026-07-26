import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/state/cloud_folder_share.dart'
    show CloudFolderShareStorage;
import 'package:xveil/state/cloud_member_content.dart';

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

Uint8List Function(int) _counterBytes() {
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

void main() {
  final documentId = Uint8List.fromList(List.generate(32, (i) => i + 1));
  final epoch1 = Uint8List.fromList(List.filled(32, 0x11));
  final epoch2 = Uint8List.fromList(List.filled(32, 0x22));
  final servicePublicKey = Uint8List.fromList(List.filled(32, 0x51));
  final appId = Uint8List.fromList(List.filled(32, 0xA7));
  const endpointId = 40;
  final expiresAtMs = DateTime(2035).millisecondsSinceEpoch;

  ({_Storage storage, ContentManifest manifest, Uint8List bytes}) fixture() {
    final storage = _Storage();
    final bytes = Uint8List.fromList(
      List.generate(700, (i) => (i * 13) & 0xff),
    );
    final manifest = ContentManifest.fromBytes('m.bin', bytes, pieceSize: 256);
    storage.files[manifest.contentId] = bytes;
    return (storage: storage, manifest: manifest, bytes: bytes);
  }

  CloudMemberContentClient client({
    required Uint8List epochKey,
    required Stream<Uint8List> incoming,
    required CloudMemberContentHost host,
  }) => CloudMemberContentClient(
    documentId: documentId,
    epochKey: epochKey,
    servicePublicKey: servicePublicKey,
    appId: appId,
    endpointId: endpointId,
    expiresAtMs: expiresAtMs,
    returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
    returnAppId: Uint8List.fromList(List.filled(32, 4)),
    returnEndpointId: 48,
    incoming: incoming,
    send: (data) async => unawaited(host.serve(data)),
    timeout: const Duration(milliseconds: 400),
    randomBytes: _counterBytes(),
  );

  test('a member fetches a file under the current epoch key', () async {
    final f = fixture();
    final hostToClient = StreamController<Uint8List>.broadcast();
    final host = CloudMemberContentHost(
      documentId: documentId,
      servicePublicKey: servicePublicKey,
      appId: appId,
      endpointId: endpointId,
      expiresAtMs: expiresAtMs,
      storage: f.storage,
      epochKey: epoch1,
      servable: [f.manifest],
      send:
          ({
            required servicePublicKey,
            required targetAppId,
            required targetEndpointId,
            required data,
          }) async => hostToClient.add(data),
    );
    final member = client(
      epochKey: epoch1,
      incoming: hostToClient.stream,
      host: host,
    );
    expect(await member.fetchFile(f.manifest), f.bytes);
    await hostToClient.close();
  });

  test('an epoch rotation instantly cuts off the old-key member', () async {
    final f = fixture();
    final hostToClient = StreamController<Uint8List>.broadcast();
    final host = CloudMemberContentHost(
      documentId: documentId,
      servicePublicKey: servicePublicKey,
      appId: appId,
      endpointId: endpointId,
      expiresAtMs: expiresAtMs,
      storage: f.storage,
      epochKey: epoch1,
      servable: [f.manifest],
      send:
          ({
            required servicePublicKey,
            required targetAppId,
            required targetEndpointId,
            required data,
          }) async => hostToClient.add(data),
    );
    // The removed member still holds epoch1. Owner rotates to epoch2.
    host.rekey(epoch2, [f.manifest]);
    final removed = client(
      epochKey: epoch1,
      incoming: hostToClient.stream,
      host: host,
    );
    await expectLater(
      removed.fetchFile(f.manifest),
      throwsA(isA<TimeoutException>()),
      reason: 'the old epoch key no longer derives a valid subkey',
    );
    // A retained member with the new epoch key still fetches.
    final retained = client(
      epochKey: epoch2,
      incoming: hostToClient.stream,
      host: host,
    );
    expect(await retained.fetchFile(f.manifest), f.bytes);
    await hostToClient.close();
  });

  test('a file removed from the servable set stops being served', () async {
    final f = fixture();
    final hostToClient = StreamController<Uint8List>.broadcast();
    final host = CloudMemberContentHost(
      documentId: documentId,
      servicePublicKey: servicePublicKey,
      appId: appId,
      endpointId: endpointId,
      expiresAtMs: expiresAtMs,
      storage: f.storage,
      epochKey: epoch1,
      servable: [f.manifest],
      send:
          ({
            required servicePublicKey,
            required targetAppId,
            required targetEndpointId,
            required data,
          }) async => hostToClient.add(data),
    );
    host.rekey(epoch1, const []); // same epoch, file dropped
    final member = client(
      epochKey: epoch1,
      incoming: hostToClient.stream,
      host: host,
    );
    await expectLater(
      member.fetchFile(f.manifest),
      throwsA(isA<TimeoutException>()),
    );
    await hostToClient.close();
  });

  test('an expired share never answers', () async {
    final f = fixture();
    final hostToClient = StreamController<Uint8List>.broadcast();
    final host = CloudMemberContentHost(
      documentId: documentId,
      servicePublicKey: servicePublicKey,
      appId: appId,
      endpointId: endpointId,
      expiresAtMs: DateTime(2000).millisecondsSinceEpoch,
      storage: f.storage,
      epochKey: epoch1,
      servable: [f.manifest],
      now: () => DateTime(2030),
      send:
          ({
            required servicePublicKey,
            required targetAppId,
            required targetEndpointId,
            required data,
          }) async => hostToClient.add(data),
    );
    final member = CloudMemberContentClient(
      documentId: documentId,
      epochKey: epoch1,
      servicePublicKey: servicePublicKey,
      appId: appId,
      endpointId: endpointId,
      expiresAtMs: DateTime(2000).millisecondsSinceEpoch,
      returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
      returnAppId: Uint8List.fromList(List.filled(32, 4)),
      returnEndpointId: 48,
      incoming: hostToClient.stream,
      send: (data) async => unawaited(host.serve(data)),
      timeout: const Duration(milliseconds: 300),
      randomBytes: _counterBytes(),
    );
    await expectLater(
      member.fetchFile(f.manifest),
      throwsA(isA<TimeoutException>()),
    );
    await hostToClient.close();
  });

  test('a silently dropped request is retried, not thrown away', () async {
    // Denials in the anonymous path are silent by design, so a lost request
    // is indistinguishable from a refusal until the deadline passes. Without
    // a retry one dropped datagram discards every chunk already pulled — on
    // the live stand that was minutes of work lost to a single loss.
    final f = fixture();
    final hostToClient = StreamController<Uint8List>.broadcast();
    final host = CloudMemberContentHost(
      documentId: documentId,
      servicePublicKey: servicePublicKey,
      appId: appId,
      endpointId: endpointId,
      expiresAtMs: expiresAtMs,
      storage: f.storage,
      epochKey: epoch1,
      servable: [f.manifest],
      send:
          ({
            required servicePublicKey,
            required targetAppId,
            required targetEndpointId,
            required data,
          }) async => hostToClient.add(data),
    );
    var sent = 0;
    final member = CloudMemberContentClient(
      documentId: documentId,
      epochKey: epoch1,
      servicePublicKey: servicePublicKey,
      appId: appId,
      endpointId: endpointId,
      expiresAtMs: expiresAtMs,
      returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
      returnAppId: Uint8List.fromList(List.filled(32, 4)),
      returnEndpointId: 48,
      incoming: hostToClient.stream,
      send: (data) async {
        sent++;
        if (sent == 2) return; // this one never reaches the host
        unawaited(host.serve(data));
      },
      timeout: const Duration(milliseconds: 200),
      randomBytes: _counterBytes(),
    );
    // 700 bytes over 256-byte pieces of one chunk each: three chunks, plus one
    // re-send of the one that vanished.
    expect(await member.fetchFile(f.manifest), f.bytes);
    expect(sent, 4, reason: 'the dropped request was sent again');
    await hostToClient.close();
  });

  test(
    'a slow send does not spend the reply budget of the chunks behind it',
    () async {
      // Several chunk requests are put in flight before any reply is awaited,
      // and sends leave one at a time. A deadline armed when the matcher is
      // attached — rather than when the request actually goes out — charges
      // every chunk for the sends queued ahead of it, so the tail of a window
      // expired before it had even been asked for. Here each send costs more
      // than half the per-chunk budget, which only a deadline started after the
      // send can survive.
      final storage = _Storage();
      final bytes = Uint8List.fromList(
        List.generate(2048, (i) => (i * 7) & 0xff),
      );
      final manifest = ContentManifest.fromBytes(
        'slow.bin',
        bytes,
        pieceSize: 2048,
      );
      storage.files[manifest.contentId] = bytes;
      final hostToClient = StreamController<Uint8List>.broadcast();
      final host = CloudMemberContentHost(
        documentId: documentId,
        servicePublicKey: servicePublicKey,
        appId: appId,
        endpointId: endpointId,
        expiresAtMs: expiresAtMs,
        storage: storage,
        epochKey: epoch1,
        servable: [manifest],
        send:
            ({
              required servicePublicKey,
              required targetAppId,
              required targetEndpointId,
              required data,
            }) async => hostToClient.add(data),
      );
      var sends = Future<void>.value();
      Future<void> slowSerialSend(Uint8List data) {
        sends = sends.then((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          unawaited(host.serve(data));
        });
        return sends;
      }

      final member = CloudMemberContentClient(
        documentId: documentId,
        epochKey: epoch1,
        servicePublicKey: servicePublicKey,
        appId: appId,
        endpointId: endpointId,
        expiresAtMs: expiresAtMs,
        returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
        returnAppId: Uint8List.fromList(List.filled(32, 4)),
        returnEndpointId: 48,
        incoming: hostToClient.stream,
        send: slowSerialSend,
        timeout: const Duration(milliseconds: 150),
        randomBytes: _counterBytes(),
      );
      expect(await member.fetchFile(manifest), bytes);
      await hostToClient.close();
    },
  );
}
