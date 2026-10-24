import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/call_log.dart';
import 'package:xveil/state/call_log.dart';
import 'package:xveil/state/call_log_sync.dart';

CallLogEntry entry(String id, {int time = 1000, int duration = 75}) =>
    CallLogEntry(
      id: id,
      peerHex: 'fixture-peer',
      outgoing: false,
      video: false,
      outcome: CallLogOutcome.completed,
      atMs: time,
      durationSec: duration,
    );

Future<HiddenVolumeStorage> open(FakeKvLogStore kv) async {
  final s = HiddenVolumeStorage(
    ({required password, required bool create}) => kv,
  );
  await s.open(password: 'fixture', createIfMissing: true);
  return s;
}

class RefusingStore extends FakeKvLogStore {
  bool refuse = false;
  @override
  int commit(List<KvLogOp> ops) {
    if (refuse && ops.any((op) => op is AppendLogOp)) {
      throw StateError('refused');
    }
    return super.commit(ops);
  }
}

void main() {
  test(
    'local commit and publication intent survive reopening together',
    () async {
      final kv = FakeKvLogStore();
      final s = await open(kv);
      await CallLogStore(s).add(entry('local'));
      await CallLogStore(s).addMirrored(entry('mirror'));
      final reopened = await open(kv);
      expect((await reopened.pendingCallLogSync()).single.entry.id, 'local');
      expect((await reopened.callLogEntries()).length, 2);
    },
  );

  test('a refused append leaves neither row nor publication intent', () async {
    final kv = RefusingStore();
    final s = await open(kv);
    kv.refuse = true;
    await expectLater(CallLogStore(s).add(entry('local')), throwsStateError);
    expect(await s.callLogEntries(), isEmpty);
    expect(await s.pendingCallLogSync(), isEmpty);
  });

  test(
    'an aged-out final revision retains its publication obligation',
    () async {
      final kv = FakeKvLogStore();
      final s = await open(kv);
      await s.appendCallLogEntry(entry('old', time: 1000, duration: 0), cap: 2);
      await s.appendCallLogEntry(entry('one', time: 2000), cap: 2);
      await s.appendCallLogEntry(entry('two', time: 3000), cap: 2);
      await s.appendCallLogEntry(
        entry('old', time: 500),
        cap: 2,
        queueForSync: true,
      );
      expect((await s.callLogEntries()).map((e) => e.id), ['two', 'one']);
      // The bridge repairs the displaced row from its effective device log.
      // The final result itself is older than the visible retained window.
      final reopened = await open(kv);
      final pending = (await reopened.pendingCallLogSync()).single;
      expect(pending.entry.id, 'old');
      expect(pending.entry.durationSec, 75);
    },
  );

  test(
    'acknowledging an old revision cannot erase a newer local result',
    () async {
      final s = await open(FakeKvLogStore());
      final store = CallLogStore(s);
      await store.add(entry('same', duration: 1));
      final old = (await s.pendingCallLogSync()).single;
      await store.add(entry('same', duration: 75));
      expect(await s.acknowledgeCallLogSync(old), false);
      final current = (await s.pendingCallLogSync()).single;
      expect(current.entry.durationSec, 75);
      expect(await s.acknowledgeCallLogSync(current), true);
      expect(await s.pendingCallLogSync(), isEmpty);
    },
  );

  test('a corrupt publication record is reported and retained', () async {
    final kv = FakeKvLogStore();
    final s = await open(kv);
    await CallLogStore(s).add(entry('local'));
    final key = kv
        .kvKeys(Ns.settings)
        .singleWhere((k) => utf8.decode(k).startsWith('call.sync.pending.v1:'));
    kv.commit([PutOp(Ns.settings, key, utf8.encode('{bad'))]);
    await expectLater(s.pendingCallLogSync(), throwsStateError);
    expect(kv.get(Ns.settings, key), isNotNull);
  });

  test(
    'erasing the identity also erases its publication obligations',
    () async {
      final s = await open(FakeKvLogStore());
      await CallLogStore(s).add(entry('erase'));
      await s.eraseSpace();
      expect(await s.pendingCallLogSync(), isEmpty);
    },
  );

  group('publisher', () {
    late HiddenVolumeStorage s;
    late ErrorJournal journal;
    late List<CallLogEntry> published;
    late List<CallLogEntry> posts;
    late bool linked;
    late Future<bool> Function(CallLogEntry) post;
    CallLogPublisher publisher({Duration? retryEvery}) => CallLogPublisher(
      storage: s,
      isLinked: () async => linked,
      loadPublished: () async => published,
      post: (e) => post(e),
      reconcile: (_) async {},
      journal: journal,
      retryEvery: retryEvery ?? const Duration(seconds: 30),
    );
    setUp(() async {
      s = await open(FakeKvLogStore());
      journal = ErrorJournal();
      published = [];
      posts = [];
      linked = true;
      post = (e) async {
        posts.add(e);
        published.add(e);
        return true;
      };
    });

    test('idle retry does not repeatedly read the whole group', () async {
      var reads = 0;
      final p = CallLogPublisher(
        storage: s,
        isLinked: () async => true,
        loadPublished: () async {
          reads++;
          return [];
        },
        post: (e) => post(e),
        reconcile: (_) async {},
      );
      addTearDown(p.close);
      expect(await p.flush(), true);
      expect(await p.flush(), true);
      expect(reads, 1);
    });

    test(
      'boot migrates a visible old local result missing from the group',
      () async {
        await s.appendCallLogEntry(entry('legacy'), cap: 200);
        final p = publisher();
        addTearDown(p.close);
        expect(await p.flush(), true);
        expect(posts.single.id, 'legacy');
        expect(await s.pendingCallLogSync(), isEmpty);
      },
    );

    test(
      'compaction of an old group result does not replay history every boot',
      () async {
        await s.appendCallLogEntry(entry('legacy'), cap: 200);
        final p = publisher();
        expect(await p.flush(), true);
        await p.close();
        expect(posts.length, 1);
        published.clear();
        final restarted = publisher();
        addTearDown(restarted.close);
        expect(await restarted.flush(), true);
        expect(posts.length, 1);
      },
    );

    test(
      'a committed group result is not posted again after restart',
      () async {
        await CallLogStore(s).add(entry('already-posted', time: 9999999999999));
        published = [entry('already-posted', time: 9999999999999)];
        final p = publisher();
        expect(await p.flush(), true);
        await p.close();
        final restarted = publisher();
        addTearDown(restarted.close);
        expect(await restarted.flush(), true);
        expect(posts, isEmpty);
        expect(await s.pendingCallLogSync(), isEmpty);
      },
    );

    test(
      'failed publication stays pending and the next retry publishes it',
      () async {
        await CallLogStore(s).add(entry('retry'));
        post = (_) async => false;
        final p = publisher();
        addTearDown(p.close);
        expect(await p.flush(), false);
        expect((await s.pendingCallLogSync()).length, 1);
        post = (e) async {
          posts.add(e);
          return true;
        };
        expect(await p.flush(), true);
        expect(posts.single.id, 'retry');
        expect(await s.pendingCallLogSync(), isEmpty);
      },
    );

    test('one failing page does not starve other pending calls', () async {
      for (var i = 0; i < 70; i++) {
        await s.queueCallLogSync(entry('call-$i'));
      }
      final first = (await s.pendingCallLogSync(limit: 1)).single.entry.id;
      post = (e) async {
        posts.add(e);
        return e.id != first;
      };
      final p = publisher();
      addTearDown(p.close);
      expect(await p.flush(), false);
      expect(posts.length, 70);
      expect((await s.pendingCallLogSync()).single.entry.id, first);
    });

    test(
      'retry resumes past eight failed pages instead of starving later calls',
      () async {
        for (var i = 0; i < 520; i++) {
          await s.queueCallLogSync(entry('many-$i'));
        }
        final failed = (await s.pendingCallLogSync(
          limit: 512,
        )).map((e) => e.entry.id).toSet();
        post = (e) async {
          posts.add(e);
          return !failed.contains(e.id);
        };
        final p = publisher();
        addTearDown(p.close);
        expect(await p.flush(), false);
        expect(posts.length, 512);
        await p.flush();
        expect(posts.length, 520);
        expect((await s.pendingCallLogSync(limit: 600)).length, 512);
      },
    );

    test(
      'a newer local result while posting is retried before going idle',
      () async {
        final store = CallLogStore(s);
        await store.add(entry('race', duration: 1));
        final started = Completer<void>(), release = Completer<void>();
        post = (e) async {
          posts.add(e);
          if (e.durationSec == 1) {
            started.complete();
            await release.future;
          }
          return true;
        };
        final p = publisher();
        addTearDown(p.close);
        final work = p.flush();
        await started.future;
        await store.add(entry('race', duration: 75));
        p.nudge();
        release.complete();
        await work;
        expect(posts.map((e) => e.durationSec), [1, 75]);
        expect(await s.pendingCallLogSync(), isEmpty);
      },
    );

    test(
      'an unlinked identity keeps bounded history without growing an outbox',
      () async {
        linked = false;
        await CallLogStore(s).add(entry('unlinked'));
        final p = publisher();
        addTearDown(p.close);
        expect(await p.flush(), true);
        expect(posts, isEmpty);
        expect(await s.pendingCallLogSync(), isEmpty);
        expect((await s.callLogEntries()).single.id, 'unlinked');
        linked = true;
        expect(await p.flush(), true);
        expect(posts.single.id, 'unlinked');
      },
    );

    test(
      'exception text cannot expose call data in either diagnostics view',
      () async {
        await CallLogStore(s).add(entry('private-call'));
        post = (_) async =>
            throw StateError('secret-peer private-call /private/file');
        final p = publisher();
        addTearDown(p.close);
        expect(await p.flush(), false);
        expect(journal.entries.single.kind, 'call-history-sync');
        expect(journal.entries.single.message, isNot(contains('private-call')));
        expect(journal.entries.single.message, isNot(contains('secret-peer')));
        expect(await s.pendingCallLogSync(), hasLength(1));
      },
    );

    test(
      'close waits for admitted publication and stops retries and admission',
      () async {
        await CallLogStore(s).add(entry('close'));
        final started = Completer<void>(), release = Completer<void>();
        post = (e) async {
          posts.add(e);
          started.complete();
          await release.future;
          return true;
        };
        final p = publisher(retryEvery: const Duration(milliseconds: 20));
        p.start();
        await started.future;
        var closed = false;
        final close = p.close().then((_) => closed = true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(closed, false);
        release.complete();
        await close;
        expect(await s.pendingCallLogSync(), isEmpty);
        await CallLogStore(s).add(entry('after-close'));
        p.nudge();
        expect(await p.flush(), false);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(posts.length, 1);
        expect((await s.pendingCallLogSync()).single.entry.id, 'after-close');
      },
    );
  });
}
