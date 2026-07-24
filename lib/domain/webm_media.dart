// WebM → native-player repack (media epic: full-size video playback on Linux).
//
// Linux has no video_player implementation and the platform media stacks are
// off-limits by decision (media_kit/libmpv rejected: LGPL + 40-80 MB). What the
// deployed libveil_media.so CAN do — today, with no new native ABI — is play
// VNOTE1 video (VP8, pull-decoded by position with keyframe rewind) and
// VOICE_OPUS audio (Opus → PCM → the WebRTC default ADM, PulseAudio/ALSA). So
// the Linux path for a full-size video attachment is a pure-Dart REMUX, not a
// decoder: demux the WebM container in Dart, hand the VP8 frames to the VNOTE1
// player and the Opus packets to the voice player, and drive frames off the
// audio clock exactly like video notes do.
//
// Scope is honest and fixed by the codec-stripped libwebrtc: WebM/Matroska
// containers with VP8 video and/or Opus audio. H.264/VP9/AV1 attachments stay
// unplayable on Linux (the codecs were deliberately never shipped); the player
// screen says so instead of pretending.
//
// This file is PURE Dart (typed_data only): it is unit-tested byte-for-byte
// and reused by tool/native_video_probe.dart, which must run without Flutter.

import 'dart:typed_data';

/// One encoded video frame, referencing [WebmExtract.source] (no copy).
class WebmFrame {
  WebmFrame({
    required this.tsMs,
    required this.key,
    required this.start,
    required this.end,
  });

  final int tsMs;
  final bool key;

  /// Payload byte range [start, end) into the source buffer.
  final int start;
  final int end;

  int get length => end - start;
}

/// One Opus packet, referencing [WebmExtract.source] (no copy).
class WebmOpusPacket {
  WebmOpusPacket({required this.start, required this.end});

  final int start;
  final int end;

  int get length => end - start;
}

/// The demuxed essence of a WebM file: VP8 frames + Opus packets by reference.
class WebmExtract {
  WebmExtract({
    required this.source,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.videoFrames,
    required this.opusPackets,
    required this.opusChannels,
  });

  final Uint8List source;
  final int width;
  final int height;
  final int durationMs;

  /// VP8 frames in presentation order, first frame always a keyframe (leading
  /// non-key frames are dropped — the native player rejects a container that
  /// does not open on a keyframe).
  final List<WebmFrame> videoFrames;
  final List<WebmOpusPacket> opusPackets;
  final int opusChannels;

  bool get hasVideo => videoFrames.isNotEmpty;
  bool get hasAudio => opusPackets.isNotEmpty;
}

// ── EBML / Matroska ids (raw, marker bits kept — the Matroska convention) ───
const int _idEbml = 0x1A45DFA3;
const int _idSegment = 0x18538067;
const int _idInfo = 0x1549A966;
const int _idTimestampScale = 0x2AD7B1;
const int _idDuration = 0x4489;
const int _idTracks = 0x1654AE6B;
const int _idTrackEntry = 0xAE;
const int _idTrackNumber = 0xD7;
const int _idTrackType = 0x83;
const int _idCodecId = 0x86;
const int _idVideo = 0xE0;
const int _idPixelWidth = 0xB0;
const int _idPixelHeight = 0xBA;
const int _idAudio = 0xE1;
const int _idChannels = 0x9F;
const int _idCluster = 0x1F43B675;
const int _idClusterTimestamp = 0xE7;
const int _idSimpleBlock = 0xA3;
const int _idBlockGroup = 0xA0;
const int _idBlock = 0xA1;

/// Segment-level element ids that terminate an unknown-size Cluster.
const Set<int> _segmentLevelIds = {
  _idCluster,
  _idInfo,
  _idTracks,
  0x114D9B74, // SeekHead
  0x1C53BB6B, // Cues
  0x1254C367, // Tags
  0x1043A770, // Chapters
  0x1941A469, // Attachments
};

class _Reader {
  _Reader(this.bytes, this.pos, this.end);
  final Uint8List bytes;
  int pos;
  final int end;

  bool get done => pos >= end;

  /// Reads an element id (marker kept). Returns -1 on malformed input.
  int readId() {
    if (pos >= end) return -1;
    final first = bytes[pos];
    if (first == 0) return -1;
    var len = 1;
    var mask = 0x80;
    while (mask != 0 && (first & mask) == 0) {
      len++;
      mask >>= 1;
    }
    if (len > 4 || pos + len > end) return -1;
    var id = 0;
    for (var i = 0; i < len; i++) {
      id = (id << 8) | bytes[pos + i];
    }
    pos += len;
    return id;
  }

  /// Peeks the next element id without consuming it (-1 on malformed input).
  int peekId() {
    final save = pos;
    final id = readId();
    pos = save;
    return id;
  }

  /// Reads an element size (marker stripped). Returns -1 on malformed input,
  /// -2 for the reserved "unknown size" (streamed WebM: Segment/Cluster).
  int readSize() {
    if (pos >= end) return -1;
    final first = bytes[pos];
    if (first == 0) return -1;
    var len = 1;
    var mask = 0x80;
    while (mask != 0 && (first & mask) == 0) {
      len++;
      mask >>= 1;
    }
    if (len > 8 || pos + len > end) return -1;
    var value = first & (mask - 1);
    var allOnes = value == mask - 1;
    for (var i = 1; i < len; i++) {
      final b = bytes[pos + i];
      value = (value << 8) | b;
      if (b != 0xFF) allOnes = false;
    }
    pos += len;
    return allOnes ? -2 : value;
  }

  int readUint(int size) {
    var v = 0;
    for (var i = 0; i < size; i++) {
      v = (v << 8) | bytes[pos + i];
    }
    pos += size;
    return v;
  }

  double readFloat(int size) {
    final data = ByteData.sublistView(bytes, pos, pos + size);
    pos += size;
    if (size == 4) return data.getFloat32(0);
    if (size == 8) return data.getFloat64(0);
    return 0;
  }
}

class _Track {
  int number = -1;
  int type = 0;
  String codec = '';
  int width = 0;
  int height = 0;
  int channels = 1;
}

/// Demuxes [bytes] as WebM/Matroska. Returns null when the container is not
/// EBML or carries neither a VP8 video track nor an Opus audio track — the
/// caller shows the honest "unsupported format" state.
WebmExtract? demuxWebm(Uint8List bytes) {
  if (bytes.length < 8) return null;
  final r = _Reader(bytes, 0, bytes.length);
  if (r.readId() != _idEbml) return null;
  final ebmlSize = r.readSize();
  if (ebmlSize < 0) return null;
  r.pos += ebmlSize;

  if (r.readId() != _idSegment) return null;
  final segSize = r.readSize();
  if (segSize == -1) return null;
  final segEnd = segSize == -2
      ? bytes.length
      : (r.pos + segSize <= bytes.length ? r.pos + segSize : bytes.length);

  var timestampScale = 1000000; // ns per tick; default = 1 ms
  var durationTicks = -1.0;
  _Track? video;
  _Track? audio;
  var sawOtherVideoCodec = false;
  final frames = <WebmFrame>[];
  final packets = <WebmOpusPacket>[];
  var lastVideoTsMs = 0;

  final seg = _Reader(bytes, r.pos, segEnd);
  while (!seg.done) {
    final id = seg.readId();
    if (id < 0) break;
    final size = seg.readSize();
    if (size == -1) break;

    if (id == _idInfo && size >= 0) {
      final info = _Reader(bytes, seg.pos, seg.pos + size);
      while (!info.done) {
        final iid = info.readId();
        final isz = info.readSize();
        if (iid < 0 || isz < 0 || info.pos + isz > info.end) break;
        if (iid == _idTimestampScale) {
          timestampScale = info.readUint(isz);
        } else if (iid == _idDuration) {
          durationTicks = info.readFloat(isz);
        } else {
          info.pos += isz;
        }
      }
      seg.pos += size;
    } else if (id == _idTracks && size >= 0) {
      final tracks = _Reader(bytes, seg.pos, seg.pos + size);
      while (!tracks.done) {
        final tid = tracks.readId();
        final tsz = tracks.readSize();
        if (tid < 0 || tsz < 0 || tracks.pos + tsz > tracks.end) break;
        if (tid == _idTrackEntry) {
          final t = _parseTrackEntry(_Reader(bytes, tracks.pos, tracks.pos + tsz));
          if (t.type == 1 && t.codec == 'V_VP8' && video == null) {
            video = t;
          } else if (t.type == 1 && t.codec != 'V_VP8') {
            sawOtherVideoCodec = true;
          }
          if (t.type == 2 && t.codec == 'A_OPUS' && audio == null) audio = t;
        }
        tracks.pos += tsz;
      }
      seg.pos += size;
    } else if (id == _idCluster) {
      final clEnd = size == -2 ? segEnd : seg.pos + size;
      if (clEnd > segEnd) break;
      final consumed = _parseCluster(
        _Reader(bytes, seg.pos, clEnd),
        unknownSize: size == -2,
        timestampScale: timestampScale,
        video: video,
        audio: audio,
        frames: frames,
        packets: packets,
      );
      seg.pos = size == -2 ? consumed : clEnd;
    } else if (size == -2) {
      break; // unknown-size non-cluster master: cannot skip safely
    } else {
      if (seg.pos + size > seg.end) break;
      seg.pos += size;
    }
  }

  // A visible video track this build cannot decode (VP9/AV1/H.264) means the
  // ATTACHMENT is unsupported — degrading a music video to audio-only would
  // just look broken. Only a genuinely video-less file plays audio-only.
  if (video == null && sawOtherVideoCodec) return null;
  if (video == null && audio == null) return null;
  if (frames.isEmpty && packets.isEmpty) return null;

  // The native player rejects a container that does not OPEN on a keyframe:
  // drop leading delta frames (decoding them without their reference would
  // only produce garbage anyway).
  var firstKey = 0;
  while (firstKey < frames.length && !frames[firstKey].key) {
    firstKey++;
  }
  final playable = frames.sublist(firstKey);
  if (playable.isNotEmpty) lastVideoTsMs = playable.last.tsMs;

  var durationMs = 0;
  if (durationTicks > 0) {
    durationMs = (durationTicks * timestampScale / 1000000).round();
  }
  if (durationMs <= 0 && playable.length > 1) {
    final span = playable.last.tsMs - playable.first.tsMs;
    durationMs = lastVideoTsMs + (span ~/ (playable.length - 1));
  }
  if (durationMs <= 0 && packets.isNotEmpty) {
    durationMs = packets.length * 20; // Opus default frame duration
  }
  if (durationMs <= 0) durationMs = lastVideoTsMs;
  if (playable.isEmpty && packets.isEmpty) return null;

  return WebmExtract(
    source: bytes,
    width: video?.width ?? 0,
    height: video?.height ?? 0,
    durationMs: durationMs,
    videoFrames: playable,
    opusPackets: packets,
    opusChannels: audio?.channels ?? 1,
  );
}

_Track _parseTrackEntry(_Reader r) {
  final t = _Track();
  while (!r.done) {
    final id = r.readId();
    final size = r.readSize();
    if (id < 0 || size < 0 || r.pos + size > r.end) break;
    switch (id) {
      case _idTrackNumber:
        t.number = r.readUint(size);
      case _idTrackType:
        t.type = r.readUint(size);
      case _idCodecId:
        t.codec = String.fromCharCodes(r.bytes, r.pos, r.pos + size);
        r.pos += size;
      case _idVideo:
        final v = _Reader(r.bytes, r.pos, r.pos + size);
        while (!v.done) {
          final vid = v.readId();
          final vsz = v.readSize();
          if (vid < 0 || vsz < 0 || v.pos + vsz > v.end) break;
          if (vid == _idPixelWidth) {
            t.width = v.readUint(vsz);
          } else if (vid == _idPixelHeight) {
            t.height = v.readUint(vsz);
          } else {
            v.pos += vsz;
          }
        }
        r.pos += size;
      case _idAudio:
        final a = _Reader(r.bytes, r.pos, r.pos + size);
        while (!a.done) {
          final aid = a.readId();
          final asz = a.readSize();
          if (aid < 0 || asz < 0 || a.pos + asz > a.end) break;
          if (aid == _idChannels) {
            t.channels = a.readUint(asz);
          } else {
            a.pos += asz;
          }
        }
        r.pos += size;
      default:
        r.pos += size;
    }
  }
  return t;
}

/// Parses one Cluster; returns the byte offset it stopped at (only meaningful
/// for unknown-size clusters, which end at the next segment-level element).
int _parseCluster(
  _Reader r, {
  required bool unknownSize,
  required int timestampScale,
  required _Track? video,
  required _Track? audio,
  required List<WebmFrame> frames,
  required List<WebmOpusPacket> packets,
}) {
  var clusterTs = 0;
  while (!r.done) {
    if (unknownSize && _segmentLevelIds.contains(r.peekId())) break;
    final id = r.readId();
    final size = r.readSize();
    if (id < 0 || size < 0 || r.pos + size > r.end) {
      r.pos = r.end;
      break;
    }
    if (id == _idClusterTimestamp) {
      clusterTs = r.readUint(size);
    } else if (id == _idSimpleBlock) {
      _parseBlock(r.bytes, r.pos, r.pos + size,
          clusterTs: clusterTs,
          timestampScale: timestampScale,
          video: video,
          audio: audio,
          frames: frames,
          packets: packets);
      r.pos += size;
    } else if (id == _idBlockGroup) {
      // A BlockGroup wraps the Block with reference metadata; find the Block.
      // (Keyframe-ness comes from the VP8 payload itself, not the container.)
      final g = _Reader(r.bytes, r.pos, r.pos + size);
      while (!g.done) {
        final gid = g.readId();
        final gsz = g.readSize();
        if (gid < 0 || gsz < 0 || g.pos + gsz > g.end) break;
        if (gid == _idBlock) {
          _parseBlock(r.bytes, g.pos, g.pos + gsz,
              clusterTs: clusterTs,
              timestampScale: timestampScale,
              video: video,
              audio: audio,
              frames: frames,
              packets: packets);
        }
        g.pos += gsz;
      }
      r.pos += size;
    } else {
      r.pos += size;
    }
  }
  return r.pos;
}

void _parseBlock(
  Uint8List bytes,
  int start,
  int end, {
  required int clusterTs,
  required int timestampScale,
  required _Track? video,
  required _Track? audio,
  required List<WebmFrame> frames,
  required List<WebmOpusPacket> packets,
}) {
  final r = _Reader(bytes, start, end);
  // Track number is an EBML vint (value, not id — strip the marker).
  final trackNum = r.readSize();
  if (trackNum < 0 || r.pos + 3 > end) return;
  final relTs = (bytes[r.pos] << 8 | bytes[r.pos + 1]).toSigned(16);
  final flags = bytes[r.pos + 2];
  r.pos += 3;

  final isVideo = video != null && trackNum == video.number;
  final isAudio = audio != null && trackNum == audio.number;
  if (!isVideo && !isAudio) return;

  final tsMs =
      (((clusterTs + relTs) * timestampScale) / 1000000).round();

  // Lacing (flags bits 1-2): 0 = none, 1 = Xiph, 2 = fixed, 3 = EBML.
  final laceMode = (flags >> 1) & 0x3;
  final sizes = <int>[];
  if (laceMode == 0) {
    sizes.add(end - r.pos);
  } else {
    if (r.pos >= end) return;
    final count = bytes[r.pos] + 1;
    r.pos += 1;
    if (laceMode == 2) {
      // Fixed-size lacing: equal split of the remainder.
      final each = (end - r.pos) ~/ count;
      for (var i = 0; i < count; i++) {
        sizes.add(each);
      }
    } else if (laceMode == 1) {
      // Xiph: 255-continued byte sums for all but the last frame.
      var total = 0;
      for (var i = 0; i < count - 1; i++) {
        var sz = 0;
        while (r.pos < end) {
          final b = bytes[r.pos];
          r.pos++;
          sz += b;
          if (b != 255) break;
        }
        sizes.add(sz);
        total += sz;
      }
      sizes.add(end - r.pos - total);
    } else {
      // EBML lacing: first size is a vint, the rest signed-vint deltas.
      final firstRead = _Reader(bytes, r.pos, end);
      var prev = firstRead.readSize();
      if (prev < 0) return;
      sizes.add(prev);
      for (var i = 1; i < count - 1; i++) {
        final save = firstRead.pos;
        final raw = firstRead.readSize();
        if (raw < 0) return;
        final vintLen = firstRead.pos - save;
        // Signed vint: unsigned value minus (2^(7*len-1) - 1).
        final delta = raw - ((1 << (7 * vintLen - 1)) - 1);
        prev += delta;
        if (prev < 0) return;
        sizes.add(prev);
      }
      r.pos = firstRead.pos;
      var total = 0;
      for (final s in sizes) {
        total += s;
      }
      sizes.add(end - r.pos - total);
    }
  }

  for (final sz in sizes) {
    if (sz <= 0 || r.pos + sz > end) return;
    if (isVideo) {
      // The VP8 bitstream is authoritative for keyframe-ness (bit 0 of the
      // first payload byte is 0 on a keyframe) — a wrongly flagged delta
      // frame would poison the native decode chain.
      final key = (bytes[r.pos] & 0x01) == 0;
      frames.add(WebmFrame(
        tsMs: tsMs,
        key: key,
        start: r.pos,
        end: r.pos + sz,
      ));
    } else {
      packets.add(WebmOpusPacket(start: r.pos, end: r.pos + sz));
    }
    r.pos += sz;
  }
}

// ── Repack: WebM essence → the containers the deployed native ABI plays ────

/// Builds a video-only VNOTE1 container over [x]'s frames [fromFrame, toFrame)
/// with their ORIGINAL timestamps — the windowed source the native VNOTE1
/// player streams from. [fromFrame] must index a keyframe (the native parse
/// rejects a container that does not open on one); callers pick windows via
/// [WebmExtract.videoFrames]' key flags.
Uint8List buildVnote1Video(
  WebmExtract x, {
  int fromFrame = 0,
  int? toFrame,
}) {
  final frames = x.videoFrames;
  final endIdx = toFrame ?? frames.length;
  assert(fromFrame < endIdx && endIdx <= frames.length);
  assert(frames[fromFrame].key, 'VNOTE1 windows must open on a keyframe');

  var payload = 0;
  for (var i = fromFrame; i < endIdx; i++) {
    payload += 9 + frames[i].length;
  }
  final out = Uint8List(24 + payload);
  final d = ByteData.sublistView(out);
  out[0] = 0x56; // V
  out[1] = 0x4E; // N
  out[2] = 0x30; // 0
  out[3] = 0x31; // 1
  out[4] = 1; // version
  out[5] = 2; // flags: video only — audio rides the voice player separately
  d.setUint16(6, x.width.clamp(0, 0xFFFF), Endian.little);
  d.setUint16(8, x.height.clamp(0, 0xFFFF), Endian.little);
  out[10] = _estimateFps(frames).clamp(1, 255);
  out[11] = 0;
  d.setUint32(12, x.durationMs.clamp(0, 0xFFFFFFFF), Endian.little);
  d.setUint32(16, 0, Endian.little); // no embedded audio
  d.setUint32(20, endIdx - fromFrame, Endian.little);

  var off = 24;
  var lastTs = 0;
  for (var i = fromFrame; i < endIdx; i++) {
    final f = frames[i];
    // The native parse requires non-decreasing timestamps; clamp rounding
    // artifacts instead of rejecting the whole file.
    final ts = f.tsMs < lastTs ? lastTs : f.tsMs;
    lastTs = ts;
    d.setUint32(off, ts, Endian.little);
    out[off + 4] = f.key ? 1 : 0;
    d.setUint32(off + 5, f.length, Endian.little);
    out.setRange(off + 9, off + 9 + f.length, x.source, f.start);
    off += 9 + f.length;
  }
  return out;
}

int _estimateFps(List<WebmFrame> frames) {
  if (frames.length < 2) return 24;
  final span = frames.last.tsMs - frames.first.tsMs;
  if (span <= 0) return 24;
  return ((frames.length - 1) * 1000 / span).round();
}

/// Builds a VOICE_OPUS (VOP1) block over [x]'s Opus packets, playable by the
/// existing voice player (native decode → ADM speaker on Linux). Null when the
/// file has no Opus audio or a packet exceeds the container's u16 length field
/// (real Opus packets top out ~8 KB; oversize means a corrupt file).
Uint8List? buildVoiceOpus(WebmExtract x) {
  if (!x.hasAudio) return null;
  var payload = 0;
  for (final p in x.opusPackets) {
    if (p.length > 0xFFFF) return null;
    payload += 2 + p.length;
  }
  final out = Uint8List(18 + payload);
  final d = ByteData.sublistView(out);
  out[0] = 0x56; // V
  out[1] = 0x4F; // O
  out[2] = 0x50; // P
  out[3] = 0x31; // 1
  out[4] = 1; // version
  out[5] = x.opusChannels.clamp(1, 255);
  d.setUint32(6, 48000, Endian.little); // WebM Opus is always 48 kHz
  d.setUint32(10, x.durationMs.clamp(0, 0xFFFFFFFF), Endian.little);
  d.setUint32(14, x.opusPackets.length, Endian.little);
  var off = 18;
  for (final p in x.opusPackets) {
    d.setUint16(off, p.length, Endian.little);
    out.setRange(off + 2, off + 2 + p.length, x.source, p.start);
    off += 2 + p.length;
  }
  return out;
}
