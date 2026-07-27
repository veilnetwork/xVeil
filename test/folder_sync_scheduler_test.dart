import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/folder_sync.dart';
import 'package:xveil/state/folder_sync_scheduler.dart';

const _pair = FolderSyncPair(id: 'p1', localPath: '/local');

void main() {
  late List<String> ran;
  late StreamController<void> events;
  late FolderSyncScheduler scheduler;
  Completer<void>? gate;

  setUp(() {
    ran = [];
    gate = null;
    events = StreamController<void>.broadcast();
  });
  tearDown(() {
    scheduler.dispose();
    events.close();
  });

  FolderSyncScheduler build({
    Duration quiet = const Duration(milliseconds: 40),
    Duration sweep = const Duration(seconds: 30),
  }) => scheduler = FolderSyncScheduler((pair) async {
    ran.add(pair.id);
    final held = gate;
    if (held != null) await held.future;
  }, quiet, sweep);

  test('a burst of folder events becomes exactly one pass', () async {
    // A save, an unpack, and our OWN downloads all arrive as a stream of
    // events. Reacting to each would have the mirror chase its own tail.
    build().watch(_pair, events.stream);

    for (var i = 0; i < 20; i++) {
      events.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(ran, ['p1']);
  });

  test('quiet is measured from the LAST event, not the first', () async {
    build().watch(_pair, events.stream);

    events.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(ran, isEmpty, reason: 'the folder is still busy');
    events.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(ran, isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(ran, ['p1']);
  });

  test('events during a pass cause ONE follow-up, not one per event', () async {
    build().watch(_pair, events.stream);
    gate = Completer<void>();

    events.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(ran, ['p1'], reason: 'the first pass is now in flight');

    for (var i = 0; i < 10; i++) {
      events.add(null);
    }
    gate!.complete();
    gate = null;
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(ran, ['p1', 'p1']);
  });

  test('the sweep never starts a second pass on top of a running one', () async {
    // The quiet period collapses a burst of EVENTS on its own, so it is the
    // sweep — which deliberately does not wait for quiet — that can arrive
    // mid-pass. Two passes over one folder would each read a base the other is
    // about to rewrite. Verified by breaking it: without the guard this runs
    // once per sweep tick.
    build(sweep: const Duration(milliseconds: 30)).watch(_pair, events.stream);
    gate = Completer<void>();

    // ~6 sweep ticks land while the pass is held. Exactly one pass exists.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(ran, ['p1'], reason: 'one pass in flight, sweeps piling up behind');

    gate!.complete();
    gate = null;
    // Nothing is asserted about the rate AFTER release: at a 30 ms sweep the
    // ticks are supposed to keep coming, and pinning a number here would be
    // measuring the test's own timings rather than the guard.
  });

  test('a remote change triggers a pass with nothing local happening',
      () async {
    build().watch(_pair, events.stream);

    scheduler.noteRemoteChange();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(ran, ['p1']);
  });

  test('the periodic sweep runs even when nothing at all happens', () async {
    // The signal that matters most is the one that never arrives: a watcher
    // that died, or a cloud change this device was not told about.
    build(sweep: const Duration(milliseconds: 60)).watch(_pair, events.stream);

    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(ran.length, greaterThanOrEqualTo(2));
  });

  test('a dead watcher does not stop the pair from syncing', () async {
    build(sweep: const Duration(milliseconds: 60)).watch(_pair, events.stream);

    events.addError(StateError('watcher died'));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      ran,
      isNotEmpty,
      reason: 'the sweep is what keeps a pair alive after its watcher fails',
    );
  });

  test('unwatching stops everything for that pair', () async {
    build(sweep: const Duration(milliseconds: 40)).watch(_pair, events.stream);
    scheduler.unwatch(_pair.id);

    events.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(ran, isEmpty);
  });
}
