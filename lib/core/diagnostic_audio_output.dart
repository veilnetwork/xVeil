import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'diagnostic_journal.dart';

/// Run the bundled helper, never a PATH/shell command. The helper queries only
/// its parent process and has its own 1500-ms hard deadline. No raw stderr is
/// retained, and stdout is a bounded, source-owned JSON protocol.
Future<Map<Object?, Object?>?> _readWindowsAudioOutput() async {
  final helper = File(
    '${File(Platform.resolvedExecutable).parent.path}'
    '${Platform.pathSeparator}xveil_audio_probe.exe',
  );
  if (!await helper.exists()) return null;
  final process = await Process.start(helper.path, const [], runInShell: false);
  final stderr = process.stderr.listen((_) {});
  final output = <int>[];
  final drained = Completer<void>();
  Object? readFailure;
  final stdout = process.stdout.listen(
    (bytes) {
      if (output.length + bytes.length > 4096) {
        readFailure = const FormatException('audio probe output too large');
        process.kill();
      } else if (readFailure == null) {
        output.addAll(bytes);
      }
    },
    onError: (Object _) {
      readFailure = const FormatException('audio probe read failed');
    },
    onDone: () => drained.complete(),
  );
  try {
    final exit = await process.exitCode.timeout(const Duration(seconds: 3));
    // Drain the pipe after process exit; exitCode alone does not prove that
    // the final stdout chunk has reached its Dart subscription.
    await drained.future.timeout(const Duration(seconds: 1));
    if (exit != 0 || readFailure != null) {
      throw StateError('audio probe failed');
    }
    final decoded = jsonDecode(utf8.decode(output));
    return decoded is Map<String, dynamic> ? decoded : null;
  } finally {
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 1),
      onTimeout: () => -1,
    );
    await stdout.cancel();
    await stderr.cancel();
  }
}

/// Per-process sampler. A timed-out reader remains the only in-flight reader
/// until it actually finishes; repeated exports cannot spawn more helpers.
class DiagnosticAudioOutputSampler {
  DiagnosticAudioOutputSampler({
    DiagnosticJournal? journal,
    bool? windows,
    Future<Map<Object?, Object?>?> Function()? readState,
    Duration Function()? elapsed,
    this.timeout = const Duration(seconds: 2),
  }) : _journal = journal ?? diagnosticJournal,
       _windows = windows ?? Platform.isWindows,
       _readState = readState ?? _readWindowsAudioOutput,
       _elapsed = elapsed ?? (Stopwatch()..start()).elapsedTime;

  final DiagnosticJournal _journal;
  final bool _windows;
  final Future<Map<Object?, Object?>?> Function() _readState;
  final Duration Function() _elapsed;
  final Duration timeout;
  Future<Map<Object?, Object?>?>? _inFlight;
  Duration? _lastCallSample;

  Future<void> sample({
    bool duringCall = false,
    bool Function()? stillCurrent,
  }) async {
    if (!_journal.enabled || !_windows) return;
    if (duringCall) {
      final now = _elapsed();
      final previous = _lastCallSample;
      if (previous != null && now - previous < const Duration(seconds: 10)) {
        return;
      }
      _lastCallSample = now;
    }
    var read = _inFlight;
    if (read == null) {
      read = Future.sync(_readState);
      _inFlight = read;
      void release() {
        if (identical(_inFlight, read)) _inFlight = null;
      }

      unawaited(
        read.then<void>((_) => release(), onError: (Object _) => release()),
      );
    }
    try {
      final state = await read.timeout(timeout);
      if (duringCall && stillCurrent?.call() == false) return;
      _journal.recordAudioOutputState(state, duringCall: duringCall);
    } catch (_) {
      if (duringCall && stillCurrent?.call() == false) return;
      // Do not stringify process errors, command paths or provider messages.
      _journal.recordAudioOutputState(
        null,
        duringCall: duringCall,
        failed: true,
      );
    }
  }
}

extension on Stopwatch {
  Duration elapsedTime() => elapsed;
}

final diagnosticAudioOutput = DiagnosticAudioOutputSampler();
