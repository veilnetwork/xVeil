import unittest

from file_transfer_snapshot import snapshot_transfers


class FileSnapshotTests(unittest.TestCase):
    def snapshot(self, progress, chunks):
        return snapshot_transfers(progress, chunks, [b'abcdef', b'uvwxyz'],
                                  [0, 0], [0, 0], [{}, {}], chunk_bytes=3)

    def test_late_callback_cannot_change_frozen_counts_or_file_gate(self):
        progress = [{'queued': 6}, {'queued': 6}]
        chunks = [{0: b'uvw'}, {0: b'abc', 1: b'def'}]
        frozen = self.snapshot(progress, chunks)
        chunks[0][1] = b'xyz'
        progress[0].update(received=6, hash_matches=True)
        self.assertEqual(frozen['file_results'][0]['received'], 3)
        self.assertEqual(frozen['file_results'][0]['missing_chunks'], 1)
        self.assertEqual(frozen['file_results'][0]['missing_indices'], [1])
        self.assertFalse(frozen['file_results'][0]['hash_matches'])
        self.assertTrue(self.snapshot(progress, chunks)['file_results'][0]['hash_matches'])

    def test_hash_uses_frozen_bytes_instead_of_a_cached_success(self):
        chunks = [{0: b'uvw', 1: b'bad'}, {0: b'abc', 1: b'def'}]
        frozen = self.snapshot([{'hash_matches': True}, {}], chunks)
        self.assertFalse(frozen['file_results'][0]['hash_matches'])
        self.assertTrue(frozen['file_results'][1]['hash_matches'])

    def test_failure_counters_are_detached_from_late_callbacks(self):
        failures = [{}, {'7': 1}]
        errors, duplicates = [0, 1], [2, 0]
        frozen = snapshot_transfers([{}, {}], [{}, {}], [b'abcdef', b'uvwxyz'],
                                    errors, duplicates, failures, chunk_bytes=3)
        errors[0] = 10
        duplicates[1] = 10
        failures[1]['7'] = 10
        self.assertEqual(frozen['file_auth_errors'], [0, 1])
        self.assertEqual(frozen['file_duplicates'], [2, 0])
        self.assertEqual(frozen['file_async_send_failures'], [{}, {'7': 1}])


if __name__ == '__main__':
    unittest.main()
