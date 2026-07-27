import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/folder_sync.dart';

LocalFile _local(String path, {int size = 10, int mtime = 100, String? cid}) =>
    LocalFile(
      path: path,
      size: size,
      modifiedAtMs: mtime,
      contentId: cid,
    );

RemoteFile _remote(
  String path, {
  String cid = 'cid-a',
  int size = 10,
  int mtime = 100,
}) => RemoteFile(
  path: path,
  itemId: 'item-$path',
  contentId: cid,
  size: size,
  modifiedAtMs: mtime,
);

SyncedFile _base(String path, {String cid = 'cid-a', int size = 10, int mtime = 100}) =>
    SyncedFile(
      path: path,
      contentId: cid,
      size: size,
      localModifiedAtMs: mtime,
    );

List<SyncAction> _plan({
  List<SyncedFile> base = const [],
  List<LocalFile> local = const [],
  List<RemoteFile> remote = const [],
  bool deletePropagates = true,
}) => planFolderSync(
  base: base,
  local: local,
  remote: remote,
  deletePropagates: deletePropagates,
).actions;

void main() {
  group('the two-sided cases a plain copy cannot tell apart', () {
    test('a file only the other side has is a download, not a local delete', () {
      // With no base you cannot distinguish these two; that is the entire
      // reason the base picture exists.
      expect(_plan(remote: [_remote('a.txt')]), [
        const SyncAction(SyncActionKind.download, 'a.txt'),
      ]);
    });

    test('a file only this side has is an upload', () {
      expect(_plan(local: [_local('a.txt')]), [
        const SyncAction(SyncActionKind.upload, 'a.txt'),
      ]);
    });

    test('present on both sides and unchanged since the last sync: nothing', () {
      expect(
        _plan(
          base: [_base('a.txt')],
          local: [_local('a.txt')],
          remote: [_remote('a.txt')],
        ),
        isEmpty,
      );
    });
  });

  group('one side moved', () {
    test('a local edit uploads', () {
      expect(
        _plan(
          base: [_base('a.txt')],
          local: [_local('a.txt', mtime: 200)],
          remote: [_remote('a.txt')],
        ),
        [const SyncAction(SyncActionKind.upload, 'a.txt')],
      );
    });

    test('a remote edit downloads', () {
      expect(
        _plan(
          base: [_base('a.txt')],
          local: [_local('a.txt')],
          remote: [_remote('a.txt', cid: 'cid-b')],
        ),
        [const SyncAction(SyncActionKind.download, 'a.txt')],
      );
    });

    test('a local delete removes the cloud copy when deletes propagate', () {
      expect(
        _plan(
          base: [_base('a.txt'), _base('keep.txt')],
          local: [_local('keep.txt')],
          remote: [_remote('a.txt'), _remote('keep.txt')],
        ),
        [const SyncAction(SyncActionKind.deleteRemote, 'a.txt')],
      );
    });

    test('with deletes NOT propagating, a removed file is fetched back', () {
      expect(
        _plan(
          base: [_base('a.txt'), _base('keep.txt')],
          local: [_local('keep.txt')],
          remote: [_remote('a.txt'), _remote('keep.txt')],
          deletePropagates: false,
        ),
        [const SyncAction(SyncActionKind.download, 'a.txt')],
      );
    });
  });

  group('both sides moved', () {
    test('two different edits are a conflict, never resolved silently', () {
      expect(
        _plan(
          base: [_base('a.txt')],
          local: [_local('a.txt', mtime: 200)],
          remote: [_remote('a.txt', cid: 'cid-b')],
        ),
        [const SyncAction(SyncActionKind.conflict, 'a.txt')],
      );
    });

    test('the SAME content on both sides is a coincidence, not a conflict', () {
      expect(
        _plan(
          base: [_base('a.txt')],
          local: [_local('a.txt', mtime: 200, cid: 'cid-b')],
          remote: [_remote('a.txt', cid: 'cid-b')],
        ),
        isEmpty,
      );
    });

    test('an edit outranks a delete, in both directions', () {
      // Deleting a file someone else was working on is the accident; the edit
      // is the intentional act. Resurrect rather than lose it.
      expect(
        _plan(
          base: [_base('a.txt'), _base('k.txt')],
          local: [_local('k.txt')],
          remote: [_remote('a.txt', cid: 'cid-b'), _remote('k.txt')],
        ),
        [const SyncAction(SyncActionKind.download, 'a.txt')],
      );
      expect(
        _plan(
          base: [_base('a.txt'), _base('k.txt')],
          local: [_local('a.txt', mtime: 200), _local('k.txt')],
          remote: [_remote('k.txt')],
        ),
        [const SyncAction(SyncActionKind.upload, 'a.txt')],
      );
    });

    test('deleted on both sides: simply forgotten', () {
      expect(
        _plan(
          base: [_base('a.txt'), _base('k.txt')],
          local: [_local('k.txt')],
          remote: [_remote('k.txt')],
        ),
        isEmpty,
      );
    });
  });

  group('rename', () {
    test('same content at a new path is a move, not a re-upload', () {
      final actions = _plan(
        base: [_base('old.txt', cid: 'cid-a')],
        local: [_local('new.txt', cid: 'cid-a')],
        remote: [_remote('old.txt', cid: 'cid-a')],
      );
      expect(actions, [
        const SyncAction(
          SyncActionKind.renameRemote,
          'new.txt',
          fromPath: 'old.txt',
        ),
      ]);
      expect(
        actions.single.itemId,
        'item-old.txt',
        reason: 'the move must address the EXISTING item, not mint a new one',
      );
    });

    test('without a local hash it degrades to delete + upload, not silence', () {
      // A cheap scan leaves contentId null; the result must still be correct,
      // just less clever.
      final actions = _plan(
        base: [_base('old.txt')],
        local: [_local('new.txt')],
        remote: [_remote('old.txt')],
      );
      expect(actions, containsAll(const [
        SyncAction(SyncActionKind.deleteRemote, 'old.txt'),
        SyncAction(SyncActionKind.upload, 'new.txt'),
      ]));
    });
  });

  group('a conflict the user has not answered yet', () {
    test('is left strictly alone — not re-asked, not silently resolved', () {
      // Asking again every pass is nagging; picking a side while they think is
      // the silent overwrite that asking was meant to avoid.
      final actions = planFolderSync(
        base: [_base('a.txt')],
        local: [_local('a.txt', mtime: 200)],
        remote: [_remote('a.txt', cid: 'cid-b')],
        pendingConflicts: const {'a.txt'},
      ).actions;
      expect(actions, isEmpty);
    });

    test('does not freeze its neighbours', () {
      final actions = planFolderSync(
        base: [_base('a.txt'), _base('b.txt')],
        local: [_local('a.txt', mtime: 200), _local('b.txt', mtime: 200)],
        remote: [_remote('a.txt', cid: 'cid-b'), _remote('b.txt')],
        pendingConflicts: const {'a.txt'},
      ).actions;
      expect(actions, [const SyncAction(SyncActionKind.upload, 'b.txt')]);
    });

    test('once answered, the path is planned again', () {
      final actions = planFolderSync(
        base: [_base('a.txt')],
        local: [_local('a.txt', mtime: 200)],
        remote: [_remote('a.txt', cid: 'cid-b')],
        pendingConflicts: const {},
      ).actions;
      expect(actions, [const SyncAction(SyncActionKind.conflict, 'a.txt')]);
    });

    test('a still-vanished file under a pending conflict is not deleted', () {
      // The dangerous interaction: "skip" must not read as "gone".
      final plan = planFolderSync(
        base: [
          for (var i = 0; i < 6; i++) _base('f$i.txt'),
        ],
        local: [for (var i = 0; i < 6; i++) _local('f$i.txt')],
        remote: [for (var i = 0; i < 6; i++) _remote('f$i.txt')],
        pendingConflicts: {for (var i = 0; i < 6; i++) 'f$i.txt'},
      );
      expect(plan.isRefused, isFalse);
      expect(plan.actions, isEmpty);
    });
  });

  group('a path two cloud items claim', () {
    test('is left alone rather than resolved by listing order', () {
      // The cloud lets two items share a name in one folder; a folder cannot.
      // Keeping whichever came last is how a mirror downloads an unrelated
      // file over the user's work — observed doing exactly that live.
      final plan = planFolderSync(
        base: [_base('a.txt')],
        local: [_local('a.txt', mtime: 200)],
        remote: [
          _remote('a.txt', cid: 'cid-one'),
          RemoteFile(
            path: 'a.txt',
            itemId: 'other-item',
            contentId: 'cid-two',
            size: 999,
            modifiedAtMs: 300,
          ),
        ],
      );

      expect(plan.ambiguous, {'a.txt'});
      expect(plan.actions, isEmpty);
    });

    test('its neighbours keep syncing', () {
      final plan = planFolderSync(
        base: const [],
        local: [_local('b.txt')],
        remote: [
          _remote('a.txt', cid: 'one'),
          RemoteFile(
            path: 'a.txt',
            itemId: 'other',
            contentId: 'two',
            size: 1,
            modifiedAtMs: 1,
          ),
        ],
      );

      expect(plan.ambiguous, {'a.txt'});
      expect(plan.actions, [const SyncAction(SyncActionKind.upload, 'b.txt')]);
    });
  });

  group('the mass-deletion brake', () {
    test('refuses wholesale when most of the tracked set vanished', () {
      // An unmounted drive, a permission change, a folder pointed at the wrong
      // path: all present as "everything is gone". Mirroring that observation
      // destroys the cloud copy exactly when it is needed.
      final plan = planFolderSync(
        base: [for (var i = 0; i < 10; i++) _base('f$i.txt')],
        local: [_local('f0.txt')],
        remote: [for (var i = 0; i < 10; i++) _remote('f$i.txt')],
      );
      expect(plan.isRefused, isTrue);
      expect(plan.actions, isEmpty, reason: 'a refusal is not a partial apply');
      expect(plan.refusedReason, contains('9 of 10'));
    });

    test('an ordinary tidy-up on the CLOUD side passes too', () {
      // Symmetry must not mean paranoia: deleting a couple of files in the
      // cloud is an ordinary thing to do and has to still reach the folder.
      final plan = planFolderSync(
        base: [for (var i = 0; i < 10; i++) _base('f$i.txt')],
        local: [for (var i = 0; i < 10; i++) _local('f$i.txt')],
        remote: [for (var i = 0; i < 8; i++) _remote('f$i.txt')],
      );
      expect(plan.isRefused, isFalse);
      expect(plan.actions, hasLength(2));
      expect(
        plan.actions.every((a) => a.kind == SyncActionKind.deleteLocal),
        isTrue,
      );
    });

    test('a vanished CLOUD listing is refused, and says which side', () {
      final plan = planFolderSync(
        base: [for (var i = 0; i < 10; i++) _base('f$i.txt')],
        local: [for (var i = 0; i < 10; i++) _local('f$i.txt')],
        remote: const [],
      );
      expect(plan.isRefused, isTrue);
      expect(plan.refusedReason, contains('the cloud'));
      expect(plan.actions, isEmpty);
    });

    test('an ordinary tidy-up passes', () {
      final plan = planFolderSync(
        base: [for (var i = 0; i < 10; i++) _base('f$i.txt')],
        local: [for (var i = 0; i < 8; i++) _local('f$i.txt')],
        remote: [for (var i = 0; i < 10; i++) _remote('f$i.txt')],
      );
      expect(plan.isRefused, isFalse);
      expect(plan.actions, hasLength(2));
    });

    test('a first-ever pass into an empty folder cannot trip it', () {
      // Nothing is tracked yet, so nothing can have vanished.
      final plan = planFolderSync(
        base: const [],
        local: const [],
        remote: [for (var i = 0; i < 10; i++) _remote('f$i.txt')],
      );
      expect(plan.isRefused, isFalse);
      expect(plan.actions, hasLength(10));
    });

    test('the brake is off when deletes do not propagate — nothing to lose', () {
      final plan = planFolderSync(
        base: [for (var i = 0; i < 10; i++) _base('f$i.txt')],
        local: const [],
        remote: [for (var i = 0; i < 10; i++) _remote('f$i.txt')],
        deletePropagates: false,
      );
      expect(plan.isRefused, isFalse);
      expect(plan.actions, hasLength(10));
      expect(
        plan.actions.every((a) => a.kind == SyncActionKind.download),
        isTrue,
      );
    });
  });

  group('overlapping pairs', () {
    test('identical, and either nesting, overlap', () {
      expect(folderPairsOverlap('/home/docs', '/home/docs'), isTrue);
      expect(folderPairsOverlap('/home/docs', '/home/docs/work'), isTrue);
      expect(folderPairsOverlap('/home/docs/work', '/home/docs'), isTrue);
    });

    test('a shared TEXTUAL prefix is not nesting', () {
      // The classic version of this bug: /home/docs2 is not inside /home/docs.
      expect(folderPairsOverlap('/home/docs', '/home/docs2'), isFalse);
      expect(folderPairsOverlap('/home/docs', '/home/documents'), isFalse);
    });

    test('siblings do not overlap', () {
      expect(folderPairsOverlap('/home/a', '/home/b'), isFalse);
      expect(folderPairsOverlap('/home/a/x', '/home/b/x'), isFalse);
    });

    test('trailing separators and backslashes do not change the answer', () {
      expect(folderPairsOverlap('/home/docs/', '/home/docs'), isTrue);
      expect(folderPairsOverlap(r'C:\\Users\\a', r'C:\\Users\\a\\b'), isTrue);
      expect(folderPairsOverlap(r'C:\\Users\\a', r'C:\\Users\\ab'), isFalse);
    });

    test('the filesystem root overlaps everything', () {
      expect(folderPairsOverlap('/', '/home/docs'), isTrue);
    });
  });
}
