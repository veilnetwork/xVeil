import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/runtime_dir_sweep.dart';
import 'package:xveil/data/veil_stack.dart';

/// This exercises code that DELETES, recursively.
///
/// Every path in this file is built from [base], a directory created by
/// `createTemp` in `setUp` and removed in `tearDown`. `sweepStaleRuntimeDirs`
/// is never handed anything else, and it only ever lists that one directory
/// and removes direct children of it — so a mistake in this file cannot reach
/// past it even if every assertion below is wrong.
void main() {
  late Directory base;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('xveil-sweep-test');
  });

  tearDown(() async {
    if (base.existsSync()) await base.delete(recursive: true);
  });

  /// One of OUR runtime directories, marker and all, exactly as
  /// `claimRuntimeDirUnder` leaves it.
  Future<Directory> ours(String name) async {
    final dir = Directory('${base.path}/$name');
    await dir.create();
    await File('${dir.path}/$kRuntimeDirMarker').writeAsString('mine');
    await File('${dir.path}/app.sock').writeAsString('socket');
    await File('${dir.path}/obfs4_psk.b64').writeAsString('PSK');
    return dir;
  }

  Future<int> sweep({int selfPid = 1}) => sweepStaleRuntimeDirs(
    base.path,
    selfPid: selfPid,
    singleInstanceHost: true,
  );

  test('a collision name is reaped, not skipped forever', () async {
    // `claimRuntimeDirUnder` appends `-<attempt>` when the pid-named directory
    // is taken. The sweeper parsed the whole tail as an integer, so a
    // collision name gave null — and null meant skip, on this launch and on
    // every launch after it. The sockets and the obfuscation key stayed on
    // disk permanently: a standing record that an identity ran here (audit
    // XV-14).
    final plain = await ours('xveil-rt-4321');
    final collided = await ours('xveil-rt-4321-1');
    final collidedAgain = await ours('xveil-rt-4321-17');

    expect(await sweep(), 3);
    expect(plain.existsSync(), isFalse);
    expect(
      collided.existsSync(),
      isFalse,
      reason: 'the collision name was skipped, and would be forever',
    );
    expect(collidedAgain.existsSync(), isFalse);
  });

  test('a directory wearing our name without our marker is left alone',
      () async {
    // The other half, and the one that matters more: this code deletes
    // recursively, and matching on the NAME alone is how a sweeper becomes a
    // weapon. The base can be a shared /tmp or an operator's
    // XVEIL_RUNTIME_DIR, so anything able to create `xveil-rt-<dead pid>`
    // there could aim the delete wherever it liked.
    final impostor = Directory('${base.path}/xveil-rt-4321');
    await impostor.create();
    final bystander = File('${impostor.path}/somebody-elses-data');
    await bystander.writeAsString('important');

    // A neighbour that is not even nearly ours, to prove the sweep is not
    // simply inert.
    final mine = await ours('xveil-rt-9999-2');
    final unrelated = Directory('${base.path}/not-ours-at-all');
    await unrelated.create();
    final unrelatedFile = File('${base.path}/loose-file');
    await unrelatedFile.writeAsString('x');

    expect(await sweep(), 1);
    expect(mine.existsSync(), isFalse, reason: 'ours goes');
    expect(
      impostor.existsSync(),
      isTrue,
      reason: 'a directory we did not create was deleted on the strength of '
          'its name',
    );
    expect(bystander.existsSync(), isTrue);
    expect(unrelated.existsSync(), isTrue);
    expect(unrelatedFile.existsSync(), isTrue);
  });

  test('our own live directory is never taken, whichever name it wears',
      () async {
    final live = await ours('xveil-rt-777');
    final liveCollided = await ours('xveil-rt-777-3');
    final dead = await ours('xveil-rt-778');

    expect(await sweep(selfPid: 777), 1);
    expect(live.existsSync(), isTrue);
    expect(
      liveCollided.existsSync(),
      isTrue,
      reason: 'a collision name for the RUNNING pid is still the running pid',
    );
    expect(dead.existsSync(), isFalse);
  });

  test('a live pid keeps its directory on a multi-instance host', () async {
    final live = await ours('xveil-rt-4242-1');
    final dead = await ours('xveil-rt-4243');
    final asked = <int>[];

    final removed = await sweepStaleRuntimeDirs(
      base.path,
      selfPid: 1,
      pidAlive: (p) async {
        asked.add(p);
        return p == 4242;
      },
    );

    expect(removed, 1);
    expect(live.existsSync(), isTrue);
    expect(dead.existsSync(), isFalse);
    expect(
      asked,
      containsAll([4242, 4243]),
      reason: 'the pid out of a collision name has to be the one asked about',
    );
  });

  test('a name that only looks like one of ours is not one of ours', () async {
    // Everything here carries the marker, so the marker cannot be what saves
    // them — the name is.
    final nonNumeric = await ours('xveil-rt-abc');
    final trailing = await ours('xveil-rt-4321-');
    final nested = await ours('xveil-rt-4321-1-2');
    final prefixed = await ours('not-xveil-rt-4321');

    expect(await sweep(), 0);
    expect(nonNumeric.existsSync(), isTrue);
    expect(trailing.existsSync(), isTrue);
    expect(nested.existsSync(), isTrue);
    expect(prefixed.existsSync(), isTrue);
  });

  test('a node working dir goes on age, and only on age', () async {
    // veil creates these, so there is no marker of ours to find inside one.
    // The evidence is the exact name plus a full day of silence.
    final stale = Directory('${base.path}/veil-deferred-abc');
    await stale.create();
    await File('${stale.path}/outbox.db').writeAsString('old');
    final busy = Directory('${base.path}/veil-deferred-def');
    await busy.create();
    await File('${busy.path}/outbox.db').writeAsString('fresh');

    // "Now" two hours on: neither is a day old yet.
    expect(
      await sweepStaleRuntimeDirs(
        base.path,
        selfPid: 1,
        singleInstanceHost: true,
        now: () => DateTime.now().add(const Duration(hours: 2)),
      ),
      0,
    );
    expect(stale.existsSync(), isTrue);
    expect(busy.existsSync(), isTrue);

    // …and two days on, with `busy` touched an hour ago, only the silent one
    // goes. `stale` keeps the timestamps it was made with, so from two days
    // out it has been quiet for two days.
    final future = DateTime.now().add(const Duration(days: 2));
    await File(
      '${busy.path}/outbox.db',
    ).setLastModified(future.subtract(const Duration(hours: 1)));

    expect(
      await sweepStaleRuntimeDirs(
        base.path,
        selfPid: 1,
        singleInstanceHost: true,
        now: () => future,
      ),
      1,
    );
    expect(stale.existsSync(), isFalse);
    expect(busy.existsSync(), isTrue);
  });

  test('an unreadable base is not an error', () async {
    expect(
      await sweepStaleRuntimeDirs(
        '${base.path}/never-created',
        selfPid: 1,
        singleInstanceHost: true,
      ),
      0,
    );
  });
}
