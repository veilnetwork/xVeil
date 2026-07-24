// Synthetic WebM writer for the Linux video-player tests: hand-rolled EBML so
// the demuxer is exercised against known bytes (tracks, clusters, SimpleBlock
// and BlockGroup, all three lacing modes, unknown-size clusters) without any
// media tooling. Payloads are fake VP8/Opus — only the first payload byte
// matters to the demuxer (VP8 keyframe bit); the native decode is covered by
// tool/native_video_probe.dart on a real file.

import 'dart:typed_data';

List<int> ebmlId(int id) {
  final out = <int>[];
  var v = id;
  while (v > 0) {
    out.insert(0, v & 0xFF);
    v >>= 8;
  }
  return out.isEmpty ? [0] : out;
}

/// Minimal-length EBML size vint (marker bit included).
List<int> ebmlSize(int value) {
  for (var len = 1; len <= 8; len++) {
    final max = (1 << (7 * len)) - 2; // all-ones is reserved (unknown)
    if (value <= max) {
      final out = List<int>.filled(len, 0);
      var v = value;
      for (var i = len - 1; i >= 0; i--) {
        out[i] = v & 0xFF;
        v >>= 8;
      }
      out[0] |= 0x100 >> len;
      return out;
    }
  }
  throw ArgumentError('size too large');
}

/// The reserved unknown-size marker of [len] bytes.
List<int> ebmlUnknownSize(int len) {
  final out = List<int>.filled(len, 0xFF);
  out[0] = (0x100 >> len) | ((0x100 >> len) - 1);
  return out;
}

List<int> element(int id, List<int> body) => [
  ...ebmlId(id),
  ...ebmlSize(body.length),
  ...body,
];

List<int> uintBody(int v) {
  final out = <int>[];
  var x = v;
  do {
    out.insert(0, x & 0xFF);
    x >>= 8;
  } while (x > 0);
  return out;
}

List<int> uintElement(int id, int v) => element(id, uintBody(v));

List<int> floatElement(int id, double v) {
  final b = ByteData(8)..setFloat64(0, v);
  return element(id, b.buffer.asUint8List());
}

List<int> stringElement(int id, String s) => element(id, s.codeUnits);

/// A fake VP8 keyframe payload ([n] bytes, first byte even = keyframe bit 0).
List<int> vp8Key(int n, {int fill = 0x42}) => [
  0x10,
  for (var i = 1; i < n; i++) fill,
];

/// A fake VP8 delta payload (first byte odd).
List<int> vp8Delta(int n, {int fill = 0x24}) => [
  0x11,
  for (var i = 1; i < n; i++) fill,
];

List<int> _blockHead(int track, int relTs, int flags) => [
  0x80 | track, // 1-byte track vint
  (relTs >> 8) & 0xFF,
  relTs & 0xFF,
  flags,
];

List<int> simpleBlock(int track, int relTs, List<int> payload) =>
    element(0xA3, [..._blockHead(track, relTs, 0), ...payload]);

/// SimpleBlock with Xiph lacing.
List<int> simpleBlockXiph(int track, int relTs, List<List<int>> frames) {
  final body = [..._blockHead(track, relTs, 0x02), frames.length - 1];
  for (var i = 0; i < frames.length - 1; i++) {
    var sz = frames[i].length;
    while (sz >= 255) {
      body.add(255);
      sz -= 255;
    }
    body.add(sz);
  }
  for (final f in frames) {
    body.addAll(f);
  }
  return element(0xA3, body);
}

/// SimpleBlock with fixed-size lacing (all frames equal length).
List<int> simpleBlockFixed(int track, int relTs, List<List<int>> frames) =>
    element(0xA3, [
      ..._blockHead(track, relTs, 0x04),
      frames.length - 1,
      for (final f in frames) ...f,
    ]);

/// SimpleBlock with EBML lacing.
List<int> simpleBlockEbml(int track, int relTs, List<List<int>> frames) {
  final body = [..._blockHead(track, relTs, 0x06), frames.length - 1];
  body.addAll(ebmlSize(frames[0].length));
  var prev = frames[0].length;
  for (var i = 1; i < frames.length - 1; i++) {
    final delta = frames[i].length - prev;
    // Signed vint over 2 bytes: raw = delta + (2^13 - 1).
    final raw = delta + 8191;
    body.addAll([0x40 | ((raw >> 8) & 0x3F), raw & 0xFF]);
    prev = frames[i].length;
  }
  for (final f in frames) {
    body.addAll(f);
  }
  return element(0xA3, body);
}

/// Block inside a BlockGroup ([withReference] marks it a non-keyframe — the
/// demuxer must still trust the VP8 payload bit, not the container).
List<int> blockGroup(
  int track,
  int relTs,
  List<int> payload, {
  bool withReference = false,
}) => element(0xA0, [
  ...element(0xA1, [..._blockHead(track, relTs, 0), ...payload]),
  if (withReference) ...uintElement(0xFB, 1),
]);

List<int> clusterBody(int tsMs, List<List<int>> blocks) => [
  ...uintElement(0xE7, tsMs),
  for (final b in blocks) ...b,
];

const int kTestVideoTrack = 1;
const int kTestAudioTrack = 2;

/// Assembles a whole WebM file around prepared cluster BODIES.
Uint8List buildTestWebm({
  required List<List<int>> clusterBodies,
  bool includeVideo = true,
  String videoCodec = 'V_VP8',
  int width = 64,
  int height = 48,
  bool includeAudio = false,
  String audioCodec = 'A_OPUS',
  int channels = 2,
  int timestampScale = 1000000,
  double? durationTicks,
  bool unknownSizeClusters = false,
  bool unknownSizeSegment = false,
}) {
  final info = element(0x1549A966, [
    ...uintElement(0x2AD7B1, timestampScale),
    if (durationTicks != null) ...floatElement(0x4489, durationTicks),
  ]);
  final tracks = element(0x1654AE6B, [
    if (includeVideo)
      ...element(0xAE, [
        ...uintElement(0xD7, kTestVideoTrack),
        ...uintElement(0x83, 1),
        ...stringElement(0x86, videoCodec),
        ...element(0xE0, [
          ...uintElement(0xB0, width),
          ...uintElement(0xBA, height),
        ]),
      ]),
    if (includeAudio)
      ...element(0xAE, [
        ...uintElement(0xD7, kTestAudioTrack),
        ...uintElement(0x83, 2),
        ...stringElement(0x86, audioCodec),
        ...element(0xE1, [...uintElement(0x9F, channels)]),
      ]),
  ]);
  final clusters = <int>[];
  for (final body in clusterBodies) {
    clusters.addAll(ebmlId(0x1F43B675));
    clusters.addAll(
      unknownSizeClusters ? ebmlUnknownSize(1) : ebmlSize(body.length),
    );
    clusters.addAll(body);
  }
  final segBody = [...info, ...tracks, ...clusters];
  final ebmlHeader = element(0x1A45DFA3, [
    ...uintElement(0x4286, 1), // EBMLVersion
    ...stringElement(0x4282, 'webm'), // DocType
  ]);
  return Uint8List.fromList([
    ...ebmlHeader,
    ...ebmlId(0x18538067),
    ...(unknownSizeSegment ? ebmlUnknownSize(8) : ebmlSize(segBody.length)),
    ...segBody,
  ]);
}

/// A regular clip: [frameCount] video frames at [fps], keyframe every
/// [keyEvery], [frameBytes] each; optional Opus packets (one per video frame).
Uint8List buildStandardWebm({
  int frameCount = 24,
  int fps = 25,
  int keyEvery = 6,
  int frameBytes = 40,
  bool withAudio = false,
  int audioPacketBytes = 12,
  double? durationTicks,
}) {
  final gapMs = 1000 ~/ fps;
  // One cluster per keyframe GOP — mirrors real muxers.
  final clusterBlocks = <List<List<int>>>[];
  final clusterStarts = <int>[];
  for (var i = 0; i < frameCount; i++) {
    final ts = i * gapMs;
    final key = i % keyEvery == 0;
    if (key || clusterBlocks.isEmpty) {
      clusterBlocks.add([]);
      clusterStarts.add(ts);
    }
    final rel = ts - clusterStarts.last;
    clusterBlocks.last.add(
      simpleBlock(
        kTestVideoTrack,
        rel,
        key
            ? vp8Key(frameBytes, fill: i & 0xFF)
            : vp8Delta(frameBytes, fill: i & 0xFF),
      ),
    );
    if (withAudio) {
      clusterBlocks.last.add(
        simpleBlock(kTestAudioTrack, rel, [
          0xF8,
          for (var b = 1; b < audioPacketBytes; b++) i & 0xFF,
        ]),
      );
    }
  }
  return buildTestWebm(
    clusterBodies: [
      for (var c = 0; c < clusterBlocks.length; c++)
        clusterBody(clusterStarts[c], clusterBlocks[c]),
    ],
    includeAudio: withAudio,
    durationTicks: durationTicks ?? (frameCount * gapMs).toDouble(),
  );
}
