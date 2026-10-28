import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/large_frame.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';

void main() {
  final peer = NodeId(Uint8List(32)..fillRange(0, 32, 1));
  final other = NodeId(Uint8List(32)..fillRange(0, 32, 2));
  final payload = WireEnvelope.message(
    List.filled(20000, 'a').join(),
    id: 'fixture',
    seq: 1,
  ).encode();
  InboundMessage incoming(
    Uint8List wire, {
    NodeId? source,
    NodeId? device,
    SenderProvenance proof = SenderProvenance.sessionPeer,
    int reply = 0,
  }) => InboundMessage(
    src: source ?? peer,
    payload: wire,
    srcDevice: device,
    provenance: proof,
    replyId: reply,
  );

  test(
    'shuffled duplicate fragments join exact bytes and keep the lease charged',
    () {
      final buffer = LargeFrameBuffer();
      final frames = splitLargeFrame(payload);
      expect(frames.every((f) => f.length <= kLargeFrameWireBytes), isTrue);
      LargeFrameLease? lease;
      for (final frame in frames.reversed) {
        lease =
            buffer.add(incoming(frame, reply: 42), wasBlocked: false) ?? lease;
        if (lease == null) {
          expect(buffer.add(incoming(frame), wasBlocked: false), isNull);
        }
      }
      expect(lease, isNotNull);
      expect(lease!.message.payload, payload);
      expect(lease.message.replyId, 42);
      expect(buffer.heldBytes, payload.length);
      expect(buffer.pendingSets, 1);
      expect(buffer.add(incoming(frames.first), wasBlocked: false), isNull);
      lease.release();
      lease.release();
      expect(buffer.heldBytes, 0);
      expect(buffer.pendingSets, 0);
    },
  );
  test(
    'older envelope decoders drop every fragment instead of rendering text',
    () {
      for (final frame in splitLargeFrame(payload)) {
        expect(WireEnvelope.decode(frame).kind, WireKind.unknown);
      }
    },
  );
  for (final change in ['digest', 'kind', 'length', 'index', 'short']) {
    test('$change corruption cannot yield a logical message', () {
      final buffer = LargeFrameBuffer();
      final envelopes = splitLargeFrame(payload)
          .map((wire) => jsonDecode(utf8.decode(wire)) as Map<String, dynamic>)
          .toList();
      final frames = envelopes
          .map((envelope) => base64.decode(envelope['b'] as String))
          .toList();
      if (change == 'digest') {
        for (final f in frames) {
          f[4] ^= 1;
        }
      } else if (change == 'kind') {
        for (final f in frames) {
          ByteData.sublistView(f).setUint16(40, WireKind.edit.index);
        }
      } else if (change == 'length') {
        ByteData.sublistView(
          frames.first,
        ).setUint32(36, kLargeFrameMaxBytes + 1);
      } else if (change == 'index') {
        ByteData.sublistView(frames.first).setUint16(42, 65535);
      } else {
        frames[0] = Uint8List.sublistView(
          frames.first,
          0,
          frames.first.length - 1,
        );
      }
      for (var i = 0; i < frames.length; i++) {
        final wire = Uint8List.fromList(
          utf8.encode(
            jsonEncode({...envelopes[i], 'b': base64.encode(frames[i])}),
          ),
        );
        try {
          expect(buffer.add(incoming(wire), wasBlocked: false), isNull);
        } on FormatException {
          // Malformed headers are refused before allocating a partial set.
        }
      }
      expect(buffer.heldBytes, lessThanOrEqualTo(payload.length));
      if (change == 'digest' || change == 'kind') expect(buffer.pendingSets, 0);
    });
  }
  test(
    'attribution, physical device and identity never mix between fragments',
    () {
      final frames = splitLargeFrame(payload);
      final buffer = LargeFrameBuffer();
      expect(
        buffer.add(
          incoming(frames.first, proof: SenderProvenance.claimed),
          wasBlocked: false,
        ),
        isNull,
      );
      expect(buffer.pendingSets, 0);
      buffer.add(incoming(frames.first, device: other), wasBlocked: false);
      for (final f in frames.skip(1)) {
        expect(buffer.add(incoming(f), wasBlocked: false), isNull);
      }
      expect(buffer.pendingSets, 2);
      final lease = buffer.add(incoming(frames.first), wasBlocked: true);
      expect(lease!.wasBlocked, isTrue);
      lease.release();
      expect(buffer.pendingSets, 1);
      buffer.clear();
      expect(buffer.heldBytes, 0);
    },
  );
  test(
    'byte and set quotas constrain one peer independently of other peers',
    () {
      final frames = splitLargeFrame(payload);
      final buffer = LargeFrameBuffer(
        maxSets: 3,
        maxSetsPerPeer: 1,
        maxPeerBytes: kLargeFramePartBytes,
        maxHeldBytes: 3 * kLargeFramePartBytes,
      );
      buffer.add(incoming(frames.first), wasBlocked: false);
      final different = splitLargeFrame(
        WireEnvelope.message(
          "other${List.filled(10000, 'b').join()}",
          id: 'other',
        ).encode(),
      );
      buffer.add(incoming(different.first), wasBlocked: false);
      expect(buffer.pendingSets, 1);
      buffer.add(incoming(frames.first, source: other), wasBlocked: false);
      expect(buffer.pendingSets, 2);
      expect(buffer.heldBytes, 2 * kLargeFramePartBytes);
      buffer.add(incoming(frames[1]), wasBlocked: false);
      expect(buffer.pendingSets, 1);
      expect(buffer.heldBytes, kLargeFramePartBytes);
    },
  );
  test(
    'incomplete expiry releases bytes while an active durable lease cannot expire',
    () {
      var now = DateTime.utc(2026);
      final buffer = LargeFrameBuffer(
        now: () => now,
        ttl: const Duration(seconds: 1),
      );
      final frames = splitLargeFrame(payload);
      buffer.add(incoming(frames.first), wasBlocked: false);
      now = now.add(const Duration(seconds: 2));
      buffer.add(incoming(frames.last), wasBlocked: false);
      expect(buffer.heldBytes, parseLargeFrame(frames.last).data.length);
      LargeFrameLease? lease;
      for (final f in frames.take(frames.length - 1)) {
        lease = buffer.add(incoming(f), wasBlocked: false) ?? lease;
      }
      expect(lease, isNotNull);
      now = now.add(const Duration(hours: 2));
      buffer.add(incoming(frames.first, source: other), wasBlocked: false);
      expect(buffer.pendingSets, 2);
      lease!.release();
      buffer.clear();
      lease.release();
      expect(buffer.heldBytes, 0);
    },
  );
  test(
    'live control and device-history frames cannot be tunneled through content framing',
    () {
      for (final kind in [
        WireKind.callSignal,
        WireKind.groupCallSignal,
        WireKind.deviceHistory,
        WireKind.ack,
        WireKind.groupEntry,
      ]) {
        expect(
          () => splitLargeFrame(WireEnvelope(kind, 'data').encode()),
          throwsArgumentError,
        );
      }
      expect(
        isLargeFrame(
          Uint8List.fromList(utf8.encode('XVF2 ordinary legacy text')),
        ),
        isFalse,
      );
    },
  );
  test('large text framing cannot require an oversized reflected receipt', () {
    final raw = WireEnvelope.message(
      'text',
      id: List.filled(2048, 'x').join(),
    ).encode();
    expect(largeFrameKind(raw), isNull);
    expect(() => splitLargeFrame(raw), throwsArgumentError);
  });
  test('receipt admission counts JSON escaping of reflected IDs', () {
    final raw = WireEnvelope.message(
      'text',
      id: List.filled(1024, '\u0000').join(),
    ).encode();
    expect(largeFrameKind(raw), isNull);
    expect(() => splitLargeFrame(raw), throwsArgumentError);
  });
}
