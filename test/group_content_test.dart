// Groups content path, brick 1: the signed fetch request + the holder-side
// membership authorization gate (doc/GROUPS-CONTENT-PATH.md).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_policy.dart';

NodeId _id(int fill) => NodeId(Uint8List.fromList(List.filled(32, fill)));

void main() {
  final owner = _id(1);
  final stranger = _id(9);

  GroupContentRequest req({
    NodeId? requester,
    String cid = 'c0ffee',
    String nonce = 'n1',
    int ts = 1_000_000,
  }) =>
      GroupContentRequest(
        groupId: _id(2),
        contentId: cid,
        requester: requester ?? owner,
        nonce: nonce,
        tsMs: ts,
        signature: Uint8List(64),
        authorPubKey: Uint8List(32),
      );

  test('canonical bytes are stable across a JSON round-trip', () {
    final r = req();
    final rt = GroupContentRequest.fromJson(r.toJson())!;
    expect(rt.canonicalBytes(), r.canonicalBytes());
    expect(rt.contentId, 'c0ffee');
    expect(rt.requester, owner);
    expect(rt.signature.length, 64);
    expect(rt.authorPubKey.length, 32);
  });

  test('fromJson rejects malformed requests', () {
    expect(GroupContentRequest.fromJson(null), isNull);
    expect(GroupContentRequest.fromJson('nope'), isNull);
    final good = req().toJson();
    for (final broken in [
      {...good}..remove('sig'),
      {...good, 'cid': ''},
      {...good, 'n': ''},
      {...good, 'ts': 'later'},
      {...good, 'gid': 'not-hex'},
    ]) {
      expect(GroupContentRequest.fromJson(broken), isNull,
          reason: 'must reject $broken');
    }
  });

  test('authorize: the full denial matrix, silent-drop semantics aside', () {
    final state = GroupState.genesis(owner); // owner is the only member
    final referenced = {'c0ffee'};
    final seen = <String>{};
    GroupContentDenial? auth(GroupContentRequest r,
            {bool sigOk = true, int now = 1_000_000}) =>
        authorizeGroupContentRequest(
          r,
          state: state,
          referenced: referenced,
          nowMs: now,
          seenNonces: seen,
          verify: (_) => sigOk,
        );

    // A fresh, member-signed request for referenced content is authorized.
    expect(auth(req()), isNull);

    // Each gate refuses independently.
    expect(auth(req(), sigOk: false), GroupContentDenial.badSignature);
    expect(auth(req(requester: stranger)), GroupContentDenial.notAMember);
    expect(auth(req(cid: 'feedbeef')), GroupContentDenial.unknownContent);

    // Freshness: too old AND too far in the future are both stale.
    final windowMs = kGroupContentRequestWindow.inMilliseconds;
    expect(auth(req(), now: 1_000_000 + windowMs + 1),
        GroupContentDenial.stale);
    expect(auth(req(ts: 1_000_000 + windowMs + 1)), GroupContentDenial.stale);
    // Right at the edge of the window is still fresh.
    expect(auth(req(), now: 1_000_000 + windowMs), isNull);

    // Replay: once the holder records the nonce, the same request is refused.
    seen.add('n1');
    expect(auth(req()), GroupContentDenial.replayed);
    expect(auth(req(nonce: 'n2')), isNull);
  });
}
