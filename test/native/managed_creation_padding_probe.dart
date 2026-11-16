// Standalone AOT process probe: see the managed Windows padding qualification.
// Takes only an explicitly marked, disposable fixture; never deletes a directory.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:hidden_volume/src/bindings.dart' as bindings;

void require(bool value, String reason) {
  if (!value) throw StateError(reason);
}

bool same(List<int>? a, List<int> b) =>
    a != null &&
    a.length == b.length &&
    List.generate(b.length, (i) => a[i] == b[i]).every((v) => v);

void main(List<String> args) {
  var stage = 'arguments';
  try {
    require(args.length == 3, 'expected mode, library and fixture');
    final mode = args[0];
    require(
      [
        'abi',
        'create',
        'reopen',
        'create-default',
        'reopen-default',
      ].contains(mode),
      'invalid mode',
    );
    final fixture = Directory(args[2]);
    require(
      fixture.isAbsolute &&
          FileSystemEntity.typeSync(fixture.path, followLinks: false) ==
              FileSystemEntityType.directory,
      'existing absolute fixture directory required',
    );
    final name = fixture.uri.pathSegments.where((v) => v.isNotEmpty).last;
    require(
      name.startsWith('xveil-padding-probe-'),
      'fixture name not admitted',
    );
    final marker = File('${fixture.path}/probe-owner.txt');
    require(
      FileSystemEntity.typeSync(marker.path, followLinks: false) ==
              FileSystemEntityType.file &&
          marker.readAsStringSync() == 'synthetic-native-padding-probe-v1',
      'fixture marker not admitted',
    );
    stage = 'abi';
    bindings.overrideDylib(DynamicLibrary.open(args[1]));
    bindings.verifyAbiCompatibility();
    if (mode == 'abi') {
      stdout.writeln(jsonEncode({'success': true, 'stage': stage}));
      return;
    }
    final defaultPadding = mode.endsWith('-default');
    final creating = mode.startsWith('create');
    final rows = <Map<String, Object>>[];
    for (final role
        in (defaultPadding
            ? ['hidden']
            : ['keybox', 'content', 'maintenance'])) {
      stage = '$mode-$role';
      final file = File('${fixture.path}/$role.hv');
      final password = Uint8List.fromList(
        utf8.encode('synthetic padding probe $role'),
      );
      final key = Uint8List.fromList([7]);
      final first = Uint8List.fromList(utf8.encode('first $role'));
      final second = Uint8List.fromList(utf8.encode('second $role'));
      try {
        if (creating) {
          require(
            FileSystemEntity.typeSync(file.path, followLinks: false) ==
                FileSystemEntityType.notFound,
            'existing fixture payload refused',
          );
          final space = hv.HvSpace.create(
            path: file.path,
            password: password,
            padding: defaultPadding ? null : hv.PaddingPreset.none,
          );
          try {
            space.commit([
              hv.HvWriteOpPut(namespace: 230, key: key, value: first),
            ]);
            require(
              same(space.get(230, key), first),
              'create readback differs',
            );
          } finally {
            space.close();
          }
          if (defaultPadding) {
            require(
              file.lengthSync() >= 1024 * 1024 + 4096 &&
                  (file.lengthSync() - 4096) % (1024 * 1024) == 0,
              'ordinary hidden padding grid changed',
            );
          } else {
            require(
              file.lengthSync() < 128 * 1024,
              'initial no-padding file unexpectedly large',
            );
          }
          rows.add({'role': role, 'bytes': file.lengthSync()});
        } else {
          require(
            FileSystemEntity.typeSync(file.path, followLinks: false) ==
                FileSystemEntityType.file,
            'regular fixture payload required',
          );
          final before = file.readAsBytesSync();
          final wrong = Uint8List.fromList(
            utf8.encode('wrong synthetic password'),
          );
          var refused = false;
          try {
            final unexpected = hv.HvSpace.open(
              path: file.path,
              password: wrong,
            );
            unexpected.cancelDeferredVacuum();
            unexpected.close();
          } on hv.HvException catch (error) {
            refused = error.kind == 'AuthFailed';
          } finally {
            wrong.fillRange(0, wrong.length, 0);
          }
          require(
            refused && same(file.readAsBytesSync(), before),
            'wrong password changed fixture',
          );
          final space = hv.HvSpace.open(path: file.path, password: password);
          space.cancelDeferredVacuum();
          try {
            require(same(space.get(230, key), first), 'cold readback differs');
            // Deliberately no session-only setPaddingPolicy override here.
            space.commit([
              hv.HvWriteOpPut(namespace: 230, key: key, value: second),
            ]);
            require(
              same(space.get(230, key), second),
              'second write readback differs',
            );
          } finally {
            space.close();
          }
          final growth = file.lengthSync() - before.length;
          if (defaultPadding) {
            require(
              growth >= 1024 * 1024 &&
                  (file.lengthSync() - 4096) % (1024 * 1024) == 0,
              'ordinary hidden padding lost after cold open',
            );
          } else {
            require(
              growth >= 0 && growth <= 64 * 1024,
              'persisted no-padding policy not retained',
            );
          }
          rows.add({
            'role': role,
            'before': before.length,
            'after': file.lengthSync(),
            'growth': growth,
          });
        }
      } finally {
        password.fillRange(0, password.length, 0);
      }
    }
    stdout.writeln(jsonEncode({'success': true, 'stage': mode, 'roles': rows}));
  } catch (error) {
    stdout.writeln(
      jsonEncode({
        'success': false,
        'stage': stage,
        'errorType': error.runtimeType.toString(),
      }),
    );
    exitCode = 1;
  }
}
