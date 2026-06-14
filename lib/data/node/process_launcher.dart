import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A spawned OS process, narrowed to what the node controller needs. Abstracted
/// so the controller's lifecycle logic is unit-testable without a real binary.
abstract interface class NodeProcess {
  Stream<String> get stdoutLines;
  Stream<String> get stderrLines;
  Future<int> get exitCode;

  /// Request termination. Returns false if the process had already exited.
  bool kill();
}

abstract interface class ProcessLauncher {
  Future<NodeProcess> start(
    String executable,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
  });
}

/// Production launcher backed by `dart:io`.
class IoProcessLauncher implements ProcessLauncher {
  const IoProcessLauncher();

  @override
  Future<NodeProcess> start(
    String executable,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    return _IoNodeProcess(process);
  }
}

class _IoNodeProcess implements NodeProcess {
  _IoNodeProcess(this._process);

  final Process _process;

  @override
  Stream<String> get stdoutLines =>
      _process.stdout.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<String> get stderrLines =>
      _process.stderr.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool kill() => _process.kill(ProcessSignal.sigterm);
}
