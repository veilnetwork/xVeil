// Standalone Linux probe: no Flutter engine or native database dependency.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:xveil/data/storage/managed_linux_rename.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main() {
  require(Platform.isLinux, 'Linux qualification requires a Linux kernel');
  final root = Directory.systemTemp.createTempSync('xveil-linux-rename-');
  var cases = 0;
  try {
    for (final missingWrapper in [false, true]) {
      final prefix = '${root.path}/${missingWrapper ? 'syscall' : 'wrapper'}';
      final source = Directory('$prefix-source')..createSync();
      final destination = Directory('$prefix-destination');
      File('${source.path}/payload').writeAsStringSync('source', flush: true);
      var fallbackLookups = 0;
      int publish() {
        final from = source.path.toNativeUtf8();
        final to = destination.path.toNativeUtf8();
        try {
          return managedLinuxRenameNoReplace(
            from,
            to,
            lookup: (symbol) {
              if (symbol == 'renameat2' && missingWrapper) {
                throw ArgumentError('Synthetic absent libc wrapper');
              }
              if (symbol == 'syscall') fallbackLookups++;
              return DynamicLibrary.process().lookup<Void>(symbol);
            },
          );
        } finally {
          calloc.free(from);
          calloc.free(to);
        }
      }

      destination.createSync();
      require(publish() == -1, 'An empty existing destination was replaced');
      require(source.existsSync(), 'Refused publication lost the source');
      require(destination.listSync().isEmpty, 'Empty destination was changed');
      cases++;

      File('${destination.path}/payload').writeAsStringSync('existing');
      require(publish() == -1, 'A populated destination was replaced');
      require(
        File('${destination.path}/payload').readAsStringSync() == 'existing',
        'Existing destination payload changed',
      );
      require(
        File('${source.path}/payload').readAsStringSync() == 'source',
        'Refused publication changed the source',
      );
      cases++;

      destination.deleteSync(recursive: true);
      final target = Directory('$prefix-link-target')..createSync();
      Link(destination.path).createSync(target.path);
      require(publish() == -1, 'A symlink destination was replaced');
      require(
        FileSystemEntity.isLinkSync(destination.path),
        'The destination symlink changed',
      );
      require(target.listSync().isEmpty, 'The symlink target changed');
      Link(destination.path).deleteSync();
      cases++;

      require(publish() == 0, 'Absent destination did not publish');
      require(!source.existsSync(), 'Successful rename retained the old path');
      require(
        File('${destination.path}/payload').readAsStringSync() == 'source',
        'Published payload is not exact',
      );
      cases++;

      destination.deleteSync(recursive: true);
      require(publish() == -1, 'Missing source was treated as success');
      require(!destination.existsSync(), 'Failure created a destination');
      require(
        fallbackLookups == (missingWrapper ? 5 : 0),
        'Unexpected native backend was exercised',
      );
      cases++;
    }
    require(cases == 10, 'The complete probe did not run');
    stdout.writeln(jsonEncode({'cases': cases, 'abi': '${Abi.current()}'}));
  } catch (_) {
    stderr.writeln(jsonEncode({'completedCases': cases}));
    rethrow;
  } finally {
    root.deleteSync(recursive: true);
  }
}
