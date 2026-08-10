// What a member content host does when one member asks for everything at once.
//
// Every accepted request makes the host build a return circuit to answer, and
// the call site was `unawaited(host.serve(data))` with nothing in the way. A
// member holding the current epoch key could therefore turn a stream of
// ~158-byte datagrams into as many onion round trips as it cared to send: the
// host reads, seals and sends for each one, and holds a pending answer per
// request until the circuit completes.
//
// The bound is asserted HERE and not only on `ServeAdmission`, because a gate
// that exists and is never consulted passes every test written about the gate.
// What matters is the decision at the call site: how many answers this host
// actually starts.
//
// Requests are built by the real client rather than hand-rolled, so the wire
// under test is the wire the protocol produces — including a MAC that the host
// accepts.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/serve_admission.dart';
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
  final epochKey = Uint8List.fromList(List.filled(32, 0x11));
  final servicePublicKey = Uint8List.fromList(List.filled(32, 0x51));
  final appId = Uint8List.fromList(List.filled(32, 0xA7));
  const endpointId = 40;
  final expiresAtMs = DateTime(2035).millisecondsSinceEpoch;

  /// One valid request wire, produced by the real client.
  ///
  /// The client is pointed at a host that never answers, so its first send is
  /// captured and the fetch is abandoned. That request is what a member sends
  /// when it wants a chunk, MAC and all.
  Future<Uint8List> validRequest(
    _Storage storage,
    ContentManifest manifest,
  ) async {
    final captured = Completer<Uint8List>();
    // A stream that never emits and never CLOSES. `Stream.empty()` closes at
    // once, and the client's `.first` then throws "No element" before it ever
    // sends — the fetch has to reach its send for there to be a request.
    final silence = StreamController<Uint8List>.broadcast();
    addTearDown(silence.close);
    final client = CloudMemberContentClient(
      documentId: documentId,
      epochKey: epochKey,
      servicePublicKey: servicePublicKey,
      appId: appId,
      endpointId: endpointId,
      expiresAtMs: expiresAtMs,
      returnServicePublicKey: Uint8List.fromList(List.filled(32, 3)),
      returnAppId: Uint8List.fromList(List.filled(32, 4)),
      returnEndpointId: 48,
      incoming: silence.stream,
      send: (data) async {
        if (!captured.isCompleted) captured.complete(data);
      },
      timeout: const Duration(milliseconds: 20),
      randomBytes: _counterBytes(),
    );
    unawaited(client.fetchFile(manifest).catchError((_) => Uint8List(0)));
    return captured.future;
  }

  test('a flood of valid requests starts a bounded number of answers', () async {
    final storage = _Storage();
    final bytes = Uint8List.fromList(
      List.generate(700, (i) => (i * 13) & 0xff),
    );
    final manifest = ContentManifest.fromBytes('m.bin', bytes, pieceSize: 256);
    storage.files[manifest.contentId] = bytes;

    // Answers are held open, so nothing frees a slot on its own — which is what
    // a real onion round trip looks like for the seconds it takes.
    final held = Completer<void>();
    var started = 0;
    final host = CloudMemberContentHost(
      documentId: documentId,
      servicePublicKey: servicePublicKey,
      appId: appId,
      endpointId: endpointId,
      expiresAtMs: expiresAtMs,
      storage: storage,
      epochKey: epochKey,
      servable: [manifest],
      send:
          ({
            required servicePublicKey,
            required targetAppId,
            required targetEndpointId,
            required data,
          }) async {
            started++;
            await held.future;
          },
    );

    final wire = await validRequest(storage, manifest);
    final defaults = ServeAdmission();
    final flood = defaults.maxConcurrent + defaults.maxWaiting + 16;
    final serves = [for (var i = 0; i < flood; i++) host.serve(wire)];
    // Let everything that can reach the send actually reach it.
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(
      started,
      defaults.maxConcurrent,
      reason:
          'the host started $started answers at once for $flood requests — one '
          'member turns tiny datagrams into that many return circuits',
    );

    held.complete();
    await Future.wait(serves);
    expect(
      started,
      defaults.maxConcurrent + defaults.maxWaiting,
      reason:
          'the queued requests must still be answered once slots free — a '
          'bound that drops what it could have served breaks honest members, '
          'and the excess beyond the queue must NOT be answered',
    );
  });

  test('an unauthorized flood cannot occupy the slots', () async {
    final storage = _Storage();
    final bytes = Uint8List.fromList(
      List.generate(700, (i) => (i * 13) & 0xff),
    );
    final manifest = ContentManifest.fromBytes('m.bin', bytes, pieceSize: 256);
    storage.files[manifest.contentId] = bytes;

    final held = Completer<void>();
    var started = 0;
    final host = CloudMemberContentHost(
      documentId: documentId,
      servicePublicKey: servicePublicKey,
      appId: appId,
      endpointId: endpointId,
      expiresAtMs: expiresAtMs,
      storage: storage,
      epochKey: epochKey,
      servable: [manifest],
      send:
          ({
            required servicePublicKey,
            required targetAppId,
            required targetEndpointId,
            required data,
          }) async {
            started++;
            await held.future;
          },
    );

    // The same wire with a broken MAC. A gate placed ahead of authorization
    // would let this fill the queue and refuse the authorized requests that
    // follow — which is worse than no gate at all.
    final wire = await validRequest(storage, manifest);
    final forged = Uint8List.fromList(wire);
    forged[forged.length - 1] ^= 0xff;
    for (var i = 0; i < 200; i++) {
      unawaited(host.serve(forged));
    }
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(started, 0, reason: 'a forged request was answered');

    final defaults = ServeAdmission();
    final serves = [
      for (var i = 0; i < defaults.maxConcurrent; i++) host.serve(wire),
    ];
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(
      started,
      defaults.maxConcurrent,
      reason:
          'authorized requests were refused because unauthorized ones were '
          'holding the slots',
    );
    held.complete();
    await Future.wait(serves);
  });
}
