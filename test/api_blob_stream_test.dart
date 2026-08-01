// P0-5: REST downloads must never hold a blob whole in RAM, and a video must
// be able to seek without pulling the file to do it. These cover the two
// halves: the `Range` grammar (pure, so the whole matrix is cheap) and the
// bounded-read contract of the source itself.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/api/api_server.dart';
import 'package:xveil/api/blob_sources.dart';

void main() {
  group('parseByteRange', () {
    test('absent or foreign unit means serve the whole blob', () {
      expect(parseByteRange(null, 100), isNull);
      expect(parseByteRange('items=0-10', 100), isNull);
      expect(parseByteRange('bytes=', 100), isNull);
    });

    test('a closed range is clamped to the blob, not rejected', () {
      final r = parseByteRange('bytes=10-19', 100)!;
      expect(r.start, 10);
      expect(r.endInclusive, 19);
      expect(r.length, 10);

      // Past the end is legal and means "to the end" — a player asking for a
      // generous window must get bytes, not a 416.
      final clamped = parseByteRange('bytes=90-4096', 100)!;
      expect(clamped.endInclusive, 99);
      expect(clamped.length, 10);
    });

    test('an open range runs to the end', () {
      final r = parseByteRange('bytes=64-', 100)!;
      expect(r.start, 64);
      expect(r.endInclusive, 99);
    });

    test('a suffix range counts back from the end', () {
      final r = parseByteRange('bytes=-10', 100)!;
      expect(r.start, 90);
      expect(r.endInclusive, 99);

      // A suffix longer than the blob is the whole blob, not an error.
      final whole = parseByteRange('bytes=-500', 100)!;
      expect(whole.start, 0);
      expect(whole.endInclusive, 99);
    });

    test('a well-formed range outside the blob is unsatisfiable, not ignored', () {
      // The distinction that matters: ignoring this would answer 200 with the
      // WRONG bytes, and a client that asked for a seek would splice them in
      // at the offset it requested.
      expect(parseByteRange('bytes=100-200', 100)!.unsatisfiable, isTrue);
      expect(parseByteRange('bytes=20-10', 100)!.unsatisfiable, isTrue);
      expect(parseByteRange('bytes=0-0', 0)!.unsatisfiable, isTrue);
    });

    test('malformed input is ignored rather than guessed at', () {
      expect(parseByteRange('bytes=abc-def', 100), isNull);
      expect(parseByteRange('bytes=-0', 100), isNull);
      expect(parseByteRange('bytes=-x', 100), isNull);
      expect(parseByteRange('bytes=1-2,5-6', 100), isNull); // multi-range
      expect(parseByteRange('bytes=5', 100), isNull);
    });

    test('the last byte is reachable', () {
      final r = parseByteRange('bytes=99-99', 100)!;
      expect(r.start, 99);
      expect(r.length, 1);
    });
  });

  group('ApiBlobSource', () {
    test('reads only the range asked for, never the whole blob', () async {
      final asked = <(int, int)>[];
      final source = ApiBlobSource(
        size: 10 * 1024 * 1024,
        read: (offset, length) async {
          asked.add((offset, length));
          return Uint8List(length);
        },
      );

      await source.read(1024, 64);

      expect(asked, [(1024, 64)]);
    });
  });

  group('blobChunks', () {
    test('never hands back more than was promised', () async {
      // A reader that over-delivers (a store returning a whole aligned record
      // for a small ask) must not push the walk past `total` — the writer has
      // already sent a Content-Length, so an extra byte is a corrupt response.
      final source = ApiBlobSource(
        size: 1000,
        read: (offset, length) async => Uint8List(length + 500),
      );

      var got = 0;
      await for (final chunk in blobChunks(source, 0, 100)) {
        got += chunk.length;
      }

      expect(got, 100);
    });

    test('honours the start offset of a range', () async {
      final offsets = <int>[];
      final source = ApiBlobSource(
        size: 10000,
        read: (offset, length) async {
          offsets.add(offset);
          return Uint8List(length);
        },
      );

      await blobChunks(source, 4096, 10).drain<void>();

      expect(offsets, [4096]);
    });

    test('throws rather than ending short when the blob dies', () async {
      final source = ApiBlobSource(
        size: 100,
        read: (_, _) async => null,
      );
      expect(
        blobChunks(source, 0, 100).drain<void>(),
        throwsA(isA<BlobUnreadable>()),
      );
    });
  });

  group('drainBlobSource', () {
    test('reassembles a small blob exactly', () async {
      final bytes = Uint8List.fromList(List<int>.generate(5000, (i) => i % 251));
      final out = await drainBlobSource(inMemoryBlobSource(bytes));
      expect(out, bytes);
    });

    test('refuses a blob too large to hold, instead of holding it', () async {
      // The point of the cap: a legacy byte-array consumer must fail loudly
      // rather than quietly reintroduce the unbounded read this epic removed.
      final huge = ApiBlobSource(
        size: kMaxInlineBinaryResponseBytes + 1,
        read: (_, _) async => Uint8List(0),
      );
      expect(
        () => drainBlobSource(huge),
        throwsA(isA<BlobTooLargeToBuffer>()),
      );
    });

    test('a blob that goes unreadable partway yields null, not a short read', () async {
      var calls = 0;
      final source = ApiBlobSource(
        size: 4 * kBlobStreamChunkBytes,
        read: (_, length) async {
          calls++;
          return calls > 2 ? null : Uint8List(length);
        },
      );
      expect(await drainBlobSource(source), isNull);
    });

    test('walks a multi-chunk blob in bounded hops', () async {
      final sizes = <int>[];
      final total = kBlobStreamChunkBytes * 3 + 7;
      final source = ApiBlobSource(
        size: total,
        read: (offset, length) async {
          sizes.add(length);
          return Uint8List(length);
        },
      );

      final out = await drainBlobSource(source, limit: total);

      expect(out!.length, total);
      expect(sizes.every((s) => s <= kBlobStreamChunkBytes), isTrue,
          reason: 'a hop larger than the chunk defeats the bound');
      expect(sizes.last, 7, reason: 'the tail hop asks only for what remains');
    });
  });

  group('inMemoryBlobSource', () {
    test('clamps a read that runs past the end', () async {
      final source = inMemoryBlobSource(
        Uint8List.fromList(const [1, 2, 3, 4, 5]),
      );
      expect(await source.read(3, 100), [4, 5]);
      expect(await source.read(5, 10), isEmpty);
    });
  });
}
