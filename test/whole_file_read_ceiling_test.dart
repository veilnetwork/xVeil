import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/media_object.dart';

/// `loadFile` documents itself as a whole-file read, and both screens that
/// render a stored image called it unbounded — one with no ceiling at all, the
/// other with `(media.size ?? 0) > 24 MiB`, which passes an ABSENT size as zero
/// and reads a file of any size at all. The size in question is the one the
/// SENDER wrote into the post, so omitting it is free.
///
/// The ceiling therefore lives where the size is actually known: in the store,
/// against the size it recorded itself.

HiddenVolumeStorage _storage() {
  final store = FakeKvLogStore();
  return HiddenVolumeStorage(
    ({required Uint8List password, required bool create}) =>
        password.isEmpty ? null : store,
  );
}

void main() {
  test(
    'a file over the ceiling is refused, and one under it still loads',
    () async {
      final s = _storage();
      await s.open(password: 'pw', createIfMissing: true);
      addTearDown(s.close);

      await s.storeFile('small', Uint8List(1024), name: 'small.bin');
      await s.storeFile('big', Uint8List(64 * 1024), name: 'big.bin');

      expect(
        (await s.loadFile('small', maxBytes: 32 * 1024))!.length,
        1024,
        reason: 'the ceiling refused a file that fits under it',
      );
      expect(
        await s.loadFile('big', maxBytes: 32 * 1024),
        isNull,
        reason: 'a whole-file read ran past the ceiling it was given',
      );
      // ...and with no ceiling asked for, nothing changes for the callers that
      // legitimately read whole records (the group index, a manifest, a draft).
      expect((await s.loadFile('big'))!.length, 64 * 1024);
    },
  );

  test('a record whose size cannot be read is REFUSED when a ceiling is asked '
      'for, not read anyway', () async {
    // "We do not know how big this is" must not resolve to zero — that is the
    // shape of the defeated check at the call site, one layer down.
    final store = FakeKvLogStore();
    final s = HiddenVolumeStorage(
      ({required Uint8List password, required bool create}) => store,
    );
    await s.open(password: 'pw', createIfMissing: true);
    addTearDown(s.close);
    await s.storeFile('sizeless', Uint8List(1024), name: 'x.bin');

    // Reach under the storage API and strip the size the writer recorded —
    // a metadata record no writer here would produce, which is the point.
    final key = Uint8List.fromList(utf8.encode('file:sizeless'));
    final raw = store.get(Ns.settings, key)!;
    final meta = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    meta.remove('size');
    store.commit([
      PutOp(
        Ns.settings,
        key,
        Uint8List.fromList(utf8.encode(jsonEncode(meta))),
      ),
    ]);

    expect(
      await s.loadFile('sizeless', maxBytes: 32 * 1024),
      isNull,
      reason: 'an unmeasurable record was read whole under a ceiling',
    );
  });

  test('the inline-image ceiling is one number, shared by both screens', () {
    // It used to be a literal in one screen and absent in the other, which is
    // how one of them ended up with no ceiling at all.
    expect(kInlineImageMaxBytes, 24 * 1024 * 1024);
  });

  test('both inline-image renders ASK for the ceiling', () {
    // A store that enforces a ceiling nobody asks for enforces nothing. These
    // two are the whole-file reads that decode straight into a widget, and
    // neither is reachable from a unit test without standing up its screen —
    // so the call site is pinned at the source, the way this project already
    // pins the headless daemon's import graph.
    const sites = {
      'lib/features/spaces/space_post_media.dart':
          'loadFile(_cid, maxBytes: kInlineImageMaxBytes)',
      'lib/features/groups/group_chat_screen.dart':
          'loadFile(cid, maxBytes: kInlineImageMaxBytes)',
    };
    sites.forEach((path, call) {
      final source = File(
        path,
      ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
      expect(
        source,
        contains(call),
        reason:
            '$path renders a stored image inline without a ceiling: the file '
            'is read whole into RAM and then decoded on top of that, at a size '
            'whoever sent it chose',
      );
    });
  });
}
