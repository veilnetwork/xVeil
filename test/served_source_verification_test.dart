import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/serve_source.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

// Audit X-02, the half that needs no race.
//
// A large send is served STRAIGHT FROM THE USER'S FILE — deliberately, because
// copying a terabyte attachment into the encrypted store doubles the disk and
// is what overflowed the hidden-volume index. What was persisted is
// `served:$cid = {path, size, pieceSize, name}`, and every later pull reopened
// that PATH, by name, with the manifest read back from `mf:$cid`. Nothing
// compared the two. Replace the file after the send and every subsequent fetch
// handed out the new bytes under the old content id, with a manifest that
// described the old ones.
//
// `resolveSendableFile` at the API edge is not the gap: it resolves symlinks
// before it compares and returns the resolved path. The gap is downstream, in
// what the offer does with that path hours later.
//
// The check that closes it was already in this project —
// `_rebuildManifestFromServedRecord` re-hashes and compares content ids — and
// simply was not called here.

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

class _Link implements VeilTransport {
  _Link(this._me);
  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();
  _Link? peer;
  bool dropManifestOnce = false;

  /// Every piece of content this side put on the wire, by content id.
  ///
  /// The assertion has to be about what the SENDER emitted, not about what an
  /// honest receiver kept: a receiver verifies incoming pieces against the
  /// manifest it was given and would discard the replacement anyway. That
  /// discard is the receiver protecting itself. It does nothing for the person
  /// whose file was read off disk and pushed down a socket, and a peer that
  /// simply keeps what it is sent has no reason to discard anything.
  final Map<String, List<Uint8List>> sentChunks = {};

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _in.stream;
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final env = WireEnvelope.decode(payload);
    if (env.kind == WireKind.contentManifest && dropManifestOnce) {
      dropManifestOnce = false;
      return; // the offer's manifest is "lost" → the receiver must reoffer
    }
    if (env.kind == WireKind.pieceChunk) {
      final frame = parsePieceChunk(env.body);
      (sentChunks[frame.contentId] ??= []).add(frame.data);
    }
    peer?._in.add(
      InboundMessage(
        src: _me,
        payload: payload,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
  }

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _in.close();
}

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

Uint8List _rnd(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

/// Whether [chunk] appears verbatim inside [whole] — "did any of these bytes
/// come off that file".
/// Anchored on the first four bytes so the scan stays linear: [whole] is
/// random, so a false anchor is a one-in-four-billion event per offset.
bool _isSliceOf(Uint8List chunk, Uint8List whole) {
  if (chunk.length < 8 || chunk.length > whole.length) return false;
  for (var start = 0; start + chunk.length <= whole.length; start++) {
    if (whole[start] != chunk[0] ||
        whole[start + 1] != chunk[1] ||
        whole[start + 2] != chunk[2] ||
        whole[start + 3] != chunk[3]) {
      continue;
    }
    var same = true;
    for (var i = 4; i < chunk.length; i++) {
      if (whole[start + i] != chunk[i]) {
        same = false;
        break;
      }
    }
    if (same) return true;
  }
  return false;
}

void main() {
  late NodeId a, b;
  late _Link tA, tB;
  late HiddenVolumeStorage sA, sB;
  late MessagingService mA, mB;
  late Directory workdir;

  /// Opens through the real filesystem opener, counting how many times the
  /// durable source is opened — which is how the verdict cache is observed at
  /// all (a cached answer costs no open).
  var opens = 0;
  Future<VeilServeSource?> countingOpener(String path) async {
    opens++;
    return veilSourceOpener(path);
  }

  setUp(() async {
    opens = 0;
    workdir = await Directory.systemTemp.createTemp('xveil-served-source');
    a = _id(1);
    b = _id(2);
    tA = _Link(a);
    tB = _Link(b);
    tA.peer = tB;
    tB.peer = tA;
    sA = HiddenVolumeStorage(_mem());
    sB = HiddenVolumeStorage(_mem());
    await sA.open(password: 'a', createIfMissing: true);
    await sB.open(password: 'b', createIfMissing: true);
    const fast = Duration(milliseconds: 120);
    mA = MessagingService(
      tA,
      sA,
      contentReRequestInterval: fast,
      contentPacing: Duration.zero,
    )..sourceOpener = countingOpener;
    mA.start();
    mB = MessagingService(
      tB,
      sB,
      contentReRequestInterval: fast,
      contentPacing: Duration.zero,
    )..start();
    await sA.upsertContact(Contact(nodeId: b, status: ContactStatus.accepted));
    await sB.upsertContact(Contact(nodeId: a, status: ContactStatus.accepted));
  });

  tearDown(() async {
    await mA.dispose();
    await mB.dispose();
    await workdir.delete(recursive: true);
  });

  /// A durable offer of [bytes] at [name], sent with its advertise lost so the
  /// receiver has to come back and ask — the restart-shaped path that reopens
  /// the file by name.
  Future<(String cid, File file)> durableOffer(
    String name,
    Uint8List bytes,
  ) async {
    final file = File('${workdir.path}/$name');
    await file.writeAsBytes(bytes);
    Future<Uint8List> read(int offset, int length) async {
      final handle = await file.open();
      try {
        await handle.setPosition(offset);
        return await handle.read(length);
      } finally {
        await handle.close();
      }
    }

    tA.dropManifestOnce = true;
    final cid = await mA.sendFileStreaming(
      b,
      name,
      bytes.length,
      read,
      close: () async {},
      sourcePath: file.path,
    );
    expect(cid, isNotNull, reason: 'the send itself must have worked');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    return (cid!, file);
  }

  test('a durable offer whose file was swapped is not served under the old '
      'content id, while an untouched one still is', () async {
    final honestBytes = _rnd(300000, 91);
    final (honestCid, _) = await durableOffer('honest.bin', honestBytes);
    final (swappedCid, swappedFile) = await durableOffer(
      'swapped.bin',
      _rnd(300000, 92),
    );

    // The swap. SAME LENGTH, different bytes: the manifest stays internally
    // consistent about size, so nothing short of hashing the bytes notices —
    // and an honest receiver verifies against the manifest it was given,
    // which still describes the file that is no longer there.
    final secret = _rnd(300000, 93);
    await swappedFile.writeAsBytes(secret);

    // "Restart" the sender: serve state gone, storage kept — the shape in
    // which the durable record is the only thing left pointing at the file.
    await mA.dispose();
    final mA2 =
        MessagingService(
            tA,
            sA,
            contentReRequestInterval: const Duration(milliseconds: 120),
            contentPacing: Duration.zero,
          )
          ..sourceOpener = countingOpener
          ..start();
    addTearDown(mA2.dispose);

    // THE CONTROL, and it comes first: the untouched offer still works.
    // Refusing everything would "close" this finding and break the feature.
    final honestArrived = mB.contentReceived.first;
    expect(
      await mB.downloadContent(a, honestCid),
      ContentDownloadResult.requestedReoffer,
    );
    final event = await honestArrived.timeout(const Duration(seconds: 20));
    expect(event.contentId, honestCid);
    expect(
      await sB.loadFile(honestCid),
      honestBytes,
      reason: 'a durable offer nobody touched must still serve',
    );
    expect(
      tA.sentChunks[honestCid],
      isNotEmpty,
      reason:
          'the control has to show bytes actually leaving the sender, or '
          'the silence below proves only that nothing was serving at all',
    );

    // THE FINDING: the sender must not read the replacement off disk and
    // put it on the wire under the old content id.
    expect(
      await mB.downloadContent(a, swappedCid),
      ContentDownloadResult.requestedReoffer,
    );
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(
      tA.sentChunks[swappedCid] ?? const <Uint8List>[],
      isEmpty,
      reason:
          'the sender served ${tA.sentChunks[swappedCid]?.length} chunks for '
          'a content id whose file had been replaced — it read whatever the '
          'NAME pointed at and pushed it to the peer',
    );
    final leaked = tA.sentChunks.values
        .expand((chunks) => chunks)
        .where((chunk) => _isSliceOf(chunk, secret));
    expect(
      leaked,
      isEmpty,
      reason: 'bytes of the replacement file reached the wire',
    );
    expect(
      await sB.loadFile(swappedCid),
      isNull,
      reason: 'and the peer ends up with nothing under that content id',
    );
  }, timeout: const Timeout(Duration(seconds: 90)));

  test(
    'the verdict is cached, and not one moment past the file it was about',
    () async {
      final bytes = _rnd(120000, 77);
      final file = File('${workdir.path}/media.bin');
      await file.writeAsBytes(bytes);
      Future<Uint8List> read(int offset, int length) async =>
          Uint8List.sublistView(bytes, offset, offset + length);

      final cid = await mA.registerGroupContentStreaming(
        'media.bin',
        bytes.length,
        read,
        close: () async {},
        sourcePath: file.path,
      );

      // A verdict may only be cached once the file's mtime is older than the
      // coarsest filesystem tick — otherwise a later write could hide under the
      // same stamp. Wait that out so the caching branch is the one under test.
      await Future<void>.delayed(const Duration(milliseconds: 2200));

      opens = 0;
      expect(await mA.verifiedGroupContentSourcePath(cid), file.path);
      final firstCheckOpens = opens;
      expect(
        firstCheckOpens,
        greaterThan(0),
        reason: 'the first check has to actually read the file',
      );

      expect(await mA.verifiedGroupContentSourcePath(cid), file.path);
      expect(
        opens,
        firstCheckOpens,
        reason:
            'the second check re-hashed a file that had not changed — the '
            'verdict cache is not doing its job, and every serve pays a full pass',
      );

      // Same length, different bytes. A cache keyed on anything the write does
      // not disturb would keep answering with the stale verdict.
      await file.writeAsBytes(_rnd(120000, 78));
      expect(
        await mA.verifiedGroupContentSourcePath(cid),
        isNull,
        reason:
            'a cached verdict outlived the file it was taken on — the path was '
            'still handed out for content it no longer holds',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('a durable offer stops serving when the grant that authorized it goes '
      'away, and keeps serving while it holds', () async {
    // Found while validating X-02 rather than in the report. A `served:`
    // record used to be its own authorization: written once at send time and
    // reopened by name forever after, it survived the folder being withdrawn
    // from the token AND the token being revoked outright. Old offers went on
    // reading out of a folder nobody had granted, for as long as a peer kept
    // asking.
    final bytes = _rnd(120000, 55);
    final file = File('${workdir.path}/delegated.bin');
    await file.writeAsBytes(bytes);
    Future<Uint8List> read(int offset, int length) async =>
        Uint8List.sublistView(bytes, offset, offset + length);

    // Settle the file past the stamp window FIRST, so the CONTENT verdict is
    // cached by the time the grant is withdrawn. Without that the file is too
    // fresh to cache and this test cannot tell a re-asked authorization from
    // one that is riding along on the content cache — which is exactly the
    // shape this is here to forbid.
    await Future<void>.delayed(const Duration(milliseconds: 2200));

    var granted = true;
    final asked = <(String, List<String>)>[];
    mA.servedSourceAuthorizer = (path, roots) async {
      asked.add((path, roots));
      return granted;
    };

    final cid = await mA.sendFileStreaming(
      b,
      'delegated.bin',
      bytes.length,
      read,
      close: () async {},
      sourcePath: file.path,
      sourceRoots: [workdir.path],
    );
    expect(cid, isNotNull);
    expect(
      await sA.getSetting('served:$cid'),
      contains(workdir.path),
      reason: 'the grant has to be recorded, or there is nothing to re-check',
    );

    // THE CONTROL: while the grant holds, the offer serves.
    expect(await mA.verifiedGroupContentSourcePath(cid!), file.path);
    expect(asked, hasLength(1));
    expect(asked.single.$1, file.path);
    expect(
      asked.single.$2,
      [workdir.path],
      reason: 'the authorizer was handed the path and the recorded grant',
    );

    // …and the moment it does not, it stops. No restart, no cache expiry.
    granted = false;
    expect(
      await mA.verifiedGroupContentSourcePath(cid),
      isNull,
      reason:
          'the offer kept serving out of a folder that is no longer granted — '
          'the record was acting as its own authorization',
    );
    expect(asked, hasLength(2), reason: 'the answer must not be cached');
  });

  test('a GROUP offer stops serving when the grant that authorized it goes '
      'away, and keeps serving while it holds', () async {
    // The group twin of the test above (audit XV-04). The reopen has re-checked
    // the grant since `5e78b5c` — but the group registration recorded no roots
    // for it to check, so every group offer read as user-picked and outlived
    // both the folder leaving the token and the token being revoked.
    final bytes = _rnd(100000, 61);
    final file = File('${workdir.path}/group-delegated.bin');
    await file.writeAsBytes(bytes);
    Future<Uint8List> read(int offset, int length) async =>
        Uint8List.sublistView(bytes, offset, offset + length);

    var granted = true;
    final asked = <(String, List<String>)>[];
    mA.servedSourceAuthorizer = (path, roots) async {
      asked.add((path, roots));
      return granted;
    };

    final cid = await mA.registerGroupContentStreaming(
      'group-delegated.bin',
      bytes.length,
      read,
      close: () async {},
      sourcePath: file.path,
      sourceRoots: [workdir.path],
    );
    // The ROOTS field specifically — the record's `path` already contains the
    // workdir, so a substring check here would pass on a record that carries
    // no grant at all.
    expect(
      (jsonDecode((await sA.getSetting('served:$cid'))!) as Map)['roots'],
      [workdir.path],
      reason: 'the grant has to be recorded, or there is nothing to re-check',
    );

    // THE CONTROL: while the grant holds, the offer serves.
    expect(await mA.verifiedGroupContentSourcePath(cid), file.path);
    expect(
      asked,
      hasLength(1),
      reason: 'the reopen never asked — the record was not delegated',
    );
    expect(asked.single.$1, file.path);
    expect(asked.single.$2, [workdir.path]);

    granted = false;
    expect(
      await mA.verifiedGroupContentSourcePath(cid),
      isNull,
      reason:
          'the group offer kept reading out of a folder that is no longer '
          'granted',
    );
    expect(asked, hasLength(2), reason: 'the answer must not be cached');
  });

  test('a group file the user picked here is not gated either', () async {
    // Fail-closed for delegated group offers must not become fail-closed for
    // a person choosing a file in this app — the same rule the 1:1 path has.
    final bytes = _rnd(80000, 62);
    final file = File('${workdir.path}/group-mine.bin');
    await file.writeAsBytes(bytes);
    Future<Uint8List> read(int offset, int length) async =>
        Uint8List.sublistView(bytes, offset, offset + length);

    var asked = 0;
    mA.servedSourceAuthorizer = (path, roots) async {
      asked++;
      return false; // would refuse everything, if it were consulted
    };

    final cid = await mA.registerGroupContentStreaming(
      'group-mine.bin',
      bytes.length,
      read,
      close: () async {},
      sourcePath: file.path,
    );
    expect(await mA.verifiedGroupContentSourcePath(cid), file.path);
    expect(asked, 0, reason: 'nothing delegated this, so nothing gates it');
  });

  test('a file the user picked here is not gated by anyone\'s grant', () async {
    // A record with no roots came from a person choosing a file in this app.
    // Fail-closed for delegated offers must not become fail-closed for those.
    final bytes = _rnd(90000, 56);
    final file = File('${workdir.path}/mine.bin');
    await file.writeAsBytes(bytes);
    Future<Uint8List> read(int offset, int length) async =>
        Uint8List.sublistView(bytes, offset, offset + length);

    var asked = 0;
    mA.servedSourceAuthorizer = (path, roots) async {
      asked++;
      return false; // would refuse everything, if it were consulted
    };

    final cid = await mA.sendFileStreaming(
      b,
      'mine.bin',
      bytes.length,
      read,
      close: () async {},
      sourcePath: file.path,
    );
    expect(await mA.verifiedGroupContentSourcePath(cid!), file.path);
    expect(asked, 0, reason: 'nothing delegated this, so nothing gates it');
  });

  test(
    'an unstattable source name is re-checked every time, never cached',
    () async {
      // The in-memory sources this project's tests and any non-filesystem opener
      // use have nothing to stamp. A verdict cached under "no stamp" could never
      // be invalidated, so there must not be one.
      var bytes = _rnd(300000, 73);
      Future<Uint8List> read(int offset, int length) async =>
          Uint8List.sublistView(bytes, offset, offset + length);
      mA.sourceOpener = (path) async =>
          path == 'mem://verified' ? (read: read, close: () async {}) : null;

      final cid = await mA.registerGroupContentStreaming(
        'verified.bin',
        bytes.length,
        read,
        close: () async {},
        sourcePath: 'mem://verified',
      );
      expect(await mA.verifiedGroupContentSourcePath(cid), 'mem://verified');

      bytes = Uint8List.fromList(bytes)..[0] ^= 0xff;
      expect(
        await mA.verifiedGroupContentSourcePath(cid),
        isNull,
        reason: 'a source with no stamp must be re-hashed, not remembered',
      );
    },
  );
}
