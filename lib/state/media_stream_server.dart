// Loopback media streaming (video epic): the player plugins (ExoPlayer /
// AVPlayer) can only consume a FILE or a URL, but our blobs live in the
// encrypted container and the privacy canon forbids spilling plaintext to
// disk. So playback rides a 127.0.0.1 HTTP server, with the Range support
// seeking requires.
//
// P0-5: it serves from a [RangeSource] rather than a resident buffer. It used
// to hold the entire decrypted item in RAM for the life of the player, so
// opening a multi-GB video cost a multi-GB allocation before the first frame —
// and the whole file was decrypted even when the viewer watched ten seconds
// and closed it. Now only the range a player actually asks for is decrypted,
// and only while it is in flight. Still nothing on disk: the source reads out
// of the container, it does not stage a copy.
//
// Scope: one active item at a time (the open player), a fresh random token
// path per serve (a co-resident local process cannot guess the URL), stopped
// the moment the player closes.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../domain/range_source.dart';
import 'package:flutter/foundation.dart';

/// A parsed `Range: bytes=a-b` header against a body of [total] bytes:
/// closed, half-open (`a-`) and suffix (`-n`) forms, clamped to the body.
/// Null = no/invalid range → serve the whole body with 200 (players treat a
/// malformed range as "no range"; an UNSATISFIABLE one returns 416 upstream).
({int start, int end})? parseRange(String? header, int total) {
  if (header == null || total <= 0) return null;
  final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (m == null) return null;
  final rawStart = m.group(1)!;
  final rawEnd = m.group(2)!;
  if (rawStart.isEmpty && rawEnd.isEmpty) return null;
  if (rawStart.isEmpty) {
    // Suffix form: last N bytes.
    final n = int.tryParse(rawEnd);
    if (n == null || n <= 0) return null;
    final start = max(0, total - n);
    return (start: start, end: total - 1);
  }
  final start = int.tryParse(rawStart);
  if (start == null || start >= total) return null; // unsatisfiable
  final end = rawEnd.isEmpty
      ? total - 1
      : min(int.tryParse(rawEnd) ?? (total - 1), total - 1);
  if (end < start) return null;
  return (start: start, end: end);
}

/// Content-Type for the player by file extension (a wrong type mostly still
/// plays — containers self-describe — but AVPlayer is picky about mp4/mov).
String mediaMimeFor(String? name) {
  final n = (name ?? '').toLowerCase();
  if (n.endsWith('.mp4') || n.endsWith('.m4v')) return 'video/mp4';
  if (n.endsWith('.mov')) return 'video/quicktime';
  if (n.endsWith('.webm')) return 'video/webm';
  if (n.endsWith('.mkv')) return 'video/x-matroska';
  if (n.endsWith('.avi')) return 'video/x-msvideo';
  if (n.endsWith('.wav')) return 'audio/wav';
  return 'application/octet-stream';
}

/// Serves ONE blob over loopback HTTP, in ranges, for the lifetime of a player.
class LocalMediaServer {
  /// Bumped by every [serve] and every [stop].
  ///
  /// `stop` sweeps what the field holds; `serve` binds and only then assigns.
  /// A stop landing in that window found nothing to close, and serve then
  /// published a listener nobody holds a reference to — an open loopback
  /// socket for the life of the process, answering on a token `stop` had
  /// already cleared (report9 X-12).
  int _generation = 0;

  /// Awaited once, between binding the socket and adopting it. Null in
  /// production; a test uses it to hold that window open.
  ///
  /// The window cannot be produced any other way: a loopback bind finishes
  /// before anything else in the test gets a turn, so the interleaving that
  /// leaves a socket bound to nobody is unreachable by timing alone. Cleared
  /// on use, so only the first bind waits.
  @visibleForTesting
  static Future<void>? debugBindGate;

  HttpServer? _server;
  RangeSource? _source;
  String _mime = 'application/octet-stream';
  String _token = '';

  /// Start serving [source] and return the playback URL. Restarts cleanly if
  /// already serving (the previous URL dies with its token).
  ///
  /// Takes ownership: [stop] disposes the source, so the container handle it
  /// holds is released when the player closes rather than at the next GC.
  Future<Uri> serve(RangeSource source, {String? name}) async {
    await stop();
    final generation = ++_generation;
    _source = source;
    _mime = mediaMimeFor(name);
    _token = _randomToken();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gate = debugBindGate;
    if (gate != null) {
      debugBindGate = null;
      await gate;
    }
    if (generation != _generation) {
      // Stopped — or replaced by another serve — while this was binding. The
      // socket is ours and nobody else can reach it, so close it here; the
      // source is NOT disposed, because whoever bumped the generation ran
      // `stop` and already took it.
      await server.close(force: true);
      throw StateError('serving was stopped while the server was binding');
    }
    _server = server;
    server.listen(_handle, onError: (_) {});
    return Uri.parse('http://127.0.0.1:${server.port}/m/$_token');
  }

  Future<void> _handle(HttpRequest req) async {
    final source = _source;
    final res = req.response;
    try {
      if (source == null || req.uri.path != '/m/$_token') {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final total = source.size;
      res.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..contentType = ContentType.parse(_mime);
      final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
      final range = parseRange(rangeHeader, total);
      if (rangeHeader != null && range == null && total > 0) {
        // A syntactically-valid but unsatisfiable range (start >= total).
        final m = RegExp(r'^bytes=(\d+)-').firstMatch(rangeHeader.trim());
        if (m != null && (int.tryParse(m.group(1)!) ?? 0) >= total) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
          await res.close();
          return;
        }
      }
      final int start;
      final int length;
      if (range == null) {
        res.statusCode = HttpStatus.ok;
        start = 0;
        length = total;
      } else {
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.end}/$total',
        );
        start = range.start;
        length = range.end - range.start + 1;
      }
      res.contentLength = length;
      if (req.method != 'HEAD') {
        // Chunk by chunk with a flush between: the awaited flush is what keeps
        // a player that requested a huge range from pulling the whole thing
        // into this process ahead of consuming it.
        await for (final chunk in rangeChunks(source, start, length)) {
          res.add(chunk);
          await res.flush();
        }
      }
      await res.close();
    } catch (_) {
      // Client hung up mid-stream (seek storms do this) — nothing to do.
      try {
        await res.close();
      } catch (_) {
        /* already dead */
      }
    }
  }

  /// Stop serving, release the source and its handle.
  Future<void> stop() async {
    _generation++;
    final s = _server;
    final source = _source;
    _server = null;
    _source = null;
    _token = '';
    if (s != null) await s.close(force: true);
    await source?.dispose();
  }

  static String _randomToken() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
  }
}
