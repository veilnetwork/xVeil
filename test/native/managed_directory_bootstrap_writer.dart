import 'dart:io';

import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';

class _PausePublication extends ManagedFsPlatform {
  _PausePublication(this.fixture, this.phase);
  final String fixture;
  final String phase;
  Never markAndWait() {
    File('$fixture/ready.pending')
      ..writeAsStringSync('$pid:$phase', flush: true)
      ..renameSync('$fixture/ready');
    while (true) {
      sleep(const Duration(milliseconds: 50));
    }
  }

  @override
  bool publishDirectoryNoReplace(String source, String destination) {
    if (phase == 'before') markAndWait();
    final result = super.publishDirectoryNoReplace(source, destination);
    if (!result) exit(4);
    super.syncDirectory(Directory(destination).parent.path);
    markAndWait();
  }
}

void main(List<String> args) {
  if (args.length != 2) exit(2);
  final fixture = Directory(args[0]).resolveSymbolicLinksSync();
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  final phase = args[1];
  if (!fixture.startsWith('$temporary/xveil-managed-bootstrap-') ||
      !['before', 'after'].contains(phase)) {
    exit(3);
  }
  ManagedDirectoryCatalog.createOrOpen(
    '$fixture/profile',
    fs: _PausePublication(fixture, phase),
  );
}
