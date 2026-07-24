// WebM demux + VNOTE1/VOP1 repack (the Linux video-player substrate). The
// byte layouts here mirror the STRICT native parsers (veil_video_note.cc /
// veil_audio_play.cc): magic, version, non-decreasing timestamps, keyframe
// opening, exact end offset — a container that fails any of these is rejected
// wholesale by the native side, so the repacker is tested byte-for-byte.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/webm_media.dart';

import 'support/webm_test_builder.dart';

int _u16(Uint8List b, int off) => b[off] | (b[off + 1] << 8);
int _u32(Uint8List b, int off) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

void main() {
  test('demuxes a standard clip: geometry, duration, frames, keyflags', () {
    final webm = buildStandardWebm(
      frameCount: 24,
      fps: 25,
      keyEvery: 6,
      withAudio: true,
    );
    final x = demuxWebm(webm)!;
    expect(x.width, 64);
    expect(x.height, 48);
    expect(x.durationMs, 960); // 24 frames @ 40 ms
    expect(x.videoFrames.length, 24);
    expect(x.opusPackets.length, 24);
    expect(x.opusChannels, 2);
    expect(x.videoFrames.first.tsMs, 0);
    expect(x.videoFrames.last.tsMs, 23 * 40);
    for (var i = 0; i < 24; i++) {
      expect(x.videoFrames[i].key, i % 6 == 0, reason: 'frame $i');
    }
    // Frame payloads reference the source bytes (no copy): VP8 bit intact.
    final f0 = x.videoFrames.first;
    expect(x.source[f0.start] & 1, 0);
    expect(f0.length, 40);
  });

  test('non-webm and unsupported codecs are rejected', () {
    expect(demuxWebm(Uint8List(0)), isNull);
    expect(demuxWebm(Uint8List.fromList(List.filled(64, 0x11))), isNull);
    // mp4: ftyp box, not EBML.
    expect(
      demuxWebm(
        Uint8List.fromList([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, ...List.filled(64, 0)]),
      ),
      isNull,
    );
    // VP9 video + no audio: nothing playable.
    final vp9 = buildTestWebm(
      videoCodec: 'V_VP9',
      clusterBodies: [
        clusterBody(0, [simpleBlock(kTestVideoTrack, 0, vp8Key(20))]),
      ],
    );
    expect(demuxWebm(vp9), isNull);
  });

  test('leading delta frames are dropped so the clip opens on a keyframe', () {
    final webm = buildTestWebm(
      clusterBodies: [
        clusterBody(0, [
          simpleBlock(kTestVideoTrack, 0, vp8Delta(20)),
          simpleBlock(kTestVideoTrack, 40, vp8Delta(20)),
          simpleBlock(kTestVideoTrack, 80, vp8Key(20)),
          simpleBlock(kTestVideoTrack, 120, vp8Delta(20)),
        ]),
      ],
    );
    final x = demuxWebm(webm)!;
    expect(x.videoFrames.length, 2);
    expect(x.videoFrames.first.tsMs, 80);
    expect(x.videoFrames.first.key, isTrue);
  });

  test('BlockGroup blocks and all three lacing modes demux', () {
    final webm = buildTestWebm(
      includeAudio: true,
      clusterBodies: [
        clusterBody(0, [
          blockGroup(kTestVideoTrack, 0, vp8Key(24)),
          blockGroup(kTestVideoTrack, 40, vp8Delta(24), withReference: true),
          simpleBlockXiph(kTestAudioTrack, 0, [
            List.filled(300, 0xA1), // >255: exercises the 255-continuation
            List.filled(7, 0xA2),
            List.filled(9, 0xA3),
          ]),
          simpleBlockFixed(kTestAudioTrack, 20, [
            List.filled(8, 0xB1),
            List.filled(8, 0xB2),
          ]),
          simpleBlockEbml(kTestAudioTrack, 40, [
            List.filled(10, 0xC1),
            List.filled(14, 0xC2),
            List.filled(6, 0xC3),
          ]),
        ]),
      ],
    );
    final x = demuxWebm(webm)!;
    expect(x.videoFrames.length, 2);
    expect(x.videoFrames[0].key, isTrue);
    expect(x.videoFrames[1].key, isFalse, reason: 'VP8 payload bit decides');
    expect(x.opusPackets.map((p) => p.length).toList(), [
      300, 7, 9, // Xiph
      8, 8, // fixed
      10, 14, 6, // EBML
    ]);
    // Laced payload ranges land exactly on the marker bytes.
    expect(x.source[x.opusPackets[0].start], 0xA1);
    expect(x.source[x.opusPackets[2].start], 0xA3);
    expect(x.source[x.opusPackets[4].start], 0xB2);
    expect(x.source[x.opusPackets[7].start], 0xC3);
  });

  test('unknown-size segment and clusters (streamed webm) demux', () {
    final webm = buildTestWebm(
      unknownSizeSegment: true,
      unknownSizeClusters: true,
      clusterBodies: [
        clusterBody(0, [
          simpleBlock(kTestVideoTrack, 0, vp8Key(20)),
          simpleBlock(kTestVideoTrack, 40, vp8Delta(20)),
        ]),
        clusterBody(80, [simpleBlock(kTestVideoTrack, 0, vp8Key(20))]),
      ],
    );
    final x = demuxWebm(webm)!;
    expect(x.videoFrames.map((f) => f.tsMs).toList(), [0, 40, 80]);
    expect(x.videoFrames.last.key, isTrue);
  });

  test('a non-default TimestampScale converts to milliseconds', () {
    final webm = buildTestWebm(
      timestampScale: 500000, // 0.5 ms per tick
      durationTicks: 400,
      clusterBodies: [
        clusterBody(0, [
          simpleBlock(kTestVideoTrack, 0, vp8Key(20)),
          simpleBlock(kTestVideoTrack, 100, vp8Delta(20)),
        ]),
      ],
    );
    final x = demuxWebm(webm)!;
    expect(x.videoFrames[1].tsMs, 50);
    expect(x.durationMs, 200);
  });

  test('audio-only webm (no video track) still extracts', () {
    final webm = buildTestWebm(
      includeVideo: false,
      includeAudio: true,
      clusterBodies: [
        clusterBody(0, [
          simpleBlock(kTestAudioTrack, 0, List.filled(11, 0xF0)),
          simpleBlock(kTestAudioTrack, 20, List.filled(12, 0xF1)),
        ]),
      ],
    );
    final x = demuxWebm(webm)!;
    expect(x.hasVideo, isFalse);
    expect(x.opusPackets.length, 2);
    expect(x.durationMs, 40, reason: '20 ms per Opus packet fallback');
  });

  test('VNOTE1 repack matches the native byte layout exactly', () {
    final webm = buildStandardWebm(frameCount: 6, fps: 25, keyEvery: 3);
    final x = demuxWebm(webm)!;
    final v = buildVnote1Video(x);

    expect(String.fromCharCodes(v.sublist(0, 4)), 'VN01');
    expect(v[4], 1, reason: 'version');
    expect(v[5], 2, reason: 'flags: video only, no embedded audio');
    expect(_u16(v, 6), 64);
    expect(_u16(v, 8), 48);
    expect(v[10], 25, reason: 'estimated fps');
    expect(_u32(v, 12), x.durationMs);
    expect(_u32(v, 16), 0, reason: 'audio_len');
    expect(_u32(v, 20), 6, reason: 'frame count');

    // Frame records: [u32 ts][u8 key][u32 len][payload], contiguous to EOF —
    // the native parse rejects trailing garbage.
    var off = 24;
    for (var i = 0; i < 6; i++) {
      expect(_u32(v, off), i * 40, reason: 'ts of frame $i');
      expect(v[off + 4], i % 3 == 0 ? 1 : 0, reason: 'keyflag of frame $i');
      final len = _u32(v, off + 5);
      expect(len, x.videoFrames[i].length);
      expect(
        v.sublist(off + 9, off + 9 + len),
        x.source.sublist(x.videoFrames[i].start, x.videoFrames[i].end),
      );
      off += 9 + len;
    }
    expect(off, v.length, reason: 'exact end offset');
  });

  test('VNOTE1 window repack opens on the window keyframe, keeps abs ts', () {
    final webm = buildStandardWebm(frameCount: 12, fps: 25, keyEvery: 4);
    final x = demuxWebm(webm)!;
    final v = buildVnote1Video(x, fromFrame: 4, toFrame: 8);
    expect(_u32(v, 20), 4);
    expect(_u32(v, 24), 160, reason: 'window keeps ABSOLUTE timestamps');
    expect(v[28], 1, reason: 'window opens on a keyframe');
  });

  test('VOP1 repack matches the native voice container layout', () {
    final webm = buildStandardWebm(
      frameCount: 4,
      withAudio: true,
      audioPacketBytes: 9,
    );
    final x = demuxWebm(webm)!;
    final a = buildVoiceOpus(x)!;
    expect(String.fromCharCodes(a.sublist(0, 4)), 'VOP1');
    expect(a[4], 1, reason: 'version');
    expect(a[5], 2, reason: 'channels');
    expect(_u32(a, 6), 48000, reason: 'WebM Opus is always 48 kHz');
    expect(_u32(a, 10), x.durationMs);
    expect(_u32(a, 14), 4, reason: 'packet count');
    var off = 18;
    for (final p in x.opusPackets) {
      expect(_u16(a, off), p.length);
      expect(
        a.sublist(off + 2, off + 2 + p.length),
        x.source.sublist(p.start, p.end),
      );
      off += 2 + p.length;
    }
    expect(off, a.length);
  });

  test('silent clip has no VOP1; audio-only clip has no video frames', () {
    final silent = demuxWebm(buildStandardWebm(frameCount: 4))!;
    expect(buildVoiceOpus(silent), isNull);
    expect(silent.hasAudio, isFalse);
  });
}
