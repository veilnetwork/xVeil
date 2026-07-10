// Loopback media streaming (video epic): the player plugins (ExoPlayer /
// AVPlayer) can only consume a FILE or a URL, but our blobs live in the
// encrypted container and the privacy canon forbids spilling plaintext to
// disk. So playback rides a 127.0.0.1 HTTP server that serves the decrypted
// bytes STRAIGHT FROM RAM, with the Range support seeking requires.
//
// Scope: one active item at a time (the open player), a fresh random token
// path per serve (a co-resident local process cannot guess the URL), stopped
// the moment the player closes. Nothing is ever written to disk.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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

/// Serves ONE in-RAM blob over loopback HTTP for the lifetime of a player.
class LocalMediaServer {
  HttpServer? _server;
  Uint8List? _bytes;
  String _mime = 'application/octet-stream';
  String _token = '';

  /// Start serving [bytes] and return the playback URL. Restarts cleanly if
  /// already serving (the previous URL dies with its token).
  Future<Uri> serve(Uint8List bytes, {String? name}) async {
    await stop();
    _bytes = bytes;
    _mime = mediaMimeFor(name);
    _token = _randomToken();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (_) {});
    return Uri.parse('http://127.0.0.1:${server.port}/m/$_token');
  }

  Future<void> _handle(HttpRequest req) async {
    final bytes = _bytes;
    final res = req.response;
    try {
      if (bytes == null || req.uri.path != '/m/$_token') {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final total = bytes.length;
      res.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..contentType = ContentType.parse(_mime);
      final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
      final range = parseRange(rangeHeader, total);
      if (rangeHeader != null && range == null && total > 0) {
        // A syntactically-valid but unsatisfiable range (start >= total).
        final m =
            RegExp(r'^bytes=(\d+)-').firstMatch(rangeHeader.trim());
        if (m != null && (int.tryParse(m.group(1)!) ?? 0) >= total) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
          await res.close();
          return;
        }
      }
      if (range == null) {
        res.statusCode = HttpStatus.ok;
        res.contentLength = total;
        if (req.method != 'HEAD') {
          res.add(bytes);
        }
      } else {
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.end}/$total',
        );
        res.contentLength = range.end - range.start + 1;
        if (req.method != 'HEAD') {
          res.add(Uint8List.sublistView(bytes, range.start, range.end + 1));
        }
      }
      await res.close();
    } catch (_) {
      // Client hung up mid-stream (seek storms do this) — nothing to do.
      try {
        await res.close();
      } catch (_) {/* already dead */}
    }
  }

  /// Stop serving and drop the plaintext buffer reference.
  Future<void> stop() async {
    final s = _server;
    _server = null;
    _bytes = null;
    _token = '';
    if (s != null) await s.close(force: true);
  }

  static String _randomToken() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
  }
}
