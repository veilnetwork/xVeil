// Headless probe of the Linux full-size video tract (media epic verify).
//
// Exercises the EXACT production pipeline of NativeVideoPlayer — pure-Dart
// WebM demux → VNOTE1/VOP1 repack → the deployed libveil_media.so — without
// Flutter or a display, so it runs on the x86_64 build VM over ssh:
//
//   dart run tool/native_video_probe.dart <video.webm> <libveil_media.so>
//
// Prints demux stats, native vnote-player duration/geometry, walks frameAt
// across the whole clip counting decoded frames (proves the windowed VP8
// decode), rebuilds a mid-file window (proves the seek path), and creates the
// VOICE_OPUS audio player (duration from real decoded PCM). player_start is
// attempted LAST and may honestly fail on a machine with no audio device
// (PulseAudio/ALSA absent) — that is reported, not treated as an error.
//
// The .so resolves veilclient datagram symbols from libveilclient_ffi.so via
// DT_NEEDED + $ORIGIN, so point it at the app bundle's lib/ copy (or set
// LD_LIBRARY_PATH to a directory holding both).
//
// This tool duplicates the tiny FFI surface on purpose: package:veil_media
// imports Flutter (debugPrint in its loader), which a `dart run` CLI cannot.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ignore: avoid_relative_lib_imports -- standalone CLI, not part of the app
import '../lib/domain/webm_media.dart';

typedef _CreateN = Pointer<Void> Function(Pointer<Uint8>, Size);
typedef _CreateD = Pointer<Void> Function(Pointer<Uint8>, int);
typedef _IntOfPtrN = Int32 Function(Pointer<Void>);
typedef _IntOfPtrD = int Function(Pointer<Void>);
typedef _VoidOfPtrN = Void Function(Pointer<Void>);
typedef _VoidOfPtrD = void Function(Pointer<Void>);
typedef _FrameAtN = Int32 Function(
    Pointer<Void>, Int32, Pointer<Uint8>, Int32, Pointer<Int32>, Pointer<Int32>);
typedef _FrameAtD = int Function(
    Pointer<Void>, int, Pointer<Uint8>, int, Pointer<Int32>, Pointer<Int32>);

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
        'usage: dart run tool/native_video_probe.dart <video.webm> <libveil_media.so>');
    exit(2);
  }
  final bytes = File(args[0]).readAsBytesSync();
  final lib = DynamicLibrary.open(args[1]);

  final vnCreate =
      lib.lookupFunction<_CreateN, _CreateD>('veil_media_vnote_player_create');
  final vnDuration = lib.lookupFunction<_IntOfPtrN, _IntOfPtrD>(
      'veil_media_vnote_player_duration_ms');
  final vnWidth = lib
      .lookupFunction<_IntOfPtrN, _IntOfPtrD>('veil_media_vnote_player_width');
  final vnHeight = lib
      .lookupFunction<_IntOfPtrN, _IntOfPtrD>('veil_media_vnote_player_height');
  final vnFrameAt = lib
      .lookupFunction<_FrameAtN, _FrameAtD>('veil_media_vnote_player_frame_at');
  final vnDestroy = lib.lookupFunction<_VoidOfPtrN, _VoidOfPtrD>(
      'veil_media_vnote_player_destroy');
  final apCreate =
      lib.lookupFunction<_CreateN, _CreateD>('veil_media_player_create');
  final apDuration = lib
      .lookupFunction<_IntOfPtrN, _IntOfPtrD>('veil_media_player_duration_ms');
  final apStart =
      lib.lookupFunction<_IntOfPtrN, _IntOfPtrD>('veil_media_player_start');
  final apDestroy = lib
      .lookupFunction<_VoidOfPtrN, _VoidOfPtrD>('veil_media_player_destroy');

  stdout.writeln('probe: ${args[0]} (${bytes.length} bytes)');

  final x = demuxWebm(bytes);
  if (x == null) {
    stdout.writeln('demux: FAILED (not WebM / no VP8 or Opus track)');
    exit(1);
  }
  final keys = x.videoFrames.where((f) => f.key).length;
  stdout.writeln('demux: ${x.width}x${x.height} dur=${x.durationMs}ms '
      'videoFrames=${x.videoFrames.length} (keyframes=$keys) '
      'opusPackets=${x.opusPackets.length} ch=${x.opusChannels}');

  Pointer<Void> createPlayer(Uint8List container) {
    final buf = calloc<Uint8>(container.length);
    buf.asTypedList(container.length).setAll(0, container);
    final p = vnCreate(buf, container.length);
    calloc.free(buf);
    return p;
  }

  // Walk frameAt over one container (a window or the whole clip), counting
  // DISTINCT decoded frames via the returned seq.
  (int frames, int lastSeq) walk(Pointer<Void> p, int fromMs, int toMs,
      int stepMs, Pointer<Uint8> dst, int cap, Pointer<Int32> w, Pointer<Int32> h) {
    var decoded = 0;
    var lastSeq = 0;
    for (var ms = fromMs; ms <= toMs; ms += stepMs) {
      final seq = vnFrameAt(p, ms, dst, cap, w, h);
      if (seq > lastSeq) {
        decoded += seq - lastSeq;
        lastSeq = seq;
      }
    }
    return (decoded, lastSeq);
  }

  var exitCode = 0;
  if (x.hasVideo) {
    final full = buildVnote1Video(x);
    stdout.writeln('vnote container: ${full.length} bytes');
    final p = createPlayer(full);
    if (p == nullptr) {
      stdout.writeln('vnote player_create: FAILED');
      exitCode = 1;
    } else {
      final dur = vnDuration(p);
      stdout.writeln('vnote player_create: OK duration=${dur}ms '
          'geometry=${vnWidth(p)}x${vnHeight(p)}');
      final cap = x.width * x.height * 4 + 64;
      final dst = calloc<Uint8>(cap);
      final w = calloc<Int32>();
      final h = calloc<Int32>();
      final sw = Stopwatch()..start();
      final (decoded, _) = walk(p, 0, x.durationMs, 50, dst, cap, w, h);
      sw.stop();
      stdout.writeln('frameAt walk 0..${x.durationMs}ms step 50: decoded=$decoded '
          'frames (src=${x.videoFrames.length}) in ${sw.elapsedMilliseconds}ms, '
          'last=${w.value}x${h.value}');
      if (decoded == 0) exitCode = 1;
      vnDestroy(p);

      // The seek path: a fresh window opening at a mid-file keyframe.
      final keyIdx = <int>[
        for (var i = 0; i < x.videoFrames.length; i++)
          if (x.videoFrames[i].key) i,
      ];
      if (keyIdx.length > 1) {
        final mid = keyIdx[keyIdx.length ~/ 2];
        final windowEnd = keyIdx.length > keyIdx.length ~/ 2 + 1
            ? keyIdx[keyIdx.length ~/ 2 + 1]
            : x.videoFrames.length;
        final window =
            buildVnote1Video(x, fromFrame: mid, toFrame: windowEnd);
        final wp = createPlayer(window);
        if (wp == nullptr) {
          stdout.writeln('mid-window player_create: FAILED');
          exitCode = 1;
        } else {
          final fromTs = x.videoFrames[mid].tsMs;
          final toTs = x.videoFrames[windowEnd - 1].tsMs;
          final (wdec, _) = walk(wp, fromTs, toTs, 50, dst, cap, w, h);
          stdout.writeln('mid-window (frame $mid..$windowEnd, ts $fromTs..$toTs): '
              'player_create OK, decoded=$wdec');
          if (wdec == 0) exitCode = 1;
          vnDestroy(wp);
        }
      }
      calloc.free(dst);
      calloc.free(w);
      calloc.free(h);
    }
  }

  if (x.hasAudio) {
    final vop1 = buildVoiceOpus(x);
    if (vop1 == null) {
      stdout.writeln('audio repack: FAILED');
      exitCode = 1;
    } else {
      final buf = calloc<Uint8>(vop1.length);
      buf.asTypedList(vop1.length).setAll(0, vop1);
      final ap = apCreate(buf, vop1.length);
      if (ap == nullptr) {
        stdout.writeln('audio player_create: FAILED');
        exitCode = 1;
      } else {
        stdout.writeln('audio player_create: OK duration=${apDuration(ap)}ms '
            '(decoded PCM), container=${vop1.length} bytes');
        final rc = apStart(ap);
        stdout.writeln(rc == 0
            ? 'audio player_start: OK (device playout running)'
            : 'audio player_start: rc=$rc — expected on a headless box '
                '(no PulseAudio/ALSA device); NOT a tract failure');
        apDestroy(ap);
      }
      calloc.free(buf);
    }
  }

  stdout.writeln(exitCode == 0 ? 'PROBE PASS' : 'PROBE FAIL');
  exit(exitCode);
}
