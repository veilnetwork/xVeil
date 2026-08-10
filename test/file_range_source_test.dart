// report9 X-03.
//
// `fileRangeSource` hands one `RandomAccessFile` to every reader of a blob,
// and that is deliberate: a seek-heavy player reopening per hop would be a
// syscall storm. What it cannot also do is let two readers use it at once.
//
// A range read is `setPosition` then `read`, two awaits with a suspension
// between them. The media stream server answers Range requests concurrently,
// so a second reader's `setPosition` lands in that gap and the first one reads
// from the second one's offset. Both callers are handed bytes; one of them is
// handed the wrong ones, with nothing in the answer to say so.
//
// The interleaving is not a coin toss here — Dart's event loop resumes the
// two futures in a fixed order — which is what makes this testable at all.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';

import 'package:xveil/data/range_sources.dart';
import 'package:xveil/domain/range_source.dart';

void main() {
  late Directory workdir;
  late File blob;

  setUp(() async {
    workdir = await Directory.systemTemp.createTemp('xveil-range');
    blob = File('${workdir.path}/blob.bin');
    // Every byte says which 100-byte block it came from, so a read that
    // landed at the wrong offset is legible rather than merely unequal.
    final bytes = List<int>.generate(2000, (i) => (i ~/ 100) & 0xFF);
    await blob.writeAsBytes(bytes);
  });

  tearDown(() async => workdir.delete(recursive: true));

  _walkerGuards();

  test('two readers of one handle each get the range they asked for', () async {
    final source = await fileRangeSource(blob.path);
    expect(source, isNotNull);
    addTearDown(source!.dispose);

    // Started together, awaited together: the second `setPosition` is issued
    // while the first read is suspended between its own two awaits.
    final first = source.read(0, 100);
    final second = source.read(1000, 100);
    final results = await Future.wait([first, second]);

    expect(results[0], isNotNull, reason: 'the first read failed outright');
    expect(results[1], isNotNull, reason: 'the second read failed outright');
    expect(
      results[0]!.toList(),
      List.filled(100, 0),
      reason:
          'the reader that asked for bytes 0..100 was handed another '
          "reader's range — and was told nothing about it",
    );
    expect(
      results[1]!.toList(),
      List.filled(100, 10),
      reason: 'the reader that asked for bytes 1000..1100 got the wrong range',
    );
  });

  test('an already-open handle keeps serving the file it was opened on', () async {
    final source = await fileRangeSource(blob.path);
    expect(source, isNotNull);
    addTearDown(source!.dispose);
    expect(source.size, 2000);

    // The name now means a shorter file.
    final decoy = File('${workdir.path}/decoy.bin');
    await decoy.writeAsBytes(List<int>.filled(10, 0xEE));
    await decoy.rename(blob.path);

    expect(source.size, 2000, reason: 'the size followed the name');
    final tail = await source.read(1900, 100);
    expect(
      tail,
      isNotNull,
      reason: 'the handle stopped serving the file it was opened on',
    );
    expect(tail!.length, 100);
  });

  // Structural, because the half it guards is a RACE: the size is wrong only
  // when the name is repointed between the measurement and the open, and that
  // window is two syscalls wide inside this function. What is checkable
  // exactly is the order — measure the descriptor, never the name — and that
  // is the shape that leaves no window at all.
  //
  // The behavioural test above cannot stand in for it: it stages the swap
  // AFTER the source exists, so it passes against both orders.
  test('the size is measured on the descriptor, never on the name', () {
    final source = File('lib/data/range_sources.dart').readAsStringSync();
    final start = source.indexOf('Future<RangeSource?> fileRangeSource(');
    expect(start, isNot(-1), reason: 'fileRangeSource is gone — guard is dead');
    final end = source.indexOf('\nFuture<RangeSource?> storageRangeSource(');
    expect(end, greaterThan(start), reason: 'could not bound fileRangeSource');
    final body = source.substring(start, end);

    final openAt = body.indexOf('.open(');
    final lengthAt = body.indexOf('.length()');
    expect(openAt, isNot(-1), reason: 'the file is no longer opened here');
    expect(lengthAt, isNot(-1), reason: 'the size is no longer measured here');
    expect(
      openAt,
      lessThan(lengthAt),
      reason:
          'the size is taken before the open, so it describes whatever the '
          'name meant then while the bytes come from whatever it means now — '
          'the shape audit X-02 removed from the send path',
    );
    expect(
      body,
      isNot(contains('File(path).length()')),
      reason: 'the size is being taken by NAME rather than from the handle',
    );
  });
}

// report9 X-06 — the shared walkers' own promise, checked.
//
// Both `rangeChunks` and `blobChunks` document "no hop exceeds the chunk
// bound". Both clamped an over-delivering reader against the bytes REMAINING
// rather than against the bound, and early in a large walk the remainder is
// the whole rest of the blob — so the promise held for the last hop and
// nothing else. A reader that answers a 256 KiB request with 8 MiB is not
// hypothetical: it is any source that rounds up to its own block size.
void _walkerGuards() {
  test('a hop never exceeds the chunk bound, however much a reader hands back',
      () async {
    const total = 1 << 20; // 1 MiB, so the remainder dwarfs the bound
    const cap = 64 * 1024;
    var asked = <int>[];
    final greedy = RangeSource(
      size: total,
      // Answers with FOUR times what it was asked for, every time.
      read: (offset, length) async {
        asked.add(length);
        final over = length * 4;
        final end = offset + over > total ? total - offset : over;
        return Uint8List(end);
      },
    );

    final hops = await rangeChunks(greedy, 0, total, chunkBytes: cap).toList();
    expect(hops, isNotEmpty);
    for (final hop in hops) {
      expect(
        hop.length,
        lessThanOrEqualTo(cap),
        reason:
            'a hop of ${hop.length} bytes went out under a $cap-byte bound — '
            'the peak this walker exists to bound is whatever the reader felt '
            'like returning',
      );
    }
    expect(
      hops.fold<int>(0, (a, b) => a + b.length),
      total,
      reason: 'the walk must still yield exactly what it promised',
    );
    expect(
      asked.every((n) => n <= cap),
      isTrue,
      reason: 'the walker asked for more than its own bound',
    );
  });
}
