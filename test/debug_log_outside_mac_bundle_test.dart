import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/log.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('xveil-log-bundle-'));
  tearDown(() {
    devLogDirectoryOverride = null;
    root.deleteSync(recursive: true);
  });

  test('macOS app logs sit beside the bundle', () {
    expect(
      devLogDirectoriesForExecutable(
        executable: '${root.path}/Test.app/Contents/MacOS/test',
        temporaryDirectory: '${root.path}/tmp',
        macOS: true,
      ),
      [root.path, '${root.path}/tmp'],
    );
  });

  test('standalone commands keep their existing log location', () {
    for (final macOS in [true, false]) {
      expect(
        devLogDirectoriesForExecutable(
          executable: '${root.path}/bin/test',
          temporaryDirectory: '${root.path}/tmp',
          macOS: macOS,
        ),
        ['${root.path}/bin', '${root.path}/tmp'],
      );
    }
  });

  test(
    'writing both logs preserves an actual ad-hoc bundle signature',
    () {
      final bundle = Directory('${root.path}/Test.app');
      final executable = '${bundle.path}/Contents/MacOS/test';
      File(executable).parent.createSync(recursive: true);
      // A real Mach-O, never executed. No SDK or identity is substituted.
      File('/usr/bin/true').copySync(executable);
      File('${bundle.path}/Contents/Info.plist').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>test</string>
<key>CFBundleIdentifier</key><string>network.veil.qa.log-bundle</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
''');
      final signed = Process.runSync('/usr/bin/codesign', [
        '--force',
        '--sign',
        '-',
        bundle.path,
      ]);
      expect(signed.exitCode, 0, reason: signed.stderr.toString());
      final dirs = devLogDirectoriesForExecutable(
        executable: executable,
        temporaryDirectory: Directory.systemTemp.path,
        macOS: true,
      );
      devLogDirectoryOverride = dirs.first;
      devLog(() => 'signing fixture line');
      final node = debugNodeLogPath();
      expect(node, isNotNull);
      File(node!).writeAsStringSync('native signing fixture line');
      expect(File(devLogFilePath!).existsSync(), isTrue);
      final verified = Process.runSync('/usr/bin/codesign', [
        '--verify',
        '--deep',
        '--strict',
        bundle.path,
      ]);
      expect(verified.exitCode, 0, reason: verified.stderr.toString());
    },
    skip: !Platform.isMacOS ? 'Requires macOS codesign' : false,
  );
}
