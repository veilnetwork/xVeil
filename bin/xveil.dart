import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:xveil/api/api_server.dart' show openApiSpec;
import 'package:xveil/headless/headless_config.dart';
import 'package:xveil/headless/headless_runtime.dart';

Future<void> main(List<String> args) async {
  try {
    if (args.isEmpty || args.first == 'help' || args.first == '--help') {
      _usage();
      return;
    }
    switch (args.first) {
      case 'init-config':
        if (args.length != 2) throw const FormatException('need output path');
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
        stdout.writeln(
          const JsonEncoder.withIndent('  ').convert(openApiSpec()),
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
  var create = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--config':
        configPath = _next(args, ++i, '--config');
      case '--password-file':
        passwordFile = _next(args, ++i, '--password-file');
      case '--identity-phrase-file':
        phraseFile = _next(args, ++i, '--identity-phrase-file');
      case '--api-token-file':
        tokenFile = _next(args, ++i, '--api-token-file');
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
  if (configPath == null || configPath.isEmpty) {
    throw const FormatException('--config or XVEIL_CONFIG is required');
  }

  final password = passwordFile == null
      ? _readSecretFromTerminal('Store password: ')
      : await _readSecretFile(passwordFile, 'password');
  final phrase = phraseFile == null
      ? null
      : await _readSecretFile(phraseFile, 'identity phrase');
  final token = tokenFile == null
      ? null
      : await _readSecretFile(tokenFile, 'API token');
  final config = await HeadlessConfig.load(configPath);
  final runtime = await HeadlessRuntime.start(
    config: config,
    password: password,
    createIfMissing: create,
    identityPhrase: phrase,
    apiToken: token,
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

  if (!Platform.isWindows) {
    subscriptions.add(ProcessSignal.sigterm.watch().listen(stop));
    subscriptions.add(ProcessSignal.sigint.watch().listen(stop));
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

String _next(List<String> args, int index, String option) {
  if (index >= args.length) throw FormatException('$option needs a value');
  return args[index];
}

Future<String> _readSecretFile(String path, String label) async {
  final value = (await File(path).readAsString()).trim();
  if (value.isEmpty) throw StateError('$label file is empty');
  return value;
}

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
            [--api-token-file PATH]

Secrets are never accepted in the JSON config or as literal command-line
arguments. For unattended services use protected credential files. Native
libraries may be selected with VEIL_FFI_DYLIB and XVEIL_HV_DYLIB.
''');
}
