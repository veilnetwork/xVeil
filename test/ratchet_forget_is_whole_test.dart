import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';

/// `saveRatchetStates` goes out of its way to keep a conversation inside ONE
/// commit — "never let one straddle two commits, however large it is, or a
/// crash between them restores a session whose halves came from different
/// points in the chain".
///
/// The delete path did not keep the same rule. It flattened every
/// conversation's deletes into one list and cut it every 128 ops, so a
/// conversation straddled a commit boundary whenever the total crossed one —
/// which any multi-conversation `forgetPeer` does, and a single large session
/// does on its own (a 256 KiB state is 256 chunks).
///
/// A crash between the two halves takes the head record, and the read path
/// then answers "nothing held" for that conversation — so nothing ever looks
/// for the rest. The tail chunks stay on disk holding chain keys, unreachable
/// and never scrubbed, which is what this namespace exists to prevent.
class _CommitRecordingStore extends FakeKvLogStore {
  final commits = <List<KvLogOp>>[];

  @override
  int commit(List<KvLogOp> ops) {
    commits.add(List<KvLogOp>.unmodifiable(ops));
    return super.commit(ops);
  }
}

Uint8List _key(int n) =>
    Uint8List.fromList(List<int>.generate(kRatchetKeyLen, (i) => (n * 31 + i) & 0xff));

void main() {
  test('forgetting never splits one conversation across commits', () async {
    final backing = _CommitRecordingStore();
    final storage = HiddenVolumeStorage(
      ({required password, required bool create}) => backing,
    );
    await storage.open(password: 'pw', createIfMissing: true);

    // Three sessions of 51 chunks each: 153 deletes, which the old cut at 128
    // splits through the middle of the third.
    const blobLen = 50 * 1024;
    final keys = [_key(1), _key(2), _key(3)];
    await storage.saveRatchetStates([
      for (final k in keys)
        RatchetStateEntry(
          k,
          Uint8List.fromList(List<int>.generate(blobLen, (i) => i & 0xff)),
        ),
    ]);

    backing.commits.clear();
    final forgotten = await storage.forgetRatchetStates(keys);
    expect(forgotten, keys.length, reason: 'all three were stored');

    // Which commit each conversation's deletes landed in. More than one is
    // the defect: a crash between them leaves half a session on disk.
    for (final k in keys) {
      final landed = <int>{};
      for (var c = 0; c < backing.commits.length; c++) {
        for (final op in backing.commits[c]) {
          if (op is! DeleteOp) continue;
          if (op.key.length < kRatchetKeyLen) continue;
          final prefix = Uint8List.sublistView(op.key, 0, kRatchetKeyLen);
          var same = true;
          for (var i = 0; i < kRatchetKeyLen; i++) {
            if (prefix[i] != k[i]) {
              same = false;
              break;
            }
          }
          if (same) landed.add(c);
        }
      }
      expect(
        landed.length,
        1,
        reason:
            'a conversation was deleted across ${landed.length} commits; a '
            'crash between them leaves its tail chunks on disk holding chain '
            'keys, with the head gone so nothing looks for them',
      );
    }

    // And the deletion still did its job, batching aside.
    for (final k in keys) {
      expect(
        await storage.loadRatchetState(k),
        isNull,
        reason: 'the session must be gone, not merely tidily deleted',
      );
    }
  });
}
