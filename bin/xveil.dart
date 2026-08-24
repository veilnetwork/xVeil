import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:xveil/api/api_server.dart' show ApiCapabilities, openApiSpec;
import 'package:xveil/headless/headless_config.dart';
import 'package:xveil/headless/headless_runtime.dart';
import 'package:xveil/headless/secret_file.dart';

Future<void> main(List<String> args) async {
  try {
    // `--help` ANYWHERE, not just first. `xveil init-config --help` used to
    // take the flag as the output PATH and write a config file called
    // `--help` into the working directory — the one thing a person typing
    // --help is certainly not asking for.
    if (args.isEmpty ||
        args.any((a) => a == 'help' || a == '--help' || a == '-h')) {
      _usage();
      return;
    }
    switch (args.first) {
      case 'init-config':
        if (args.length != 2) throw const FormatException('need output path');
        // A path that looks like a flag is a typo, not a destination. Writing
        // to it leaves a file nobody asked for and named after the mistake.
        if (args[1].startsWith('-')) {
          throw FormatException('${args[1]} looks like an option, not a path');
        }
        final file = File(args[1]);
        if (await file.exists()) {
          throw StateError('${file.path} already exists');
        }
        await file.parent.create(recursive: true);
        await file.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(HeadlessConfig.example)}\n',
          mode: FileMode.writeOnly,
        );
        stdout.writeln(file.absolute.path);
      case 'generate-token':
        stdout.writeln(_generateToken());
      case 'print-openapi':
        // THIS binary's contract. It used to print the union of every host's,
        // so a client generated from it was built against `/v1/cloud/*`,
        // `/v1/calls/*` and an account lock the daemon answers 501/404 to —
        // discovered at runtime, by the person who trusted the document.
        stdout.writeln(
          const JsonEncoder.withIndent(
            '  ',
          ).convert(openApiSpec(capabilities: ApiCapabilities.headless)),
        );
      case 'run':
        await _run(args.sublist(1));
      default:
        throw FormatException('unknown command: ${args.first}');
    }
  } catch (e) {
    stderr.writeln('xveil: $e');
    exitCode = 64;
  }
}

Future<void> _run(List<String> args) async {
  String? configPath;
  String? passwordFile;
  String? phraseFile;
  String? tokenFile;
  final fileRoots = <String>[];
  var create = false;
  var acceptUnchecked = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      // The operator asserting what this process could not check. Only
      // meaningful where a secret file cannot be verified at all — Windows.
      case kAcceptUncheckedSecretFilesFlag:
        acceptUnchecked = true;
      case '--config':
        configPath = _next(args, ++i, '--config');
      case '--password-file':
        passwordFile = _next(args, ++i, '--password-file');
      case '--identity-phrase-file':
        phraseFile = _next(args, ++i, '--identity-phrase-file');
      case '--api-token-file':
        tokenFile = _next(args, ++i, '--api-token-file');
      // Repeatable. Without at least one, `POST /v1/files` is refused: the
      // provisioned token authenticates a bot, it does not hand it the disk
      // (audit XV-08).
      case '--api-file-root':
        fileRoots.add(_next(args, ++i, '--api-file-root'));
      case '--create':
        create = true;
      default:
        throw FormatException('unknown run option: ${args[i]}');
    }
  }
  configPath ??= Platform.environment['XVEIL_CONFIG'];
  passwordFile ??= Platform.environment['XVEIL_PASSWORD_FILE'];
  phraseFile ??= Platform.environment['XVEIL_IDENTITY_PHRASE_FILE'];
  tokenFile ??= Platform.environment['XVEIL_API_TOKEN_FILE'];
  if (fileRoots.isEmpty) {
    final fromEnv = Platform.environment['XVEIL_API_FILE_ROOTS'];
    if (fromEnv != null && fromEnv.isNotEmpty) {
      fileRoots.addAll(
        fromEnv
            .split(Platform.isWindows ? ';' : ':')
            .where((r) => r.isNotEmpty),
      );
    }
  }
  if (configPath == null || configPath.isEmpty) {
    throw const FormatException('--config or XVEIL_CONFIG is required');
  }
  acceptUnchecked =
      acceptUnchecked ||
      Platform.environment[kAcceptUncheckedSecretFilesEnv] == '1';

  Future<String> readSecret(String path, String label) => readSecretFile(
    path,
    label,
    acceptUnchecked: acceptUnchecked,
    warn: stderr.writeln,
  );

  // No file option ⇒ the terminal prompt, which is the path this daemon
  // prefers: nothing is written down, so there is nothing for another account
  // to read and nothing for this process to have to vouch for.
  final password = passwordFile == null
      ? _readSecretFromTerminal('Store password: ')
      : await readSecret(passwordFile, 'password');
  final phrase = phraseFile == null
      ? null
      : await readSecret(phraseFile, 'identity phrase');
  final token = tokenFile == null
      ? null
      : await readSecret(tokenFile, 'API token');
  final config = await HeadlessConfig.load(configPath);
  final runtime = await HeadlessRuntime.start(
    config: config,
    password: password,
    createIfMissing: create,
    identityPhrase: phrase,
    apiToken: token,
    apiFileRoots: fileRoots,
  );
  stdout.writeln(
    jsonEncode({
      'ready': true,
      'api': 'http://127.0.0.1:${runtime.api.port}/v1',
      'node': (await runtime.stack.transport.nodeId()).hex,
    }),
  );

  final stopped = Completer<void>();
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  void stop(ProcessSignal _) {
    if (!stopped.isCompleted) stopped.complete();
  }

  for (final signal in stopSignals(isWindows: Platform.isWindows)) {
    try {
      subscriptions.add(signal.watch().listen(stop));
    } on Object catch (e) {
      // A platform that refuses a signal this list says it allows. Say so:
      // the consequence is that one of the ways to stop this daemon quietly
      // stops working, and nothing else would ever mention it.
      stderr.writeln('xveil: cannot watch ${signal.name} ($e)');
    }
  }
  if (subscriptions.isEmpty) {
    // Nothing can ask this process to stop, so `stopped` never completes and
    // the ordered close below never runs — the container keeps its exclusive
    // lock and the node stays up until something kills the process. Worth a
    // line before it happens rather than a mystery afterwards.
    stderr.writeln(
      'xveil: no stop signal could be watched — only a forced kill will end '
      'this process, and it will skip the ordered close',
    );
  }
  try {
    await stopped.future;
  } finally {
    for (final sub in subscriptions) {
      await sub.cancel();
    }
    await runtime.close();
  }
  // A standalone host may still have native worker threads winding down after
  // every Dart handle, node and encrypted-store resource has closed. Returning
  // from main leaves the AOT process waiting for those foreign threads on some
  // platforms. At this point cleanup has completed, so terminate the service
  // process explicitly just like a conventional daemon entrypoint.
  exit(0);
}

/// The signals this daemon takes as "stop", by platform.
///
/// SIGINT is watchable everywhere, Windows included — it is what Ctrl-C and a
/// console stop deliver. Only SIGTERM (and SIGUSR1/2, SIGWINCH) are absent
/// there. A blanket `if (!Platform.isWindows)` skipped both, so on Windows
/// nothing ever completed the stop future: `runtime.close` never ran, the
/// encrypted container kept its exclusive lock and the node stayed up until
/// something killed the process — which is precisely the ordered close being
/// skipped.
List<ProcessSignal> stopSignals({required bool isWindows}) => [
  ProcessSignal.sigint,
  if (!isWindows) ProcessSignal.sigterm,
];

String _next(List<String> args, int index, String option) {
  if (index >= args.length) throw FormatException('$option needs a value');
  return args[index];
}

/// The preferred way in: typed, echo off, never written anywhere.
String _readSecretFromTerminal(String prompt) {
  if (!stdin.hasTerminal) {
    throw StateError(
      'no terminal: supply --password-file or XVEIL_PASSWORD_FILE',
    );
  }
  stderr.write(prompt);
  final previousEcho = stdin.echoMode;
  try {
    stdin.echoMode = false;
    final value = stdin.readLineSync()?.trim() ?? '';
    stderr.writeln();
    if (value.isEmpty) throw StateError('password is empty');
    return value;
  } finally {
    stdin.echoMode = previousEcho;
  }
}

String _generateToken() {
  final random = Random.secure();
  return base64Url
      .encode(List<int>.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

void _usage() {
  stdout.write('''
xVeil headless daemon

  xveil init-config PATH
  xveil generate-token
  xveil print-openapi
  xveil run --config PATH [--create]
            [--password-file PATH] [--identity-phrase-file PATH]
            [--api-token-file PATH] [--api-file-root DIR]...
            [--accept-unchecked-secret-files]

Secrets are never accepted in the JSON config or as literal command-line
arguments. Preferred: run from a terminal with no --password-file and type the
store password at the prompt — nothing is written down, so there is no file for
another account to read.

A credential file is the unattended fallback, and it is refused unless this
process can show it is private: not a symlink, a regular file, and on POSIX no
permission bit beyond the owner's. On WINDOWS none of that can be checked from
Dart (no ACL, no owner), so a secret file is REFUSED there until you restrict it
yourself and pass --accept-unchecked-secret-files (or set
XVEIL_ACCEPT_UNCHECKED_SECRET_FILES=1). That flag records your assertion; it
verifies nothing.

Native libraries may be selected with VEIL_FFI_DYLIB and XVEIL_HV_DYLIB.

--api-file-root is repeatable (or XVEIL_API_FILE_ROOTS, path-separated) and
names the only folders POST /v1/files may send a local file out of. With none,
that endpoint is refused: the API token authenticates a bot, it does not grant
it the filesystem.
''');
}
