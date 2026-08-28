import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/frame_fragments.dart';

// An app frame above ~1.6 KB never arrived and nothing said so: `veil_send`
// returns OK once the local node accepts the IPC write, and the frame dies
// past that. Content chunks are ~5.6 KB, so no file could ever transfer while
// short text messages worked fine.

NodeId _peer(int seed) =>
    NodeId(Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff)));

Uint8List _payload(int n, {int seed = 7}) =>
    Uint8List.fromList(List<int>.generate(n, (i) => (i * 31 + seed) & 0xff));

/// Every fragment of a payload but the last — a set that is held and never
/// completes, which is the shape a flood takes.
List<Uint8List> _unfinished(int size, int seed) {
  final frames = fragmentFrame(_payload(size, seed: seed));
  return frames.sublist(0, frames.length - 1);
}

void main() {
  group('splitting', () {
    test('a short payload travels untouched — ordinary messages pay nothing', () {
      final small = _payload(200);
      final frames = fragmentFrame(small);
      expect(frames, hasLength(1));
      expect(identical(frames.single, small), isTrue);
    });

    test('every frame of a split payload fits the wire limit', () {
      // 5600 B is the size of a real content chunk — the thing that could
      // never arrive.
      for (final size in [1201, 2000, 5600, 122880]) {
        final frames = fragmentFrame(_payload(size));
        expect(frames.length, greaterThan(1), reason: '$size B must split');
        for (final f in frames) {
          expect(
            f.length,
            lessThanOrEqualTo(kMaxFrameBytes),
            reason: '$size B produced a ${f.length} B frame',
          );
        }
      }
    });

    test('the limit stays under the IPv6 minimum MTU', () {
      // Measured good 1583 B, measured lost 1683 B. The constant is deliberately
      // not tuned to sit just inside that cliff: its cause was never pinned
      // down, so a limit chosen to hug it breaks on a smaller-MTU network.
      expect(kMaxFrameBytes, lessThan(1280));
    });

    test('a payload beyond what fragmenting can carry throws, never vanishes', () {
      expect(
        () => fragmentFrame(Uint8List(kMaxFragmentedPayloadBytes + 1)),
        throwsA(isA<FrameTooLargeError>()),
      );
    });
  });

  group('round trip', () {
    test('a split payload reassembles byte for byte', () {
      final r = FragmentReassembler();
      for (final size in [1201, 5600, 40000]) {
        final payload = _payload(size, seed: size);
        Uint8List? done;
        for (final f in fragmentFrame(payload)) {
          done = r.accept(_peer(1), f);
        }
        expect(done, equals(payload), reason: '$size B did not round-trip');
      }
    });

    test('fragments arriving out of order still reassemble', () {
      final r = FragmentReassembler();
      final payload = _payload(5600);
      final frames = fragmentFrame(payload).reversed.toList();
      Uint8List? done;
      for (final f in frames) {
        done = r.accept(_peer(1), f);
      }
      expect(done, equals(payload));
    });

    test('a whole payload passes straight through', () {
      final r = FragmentReassembler();
      final small = _payload(100);
      expect(r.accept(_peer(1), small), equals(small));
      expect(r.pendingSets, 0);
    });

    test('the same peer can assemble two payloads at once', () {
      final r = FragmentReassembler();
      final a = _payload(3000, seed: 1);
      final b = _payload(3000, seed: 2);
      final fa = fragmentFrame(a), fb = fragmentFrame(b);
      Uint8List? doneA, doneB;
      for (var i = 0; i < fa.length; i++) {
        doneA = r.accept(_peer(1), fa[i]) ?? doneA;
        doneB = r.accept(_peer(1), fb[i]) ?? doneB;
      }
      expect(doneA, equals(a));
      expect(doneB, equals(b));
    });

    test('two peers sending the identical payload do not merge', () {
      // The frame id comes from the payload, so both peers derive the SAME id.
      // Only the source keeps them apart.
      final r = FragmentReassembler();
      final payload = _payload(2000); // exactly two fragments
      final frames = fragmentFrame(payload);
      expect(frames, hasLength(2));
      expect(r.accept(_peer(1), frames[0]), isNull);
      expect(r.accept(_peer(2), frames[0]), isNull);
      expect(r.pendingSets, 2);
      expect(r.accept(_peer(1), frames[1]), equals(payload));
      expect(r.pendingSets, 1, reason: "peer 2's half must survive");
    });
  });

  group('retries', () {
    test('a retry completes a set the first attempt left half-arrived', () {
      // Nothing acknowledges individual fragments, so a retry resends ALL of
      // them. This is what makes retries accumulate instead of starting over:
      // drop one fragment, and the retry only has to land that one.
      final r = FragmentReassembler();
      final payload = _payload(5600);
      final frames = fragmentFrame(payload);
      for (var i = 0; i < frames.length; i++) {
        if (i == 2) continue; // this one is lost
        expect(r.accept(_peer(1), frames[i]), isNull);
      }
      // The retry carries the same id because the id is the payload's hash.
      Uint8List? done;
      for (final f in fragmentFrame(payload)) {
        done = r.accept(_peer(1), f) ?? done;
      }
      expect(done, equals(payload));
    });

    test('duplicate fragments are harmless', () {
      final r = FragmentReassembler();
      final payload = _payload(3000);
      final frames = fragmentFrame(payload);
      Uint8List? done;
      for (final f in [...frames, ...frames]) {
        done = r.accept(_peer(1), f) ?? done;
      }
      expect(done, equals(payload));
    });
  });

  group('a payload that looks like a fragment', () {
    // The receiver decides "fragment or whole payload" by four leading bytes.
    // A short payload that happens to start with those bytes would be parsed
    // as a header and its body handed on as if it were the message — so the
    // sender wraps it even though it would have fit. This case needs no
    // oversized payload to reach it, which is exactly why it is easy to miss.
    Uint8List magicLeading(int n) {
      final b = _payload(n);
      b.setRange(0, 4, kFragmentMagic);
      return b;
    }

    test('it is wrapped despite fitting the wire limit', () {
      final payload = magicLeading(100);
      final frames = fragmentFrame(payload);
      expect(frames, hasLength(1));
      expect(
        identical(frames.single, payload),
        isFalse,
        reason: 'an unwrapped payload would be re-read as a header',
      );
      expect(frames.single.length, payload.length + kFragmentHeaderBytes);
    });

    test('it round-trips unchanged', () {
      final r = FragmentReassembler();
      final payload = magicLeading(100);
      Uint8List? done;
      for (final f in fragmentFrame(payload)) {
        done = r.accept(_peer(1), f) ?? done;
      }
      expect(done, equals(payload));
    });

    test('a header claiming an impossible index is not believed', () {
      final frame = Uint8List(kFragmentHeaderBytes + 4)
        ..setRange(0, 4, kFragmentMagic);
      frame[12] = 0;
      frame[13] = 2; // total = 2
      frame[14] = 0;
      frame[15] = 5; // index = 5, outside its own total
      expect(parseFragment(frame), isNull);
    });

    test('a header claiming zero fragments is not believed', () {
      final frame = Uint8List(kFragmentHeaderBytes + 4)
        ..setRange(0, 4, kFragmentMagic);
      frame[12] = 0;
      frame[13] = 0; // total = 0
      expect(parseFragment(frame), isNull);
    });
  });

  group('bounds', () {
    test('an incomplete set is dropped once it goes stale', () {
      var now = DateTime(2026, 8, 7, 12);
      final r = FragmentReassembler(
        ttl: const Duration(minutes: 2),
        now: () => now,
      );
      final frames = fragmentFrame(_payload(5600));
      expect(r.accept(_peer(1), frames[0]), isNull);
      expect(r.pendingSets, 1);
      now = now.add(const Duration(minutes: 3));
      expect(r.accept(_peer(2), fragmentFrame(_payload(3000, seed: 9))[0]),
          isNull);
      expect(r.pendingSets, 1, reason: 'the stale set must be gone');
    });

    test('a peer that never finishes cannot grow the table without limit', () {
      final r = FragmentReassembler(maxSets: 4);
      for (var i = 0; i < 20; i++) {
        r.accept(_peer(1), fragmentFrame(_payload(3000, seed: i))[0]);
      }
      expect(r.pendingSets, lessThanOrEqualTo(4));
    });
  });

  group('the bytes it holds are bounded, not just the sets', () {
    // Counting SETS bounded nothing: a set could hold 65535 fragments, so 64
    // of them is about five gigabytes held for the whole TTL. Nothing
    // authenticates a fragment header — four magic bytes — so the cost to the
    // peer is one small frame each.
    test('a flood of unfinished payloads cannot pass the byte budget', () {
      const budget = 20000;
      final r = FragmentReassembler(maxHeldBytes: budget);
      for (var i = 0; i < 200; i++) {
        for (final f in _unfinished(5600, i)) {
          r.accept(_peer(i % 5), f);
        }
        expect(
          r.heldBytes,
          lessThanOrEqualTo(budget),
          reason: 'after ${i + 1} unfinished payloads it holds ${r.heldBytes} B',
        );
      }
      // Unbounded, the same traffic would be holding hundreds of kilobytes.
      expect(r.heldBytes, lessThan(budget));
    });

    test('one payload cannot hold more than a payload is allowed to', () {
      final r = FragmentReassembler(maxPayloadBytes: 4000);
      final assembled = <Uint8List>[];
      for (final f in fragmentFrame(_payload(20000))) {
        final out = r.accept(_peer(1), f);
        if (out != null) assembled.add(out);
      }
      expect(assembled, isEmpty, reason: 'it must never assemble');
      expect(r.heldBytes, lessThanOrEqualTo(4000));
    });

    test('a header claiming more fragments than a payload can have is refused', () {
      // The header field reaches 65535; this side will not hold a set for a
      // total it would never have sent, and refuses at the FIRST fragment —
      // before the set exists, since a high index arriving first is exactly
      // what made a set expensive.
      final r = FragmentReassembler();
      final frame = Uint8List(kFragmentHeaderBytes + kFragmentDataBytes)
        ..setRange(0, 4, kFragmentMagic);
      frame[12] = 0xff;
      frame[13] = 0xff; // total = 65535
      frame[14] = 0xff;
      frame[15] = 0xfe; // index = 65534

      expect(r.accept(_peer(1), frame), isNull);
      expect(r.pendingSets, 0);
      expect(r.heldBytes, 0);
    });

    test('an expired set gives its bytes back to the budget', () {
      var now = DateTime(2026, 8, 7, 12);
      final r = FragmentReassembler(
        ttl: const Duration(minutes: 2),
        now: () => now,
      );
      for (final f in _unfinished(5600, 1)) {
        r.accept(_peer(1), f);
      }
      expect(r.heldBytes, greaterThan(kFragmentDataBytes));

      now = now.add(const Duration(minutes: 3));
      r.accept(_peer(2), fragmentFrame(_payload(3000, seed: 9))[0]);

      expect(
        r.heldBytes,
        lessThanOrEqualTo(kFragmentDataBytes),
        reason: 'only the fragment that just arrived may still be counted',
      );
    });

    test('byte pressure falls on the stalest set, not on the newcomer', () {
      // Which set pays matters. Refusing whoever arrives last would let one
      // peer's abandoned halves hold the budget until the TTL and shut out
      // everyone still sending — so pressure evicts the least recently
      // touched, the same way a full table already does.
      var now = DateTime(2026, 8, 7, 12);
      final r = FragmentReassembler(maxHeldBytes: 6000, now: () => now);
      for (final f in _unfinished(5600, 1)) {
        r.accept(_peer(1), f);
      }
      expect(r.pendingSets, 1);

      now = now.add(const Duration(seconds: 1));
      Uint8List? whole;
      for (final f in fragmentFrame(_payload(5600, seed: 2))) {
        whole = r.accept(_peer(2), f) ?? whole;
      }

      expect(whole, equals(_payload(5600, seed: 2)),
          reason: 'the peer that kept sending must still be served');
      expect(r.pendingSets, 0, reason: 'the abandoned half is what went');
    });

    test('a set with nothing left to evict for it is refused, not kept', () {
      // The backstop under the eviction: when the budget cannot fit even one
      // set, there is nothing to drop but the set itself. Reachable only when
      // a caller sets the two budgets against each other, which is why it is
      // held to a test rather than left to be believed.
      final r = FragmentReassembler(maxHeldBytes: 2000, maxPayloadBytes: 1 << 20);
      final frames = fragmentFrame(_payload(5600));

      expect(r.accept(_peer(1), frames[0]), isNull);
      expect(r.heldBytes, kFragmentDataBytes);
      expect(r.accept(_peer(1), frames[1]), isNull);

      expect(r.heldBytes, 0, reason: 'the set it could not fit must be gone');
      expect(r.pendingSets, 0);
    });

    test('CONTROL: a retry resends every fragment and still assembles', () {
      // The frame id is derived from the payload so a retry carries the same
      // one and the receiver keeps what it holds. If an index arriving twice
      // were counted twice, ordinary retries — not attacks — would eat the
      // budget and the payload would never come together.
      final r = FragmentReassembler(maxHeldBytes: 8000);
      final frames = fragmentFrame(_payload(5600));
      for (final f in frames.sublist(0, frames.length - 1)) {
        expect(r.accept(_peer(1), f), isNull);
      }

      Uint8List? whole;
      for (final f in frames) {
        whole = r.accept(_peer(1), f) ?? whole;
      }

      expect(whole, isNotNull, reason: 'the retry must complete the payload');
      expect(whole, equals(_payload(5600)));
      expect(r.heldBytes, 0, reason: 'a finished payload leaves nothing behind');
    });
  });
}
