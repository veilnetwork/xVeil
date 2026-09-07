// A crash report needs a log that was written down. `developer.log` needs a
// debugger, the stdout echo needs a console a GUI process on Windows does not
// have, and the ring buffer dies with the process — which is the moment its
// contents were wanted. A build that logs at all writes the log where a person
// can find it without being told anything but "the folder you started it from".
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/log.dart';
import 'package:xveil/data/node/embedded_node.dart';

void main() {
  // Redirected, because the default is "beside the running binary" and under
  // `flutter test` that binary is `flutter_tester` — inside the Flutter SDK's
  // own cache, shared with every other test process on the machine.
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('xveil-log-test-');
    devLogDirectoryOverride = dir.path;
  });
  tearDown(() {
    devLogDirectoryOverride = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a debug build writes its log to a file', () {
    // The suite runs unter the Dart VM, which is a debug build by the same
    // compile-time constants the app uses, so the sink is live here.
    expect(kXVeilDebugBuild, isTrue, reason: 'this test needs a debug build');
    devLog(() => 'a line to open the file with');
    final path = devLogFilePath;
    expect(path, isNotNull, reason: 'nothing was written anywhere');
    expect(File(path!).existsSync(), isTrue);
    expect(
      File(path).readAsStringSync(),
      contains('a line to open the file with'),
      reason: 'the file exists and the line is not in it',
    );
  });

  test('the line carries a timestamp, which is the first thing asked of it', () {
    devLog(() => 'stamped-line-marker');
    final body = File(devLogFilePath!).readAsStringSync();
    final line = body
        .split('\n')
        .lastWhere((l) => l.contains('stamped-line-marker'), orElse: () => '');
    expect(line, isNotEmpty);
    expect(
      DateTime.tryParse(line.split(' ').first),
      isNotNull,
      reason: 'the line begins with "$line" rather than a time',
    );
  });

  test('a distribution build cannot be made to write one', () {
    // The sink lives inside the same compile-time gate as devLog, so the
    // question is not "is it off by default" but "can it exist at all". A
    // constant somebody could flip at runtime would be the wrong shape: these
    // lines carry node ids.
    final source = File('lib/core/log.dart').readAsStringSync();
    final at = source.indexOf('_writeLogFile(stamped)');
    expect(at, isNot(-1), reason: 'the file sink is no longer called');
    final gate = source.substring(0, at).lastIndexOf('if (!_productMode');
    expect(
      gate,
      isNot(-1),
      reason: 'the file write escaped the compile-time gate, so a '
          'distribution build could write node ids to disk',
    );
  });

  group('the node writes its half too', () {
    test('a debug build names a file for it, beside the app log', () {
      final nodeLog = debugNodeLogPath();
      expect(nodeLog, isNotNull, reason: 'the node log has no home');
      devLog(() => 'open the app log');
      expect(
        File(nodeLog!).parent.path,
        File(devLogFilePath!).parent.path,
        reason:
            'the two halves of a crash report land in different folders, so '
            '"send me what is next to the exe" stops being the whole '
            'instruction',
      );
    });

    test('and the path reaches the node config', () {
      // A patcher nobody calls is the shape of this morning's lanListen: the
      // value is computed correctly and never handed on.
      final source = File('lib/data/veil_stack.dart').readAsStringSync();
      expect(
        source,
        contains('logFile: debugNodeLogPath()'),
        reason: 'the stack composes the node config without a log file, so '
            'the node keeps writing to a stderr nobody can read',
      );
    });

    test('the key lands in [global], where veil reads it', () {
      // Same hazard as identity_dir: a second key in a rendered [global] is a
      // duplicate the TOML parser rejects outright.
      const rendered = '[global]\nlog_file = "old"\nadmin_max_connections = 8\n';
      final patched = EmbeddedNode.withLogFile(rendered, '/tmp/new.log');
      expect('log_file'.allMatches(patched).length, 1);
      expect(patched, contains('log_file = "/tmp/new.log"'));
      expect(
        patched,
        contains('admin_max_connections = 8'),
        reason: 'patching [global] dropped what else was in it',
      );
    });

    test('and nothing is written when there is no path', () {
      const toml = '[global]\nadmin_max_connections = 8\n';
      expect(EmbeddedNode.withLogFile(toml, null), toml);
      expect(EmbeddedNode.withLogFile(toml, ''), toml);
    });
  });

  group('a write that failed does not silence the rest of the session', () {
    // MEASURED ON WINDOWS, not here: the stand's diagnostic build wrote eleven
    // lines and then nothing at all through an unlock, a node start and
    // everything after — because a reader that does not share writes (an
    // ordinary copy, which is exactly what a person does to SEND us the log)
    // made one write throw, and the sink had disabled itself for good.
    //
    // Not reproducible on this host: on POSIX the handle survives having the
    // file deleted under it, so there is no portable way to make a write fail
    // from a test. The structure is what is guarded here; the behaviour was
    // checked on the machine that has it.
    test('the sink reopens instead of giving up on the first failure', () {
      final source = File('lib/core/log.dart').readAsStringSync();
      final at = source.indexOf('void _writeLogFile');
      expect(at, isNot(-1), reason: 'the sink was renamed');
      final body = source.substring(at, source.indexOf('\n}', at));
      expect(
        body,
        contains('_logFileTried = false'),
        reason: 'a failed write leaves the sink closed AND marked as tried, '
            'so nothing is ever written again — the state the stand was in',
      );
    });

    test('but it stops trying rather than storming a full disk', () {
      final source = File('lib/core/log.dart').readAsStringSync();
      final at = source.indexOf('void _writeLogFile');
      final body = source.substring(at, source.indexOf('\n}', at));
      expect(
        body,
        contains('_logFileFailures >= _logFileGiveUpAfter'),
        reason: 'the retry is unbounded, so a disk that will never accept a '
            'line turns every line into an open/write/close',
      );
      expect(
        body,
        contains('_logFileFailures = 0'),
        reason: 'the failure count never resets, so five failures spread over '
            'a long session silence a sink that worked in between',
      );
    });
  });
}
