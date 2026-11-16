import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';

class _Fs extends ManagedFsPlatform {
  int reads = 0, flushes = 0;
  bool directory = true, owned = true, safe = true;
  bool replace = false, revoke = false, refuseFlush = false;
  @override
  ManagedPathWitness inspect(String path) => ManagedPathWitness(
    identity: ++reads > 1 && replace ? 'replacement' : 'original',
    directory: directory,
    ownerOnly: true,
    ownedByCurrentUser: owned,
    safeAncestor: safe && !(reads > 1 && revoke),
  );
  @override
  void syncDirectory(String path) {
    flushes++;
    if (refuseFlush) throw const ManagedFsFailure(ManagedFsFailureKind.io);
  }
}

void main() {
  for (final refusal in [
    'file',
    'owner',
    'ancestor',
    'replacement',
    'revoked',
    'flush',
  ]) {
    test(
      'source directory barrier refuses $refusal',
      () {
        final fs = _Fs();
        switch (refusal) {
          case 'file':
            fs.directory = false;
          case 'owner':
            fs.owned = false;
          case 'ancestor':
            fs.safe = false;
          case 'replacement':
            fs.replace = true;
          case 'revoked':
            fs.revoke = true;
          case 'flush':
            fs.refuseFlush = true;
        }
        expect(
          () => fs.syncSourceDirectory('/synthetic'),
          throwsA(isA<ManagedFsFailure>()),
        );
        expect(
          fs.flushes,
          ['file', 'owner', 'ancestor'].contains(refusal) ? 0 : 1,
        );
      },
      skip: Platform.isWindows
          ? 'POSIX dispatch model; Windows has a native probe'
          : false,
    );
  }
  test(
    'stable source barrier retains the actual directory flush',
    () {
      final fs = _Fs();
      fs.syncSourceDirectory('/synthetic');
      expect(fs.flushes, 1);
      expect(fs.reads, 2);
    },
    skip: Platform.isWindows
        ? 'POSIX dispatch model; Windows has a native probe'
        : false,
  );
}
