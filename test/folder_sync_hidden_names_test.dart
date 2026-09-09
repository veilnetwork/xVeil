// A name the mirror does not carry is not a name that was deleted.
//
// The scanner has always skipped hidden entries, OS junk and our own
// half-download suffix. The writer and the cloud listing did not: a cloud
// `.notes.txt` was downloaded, written, recorded in base — and missed by the
// very next scan, which reads as "deleted here" and propagates a delete of the
// cloud copy (report24 XV24-03). Nobody has to attack anything; one dotfile in
// a shared folder is enough.

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/folder_sync.dart';

void main() {
  group('the mirror name policy', () {
    test('hidden entries, junk and our own debris are not carried', () {
      expect(folderMirrorSkipsName('.notes.txt'), isTrue);
      expect(folderMirrorSkipsName('.git'), isTrue);
      expect(folderMirrorSkipsName('.DS_Store'), isTrue);
      expect(folderMirrorSkipsName('a.txt$kPartialSuffix'), isTrue);
      expect(folderMirrorSkipsName('notes.txt'), isFalse);
      expect(folderMirrorSkipsName('report.2026.pdf'), isFalse);
    });

    test('any component decides it, not just the last', () {
      expect(folderMirrorSkipsPath('.git/config'), isTrue);
      expect(folderMirrorSkipsPath('docs/.hidden/file.txt'), isTrue);
      expect(folderMirrorSkipsPath('docs/notes.txt'), isFalse);
    });
  });

  group('the plan never deletes what it never carries', () {
    test('a base row for a hidden file does not become a remote delete', () {
      // The shape an older build left behind: the download wrote it and base
      // remembers it, while the scan cannot see it. Before the fix this was a
      // deleteRemote every pass.
      final actions = planFolderSync(
        base: const [
          SyncedFile(
            path: '.notes.txt',
            contentId: 'cid-1',
            size: 3,
            localModifiedAtMs: 1000,
          ),
        ],
        local: const [],
        remote: const [
          RemoteFile(
            path: '.notes.txt',
            itemId: 'item-1',
            contentId: 'cid-1',
            size: 3,
            modifiedAtMs: 1000,
          ),
        ],
        deletePropagates: true,
      );

      expect(
        actions.actions.where((a) => a.kind == SyncActionKind.deleteRemote),
        isEmpty,
        reason: 'a file the scanner cannot see was never deleted by anyone',
      );
      expect(actions.actions, isEmpty);
    });

    test('an ordinary file still deletes when it is really gone', () {
      // The control: a rule that skipped everything would pass the test above
      // and break deletion entirely.
      final actions = planFolderSync(
        base: const [
          SyncedFile(
            path: 'notes.txt',
            contentId: 'cid-1',
            size: 3,
            localModifiedAtMs: 1000,
          ),
        ],
        local: const [],
        remote: const [
          RemoteFile(
            path: 'notes.txt',
            itemId: 'item-1',
            contentId: 'cid-1',
            size: 3,
            modifiedAtMs: 1000,
          ),
        ],
        deletePropagates: true,
      );

      expect(
        actions.actions.map((a) => a.kind),
        contains(SyncActionKind.deleteRemote),
      );
    });
  });
}
