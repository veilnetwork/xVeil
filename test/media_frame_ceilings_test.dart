import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_media/veil_media.dart'
    show kVeilMaxVideoSide, kVeilMaxVnoteSide;

/// A decoded frame's dimensions are not the container's.
///
/// Both media containers declare their sizes in the header, and both parsers
/// bound what they read. What nothing bounded was the number that comes back
/// from the DECODER: libvpx reports the size in the VP8 keyframe, and on a
/// receive path that keyframe belongs to whoever sent it. It need not agree
/// with the header, so "the parser checked it" was never true of it.
///
/// Every place that sizes an allocation from those numbers is here: the native
/// sinks that resize an RGBA buffer, and the four Dart retry paths that grow a
/// `calloc` to "the reported dimensions". libvpx's own ceiling is 16383, which
/// is 1.07 GB per buffer — and these builds are `-fno-exceptions`, where a
/// refused allocation is an abort, not an exception somebody catches.
void main() {
  const root = 'third_party/veil/flutter/veil_media';

  String read(String rel) => File('$root/$rel').readAsStringSync();

  group('the ceilings are one fact, not two', () {
    test('the Dart call ceiling matches kMaxVideoSide in the engine', () {
      final src = read('src/veil_media_engine.cc');
      final m = RegExp(r'constexpr int kMaxVideoSide = (\d+);').firstMatch(src);
      expect(
        m,
        isNotNull,
        reason: 'kMaxVideoSide is gone from the engine — this pair has drifted',
      );
      expect(
        int.parse(m!.group(1)!),
        kVeilMaxVideoSide,
        reason:
            'the native sink and the Dart retry would grow to different sizes; '
            'whichever is larger is the one an attacker gets',
      );
    });

    test('the Dart note ceiling matches kMaxVnoteSide in the recorder', () {
      final src = read('src/veil_video_note.cc');
      final m =
          RegExp(r'constexpr uint16_t kMaxVnoteSide = (\d+);').firstMatch(src);
      expect(m, isNotNull, reason: 'kMaxVnoteSide is gone from the note code');
      expect(int.parse(m!.group(1)!), kVeilMaxVnoteSide);
    });
  });

  group('every place that sizes a buffer from a decoder checks it first', () {
    /// The body of [fn] in [src], with comment lines removed.
    ///
    /// Per FUNCTION, never per file. Both of the notes beside these checks
    /// name the constant, and the vnote parser's header check spells the
    /// comparison identically — so a search over a whole file passes with the
    /// code deleted and the explanation left standing. Two earlier versions of
    /// this test did exactly that.
    String body(String src, String signature) {
      final at = src.indexOf(signature);
      expect(at, isNot(-1), reason: 'not found, so unguarded: $signature');
      final close = src.indexOf('\n  }\n', at);
      expect(close, greaterThan(at), reason: 'could not delimit $signature');
      return src
          .substring(at, close)
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
    }

    test('the call engine bounds both of its stores', () {
      final engine = read('src/veil_media_engine.cc');
      expect(
        body(engine, 'void OnFrame(const webrtc::VideoFrame& frame) override'),
        contains('kMaxVideoSide'),
        reason:
            'OnFrame is the REMOTE path: the size it stores from comes out of '
            "the peer's VP8 keyframe",
      );
      expect(
        body(engine, 'void store_i420(const uint8_t* y'),
        contains('kMaxVideoSide'),
        reason: 'the local capture store sizes a buffer from its argument too',
      );
    });

    test('the frame size gate reads the BYTES, not the index flag', () {
      // `f.key` is the VNOTE1 index's claim and libvpx does not consult it: it
      // reads the frame tag out of the payload and sizes four reference
      // buffers from that frame's own 14-bit dimensions. Gating the check on
      // the index let a real keyframe carrying 16383 square through by
      // labelling itself a delta frame (report27 V09).
      final note = read('src/veil_video_note.cc');
      final decode = body(note, 'void vnote_decode_one(VeilVnotePlayer* p');
      expect(
        decode,
        contains('veil_vp8_keyframe_size'),
        reason: 'the payload is never parsed, so the index decides',
      );
      final parse = decode.indexOf('veil_vp8_keyframe_size');
      final gate = decode.indexOf('if (f.key)');
      expect(
        gate == -1 || gate > parse,
        isTrue,
        reason: 'the parse is still behind the index flag',
      );
      expect(
        decode,
        contains('declared.ok &&'),
        reason: 'the bound is not applied to what the bytes declare',
      );
    });

    test('the note sink bounds the decoded frame', () {
      final note = read('src/veil_video_note.cc');
      expect(
        body(note, 'int32_t Decoded(webrtc::VideoFrame& frame)'),
        contains('kMaxVnoteSide'),
        reason:
            "VnoteDecodeSink::Decoded resizes from the decoder's answer, and "
            'the header check above it says nothing about that number',
      );
    });

    test('all four Dart retry paths bound before they grow', () {
      final dart = read('lib/veil_media.dart');
      // Every "grow to what native reported and try again" site.
      final retries = RegExp(r'if \(seq == -1\) \{').allMatches(dart).length;
      expect(
        retries,
        4,
        reason:
            'the number of retry paths changed — a new one may be growing '
            'unbounded, or one this test was written for is gone',
      );
      // ...and each of them gates on a ceiling rather than multiplying.
      final gated = RegExp(r'<= kVeilMax(Video|Vnote)Side').allMatches(dart);
      expect(
        gated.length,
        greaterThanOrEqualTo(8),
        reason:
            'a retry path multiplies the reported dimensions without checking '
            'them; two comparisons per path is the shape that is safe',
      );
      expect(
        dart,
        isNot(contains('final need = wp.value * hp.value * 4;')),
        reason: 'an unbounded grow is back',
      );
      expect(
        dart,
        isNot(contains('final need = width.value * height.value * 4;')),
        reason: 'an unbounded grow is back in the group path',
      );
    });
  });

  group('a queued task cannot outlive what it points at', () {
    String read(String rel) =>
        File('third_party/veil/flutter/veil_media/$rel').readAsStringSync();

    test('the inbound task holds a guard, and the destructor clears it', () {
      // `OnVeilDatagram` copies a packet and posts it to the network queue
      // with a raw `this`; `Stop` waits a second for the pending count and
      // returns anyway, so a delayed task could run against a shim its owner
      // had already freed (report27 V23). Waiting longer is not the fix.
      final shim = read('src/veil_transport_shim.cc');
      final header = read('src/veil_transport_shim.h');

      expect(
        header,
        contains('struct TaskGuard'),
        reason: 'the shim carries nothing a queued task can safely check',
      );
      final post = shim.indexOf('network_queue_->PostTask(');
      expect(post, isNot(-1), reason: 'the post moved');
      final lambda = shim.substring(post, post + 700);
      expect(
        lambda,
        contains('guard = self->task_guard_'),
        reason: 'the task captures only a raw pointer to the shim',
      );
      expect(
        lambda,
        contains('if (!guard->alive) return;'),
        reason: 'the task runs without asking whether the shim is still there',
      );

      final dtor = shim.indexOf('VeilTransportShim::~VeilTransportShim');
      final cleared = shim.indexOf('task_guard_->alive = false');
      expect(dtor, isNot(-1), reason: 'the destructor moved');
      expect(
        cleared,
        greaterThan(dtor),
        reason: 'nothing tells the queued task that the shim has gone',
      );
      expect(
        shim.substring(dtor, cleared),
        contains('std::lock_guard<std::mutex> lock(task_guard_->mu)'),
        reason:
            'the flag is cleared without the lock, so a task mid-delivery is '
            'not waited for',
      );
    });
  });
}
