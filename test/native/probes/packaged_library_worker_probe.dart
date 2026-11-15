// Compile this Flutter-free probe to an executable, then place the freshly
// built veilclient DLL/shared library beside it. Run from an unrelated working
// directory. A VM/isolate has its own native handle cache; loading in the
// parent must not be required for the storage worker's first ABI lookup.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:xveil/data/native_libs.dart';

const _base = 'veilclient_ffi';
const _symbol = 'veil_abi_contract_hash';

Future<void> main(List<String> args) async {
  if (args.length == 1 && args.single == '--missing-bundle') {
    final found = await Isolate.run(
      () => processLibFor(_base).providesSymbol(_symbol),
    );
    if (found) throw StateError('loaded DLL outside the packaged candidates');
    stdout.writeln(jsonEncode({'missing_bundle_refused': true}));
    return;
  }
  if (args.isNotEmpty) throw ArgumentError('unexpected probe argument');
  final processHasSymbol = DynamicLibrary.process().providesSymbol(_symbol);
  final beforePreload = await Isolate.run(
    () => processLibFor(_base).providesSymbol(_symbol),
  );
  if (!beforePreload) throw StateError('fresh worker cannot resolve ABI');
  if (!loadNativeLib(_base)) throw StateError('packaged preload failed');
  final afterPreload = await Isolate.run(
    () => processLibFor(_base).providesSymbol(_symbol),
  );
  if (!afterPreload) throw StateError('second worker cannot resolve ABI');
  if (Platform.isWindows && processHasSymbol) {
    throw StateError('probe did not isolate DLL exports from executable');
  }
  stdout.writeln(
    jsonEncode({
      'fresh_worker': beforePreload,
      'worker_after_parent_preload': afterPreload,
      'process_scope_had_symbol': processHasSymbol,
    }),
  );
}
