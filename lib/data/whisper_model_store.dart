import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../core/log.dart';

/// The speech model, fetched on demand instead of shipped in the build.
///
/// The model is 57 MiB and does not compress — bundling it was 63% of the
/// Android download (89.7 MiB against 32.7 MiB without). Most people never
/// transcribe anything, so most of what they downloaded was a feature they
/// did not use.
///
/// It is stored ONCE FOR THE WHOLE APP, in the support directory root rather
/// than under `profiles/<name>/`: it is a static artifact identical for
/// everyone, carries nothing about the person, and re-downloading 57 MiB per
/// profile would be absurd. This is also where the existing Android and Linux
/// lookups already probe, so a downloaded model is found by the same code that
/// used to find a bundled one.
///
/// What the download must not do is take whatever bytes arrive. The expected
/// size and SHA-256 are pinned here, matching the values the Android packaging
/// step has always verified; anything else is discarded. A model is data, not
/// code, but it is data that shapes what the app says a person said.
class WhisperModelStore {
  WhisperModelStore({
    Future<Directory> Function()? supportDirectory,
    HttpClient Function()? httpClient,
    this.stallTimeout = const Duration(seconds: 30),
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _httpClient = httpClient ?? HttpClient.new;

  final Future<Directory> Function() _supportDirectory;
  final HttpClient Function() _httpClient;

  /// How long the transfer may produce nothing before it is abandoned.
  ///
  /// A mobile connection does not usually fail, it stops: the socket stays
  /// open and no bytes arrive. Without this the app sits on a spinner
  /// indefinitely with no cancel and no retry — a state a person cannot leave.
  /// Abandoning it turns a hang into a failure, and a failure is retryable —
  /// and because the partial bytes are kept, the retry resumes rather than
  /// starting the 57 MiB again.
  final Duration stallTimeout;

  static const fileName = 'ggml-base-q5_1.bin';

  /// Pinned by the Android packaging step since the model was bundled; the
  /// download inherits the same two checks rather than inventing weaker ones.
  static const expectedSha256 =
      '422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898';
  static const expectedBytes = 59707625;

  /// Where the bytes come from. A build can point this somewhere the operator
  /// controls — the default is the canonical whisper.cpp distribution, and
  /// fetching it is a plain HTTPS request from the person's own address, which
  /// is worth knowing about in an app built to avoid exactly that.
  static const downloadUrl = String.fromEnvironment(
    'XVEIL_WHISPER_MODEL_URL',
    defaultValue:
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin',
  );

  Future<File> _target() async =>
      File('${(await _supportDirectory()).path}/$fileName');

  /// The installed model, or null. Cheap: a size check, not a hash — the hash
  /// was verified before the file was ever given this name.
  Future<File?> installed() async {
    final file = await _target();
    if (!file.existsSync()) return null;
    if (file.lengthSync() != expectedBytes) return null;
    return file;
  }

  Future<bool> isInstalled() async => (await installed()) != null;

  /// Delete the model. The person gets 57 MiB back and loses transcription
  /// until they fetch it again; nothing else depends on it.
  Future<void> remove() async {
    final file = await _target();
    if (file.existsSync()) file.deleteSync();
    final part = File('${file.path}.part');
    if (part.existsSync()) part.deleteSync();
  }

  /// How many bytes of an interrupted attempt are waiting to be resumed.
  Future<int> pendingBytes() async {
    final part = File('${(await _target()).path}.part');
    return part.existsSync() ? part.lengthSync() : 0;
  }

  /// Fetch the model, resuming an interrupted attempt where it stopped.
  ///
  /// Resuming is the point, not a nicety: this is 57 MiB, and a phone that
  /// loses the connection at 90% should not start again from zero. Partial
  /// bytes stay in `<name>.part` after a TRANSPORT failure and the next
  /// attempt asks for the rest with a Range request. A server that ignores
  /// Range (answers 200 instead of 206) is handled by starting over rather
  /// than by appending to bytes it did not continue.
  ///
  /// Bytes that fail VERIFICATION are deleted instead of kept: resuming a
  /// download whose content was already wrong would only ever fail again.
  ///
  /// The rename happens only after both checks pass, so an interrupted or
  /// substituted transfer can never be mistaken for a model.
  /// [onProgress] runs with a real fraction every time, never null: the
  /// expected size is pinned, so there is no case where the app must guess.
  /// That also keeps a resumed transfer honest — the server's content-length
  /// describes only the remaining tail, and reporting against it would show a
  /// download that starts at 0% when it is already most of the way there.
  /// [isCancelled] is consulted per chunk. Stopping is a distinct outcome
  /// from failing: the bytes are kept either way, but a person who tapped by
  /// accident on mobile data should see "continue, 40% downloaded" rather
  /// than an error they did not cause.
  Future<WhisperModelDownload> download({
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
    Uri? from,
  }) async {
    final file = await _target();
    final part = File('${file.path}.part');
    final client = _httpClient();
    client.connectionTimeout = stallTimeout;
    try {
      var have = part.existsSync() ? part.lengthSync() : 0;
      if (have >= expectedBytes) {
        // A complete-looking leftover: verify it rather than fetch it again.
        have = 0;
        part.deleteSync();
      }
      final request = await client.getUrl(from ?? Uri.parse(downloadUrl));
      if (have > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      }
      final response = await request.close();

      final resuming = response.statusCode == HttpStatus.partialContent;
      if (response.statusCode != HttpStatus.ok && !resuming) {
        return WhisperModelDownload.failed(
          'server said ${response.statusCode}',
        );
      }
      if (!resuming && have > 0) {
        // Range ignored: the body starts from zero. The file is opened in
        // truncating mode below, so nothing is spliced either way — what this
        // fixes is the COUNT. Leaving it at the leftover size would report a
        // download starting at 40% and then overshooting 100%, on a transfer
        // that is in fact starting over.
        devLog(() => 'xVeil[whisper]: server ignored Range, restarting');
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
            onProgress(
              received >= expectedBytes ? 1 : received / expectedBytes,
            );
          }
        }
      } finally {
        await sink.close();
      }
      if (cancelled) {
        // The partial file stays: this is a pause, not a discard.
        devLog(() => 'xVeil[whisper]: download cancelled at $received bytes');
        return const WhisperModelDownload.cancelled();
      }

      // Size first: it is the cheap half of the same question, and a short
      // body is the common failure while wrong content is the rare one.
      final onDisk = part.existsSync() ? part.lengthSync() : 0;
      if (onDisk != expectedBytes) {
        part.deleteSync();
        return WhisperModelDownload.failed(
          'expected $expectedBytes bytes, got $onDisk',
        );
      }
      // Hash the finished file rather than the stream: a resumed download is
      // half bytes this process never saw, so streaming the digest would only
      // cover the tail.
      final actual = sha256.convert(part.readAsBytesSync()).toString();
      if (actual != expectedSha256) {
        part.deleteSync();
        return WhisperModelDownload.failed('checksum mismatch');
      }
      part.renameSync(file.path);
      devLog(() => 'xVeil[whisper]: model installed ($onDisk bytes)');
      return WhisperModelDownload.ok(file.path);
    } on Object catch (error) {
      // Keep the partial bytes: this is what makes the next attempt a resume.
      // Only verification deletes them, above.
      return WhisperModelDownload.failed('$error');
    } finally {
      client.close(force: true);
    }
  }
}

class WhisperModelDownload {
  const WhisperModelDownload.ok(this.path) : error = null, wasCancelled = false;
  const WhisperModelDownload.failed(this.error)
    : path = null,
      wasCancelled = false;

  /// Stopped by the person, not by a fault. Distinct from [failed] so the UI
  /// does not report an error nobody made.
  const WhisperModelDownload.cancelled()
    : path = null,
      error = null,
      wasCancelled = true;

  final String? path;
  final String? error;
  final bool wasCancelled;

  bool get succeeded => path != null;
}
