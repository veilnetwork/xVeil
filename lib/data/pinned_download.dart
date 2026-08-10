import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../core/log.dart';

/// Fetching a file whose size and hash are known in advance.
///
/// This began as the body of [WhisperModelStore.download] and was lifted out
/// when translation needed the same thing per language pair. Lifted rather
/// than copied deliberately: a second copy of a hundred-line transfer loop is
/// two implementations of resume, two of the Range fallback, and eventually
/// one of them missing a fix the other got. That failure has already happened
/// in this repository this week, in build arguments, and cost a fifteen-minute
/// CI job every time.
///
/// Everything the speech model learned the hard way is preserved here, because
/// all of it applies again to a 40-150 MB translation model on the same phone
/// and the same connection.

/// A file the app knows the size and hash of before it asks for it.
class PinnedArtifact {
  const PinnedArtifact({
    required this.url,
    required this.bytes,
    required this.sha256,
  });

  final String url;
  final int bytes;

  /// Lowercase hex. Content that does not match is deleted, not kept: a
  /// resume of bytes that were already wrong can only ever fail again.
  final String sha256;
}

class PinnedDownload {
  const PinnedDownload.ok(this.path) : error = null, wasCancelled = false;
  const PinnedDownload.failed(this.error) : path = null, wasCancelled = false;

  /// Stopped by the person, not by a fault. Distinct from [failed] so the UI
  /// does not report an error nobody made.
  const PinnedDownload.cancelled()
    : path = null,
      error = null,
      wasCancelled = true;

  final String? path;
  final String? error;
  final bool wasCancelled;

  bool get succeeded => path != null;
}

/// Fetch [artifact] to [target], resuming an interrupted attempt where it
/// stopped.
///
/// Resuming is the point, not a nicety: these are tens of megabytes, and a
/// phone that loses the connection at 90% should not start again from zero.
/// Partial bytes stay in `<name>.part` after a TRANSPORT failure and the next
/// attempt asks for the rest with a Range request. A server that ignores Range
/// (answers 200 instead of 206) is handled by starting over rather than by
/// appending to bytes it did not continue.
///
/// The rename happens only after both checks pass, so an interrupted or
/// substituted transfer can never be mistaken for a finished file.
///
/// [onProgress] runs with a real fraction every time, never null: the expected
/// size is pinned, so there is no case where the app must guess. That also
/// keeps a resumed transfer honest — the server's content-length describes
/// only the remaining tail, and reporting against it would show a download
/// that starts at 0% when it is already most of the way there.
///
/// [isCancelled] is consulted per chunk. Stopping is a distinct outcome from
/// failing: the bytes are kept either way, but a person who tapped by accident
/// on mobile data should see "continue, 40% downloaded" rather than an error
/// they did not cause.
///
/// [stallTimeout] is how long the transfer may produce nothing before it is
/// abandoned. A mobile connection does not usually fail, it stops: the socket
/// stays open and no bytes arrive. Without this the app sits on a spinner
/// indefinitely with no cancel and no retry — a state a person cannot leave.
Future<PinnedDownload> fetchPinned({
  required File target,
  required PinnedArtifact artifact,
  required HttpClient Function() httpClient,
  required Duration stallTimeout,
  required String logTag,
  void Function(double progress)? onProgress,
  bool Function()? isCancelled,
  Uri? from,
}) async {
  final part = File('${target.path}.part');
  final client = httpClient();
  client.connectionTimeout = stallTimeout;
  try {
    var have = part.existsSync() ? part.lengthSync() : 0;
    if (have >= artifact.bytes) {
      // A complete-looking leftover: verify it rather than fetch it again.
      have = 0;
      part.deleteSync();
    }
    final request = await client.getUrl(from ?? Uri.parse(artifact.url));
    if (have > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
    }
    final response = await request.close();

    final resuming = response.statusCode == HttpStatus.partialContent;
    if (response.statusCode != HttpStatus.ok && !resuming) {
      return PinnedDownload.failed('server said ${response.statusCode}');
    }
    if (!resuming && have > 0) {
      // Range ignored: the body starts from zero. The file is opened in
      // truncating mode below, so nothing is spliced either way — what this
      // fixes is the COUNT. Leaving it at the leftover size would report a
      // download starting at 40% and then overshooting 100%, on a transfer
      // that is in fact starting over.
      devLog(() => 'xVeil[$logTag]: server ignored Range, restarting');
      have = 0;
    }

    final sink = part.openWrite(
      mode: resuming ? FileMode.writeOnlyAppend : FileMode.writeOnly,
    );
    var received = have;
    var cancelled = false;
    try {
      await for (final chunk in response.timeout(stallTimeout)) {
        if (isCancelled != null && isCancelled()) {
          cancelled = true;
          break;
        }
        sink.add(chunk);
        received += chunk.length;
        if (onProgress != null) {
          onProgress(received >= artifact.bytes ? 1 : received / artifact.bytes);
        }
      }
    } finally {
      await sink.close();
    }
    if (cancelled) {
      // The partial file stays: this is a pause, not a discard.
      devLog(() => 'xVeil[$logTag]: download cancelled at $received bytes');
      return const PinnedDownload.cancelled();
    }

    // Size first: it is the cheap half of the same question, and a short body
    // is the common failure while wrong content is the rare one.
    final onDisk = part.existsSync() ? part.lengthSync() : 0;
    if (onDisk != artifact.bytes) {
      part.deleteSync();
      return PinnedDownload.failed('expected ${artifact.bytes} bytes, got $onDisk');
    }
    // Hash the finished FILE rather than the download stream: a resumed
    // download is half bytes this process never saw, so digesting the stream
    // would only cover the tail.
    //
    // Read in chunks, though. `readAsBytesSync` pulled the whole file into the
    // heap at once, on whatever isolate this runs — a spike big enough to
    // matter on the low-end devices these models exist for, and synchronous
    // besides (audit XV-21). The digest is identical either way.
    final actual = await sha256OfFileStreaming(part);
    if (actual != artifact.sha256) {
      part.deleteSync();
      return const PinnedDownload.failed('checksum mismatch');
    }
    part.renameSync(target.path);
    devLog(() => 'xVeil[$logTag]: installed ${target.path} ($onDisk bytes)');
    return PinnedDownload.ok(target.path);
  } on Object catch (error) {
    // Keep the partial bytes: this is what makes the next attempt a resume.
    // Only verification deletes them, above.
    return PinnedDownload.failed('$error');
  } finally {
    client.close(force: true);
  }
}

/// SHA-256 of a file, read in chunks rather than loaded whole.
///
/// Same digest as `sha256.convert(file.readAsBytesSync())`, without holding
/// the file in memory — which for the speech model is ~57 MiB (audit XV-21).
@visibleForTesting
Future<String> sha256OfFileStreaming(File file) async {
  final sink = _DigestSink();
  final input = sha256.startChunkedConversion(sink);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  final digest = sink.digest;
  if (digest == null) {
    // Unreachable: `close` always emits exactly one digest. Surfaced rather
    // than defaulted, because a silent empty hash would read as "mismatch"
    // and delete a file that was fine.
    throw StateError('sha256 chunked conversion produced no digest');
  }
  return digest.toString();
}

class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
