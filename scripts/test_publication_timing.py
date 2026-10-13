import unittest
from publication_timing import publication_timing


class PublicationTimingTests(unittest.TestCase):
    def test_monotonic_markers_do_not_inherit_wall_slew(self):
        clocks = [{'monotonic_us': 1000000, 'unix_us': 9000000},
                  {'monotonic_us': 361000000, 'unix_us': 368961000}]
        log = 'node.sovereign_identity.replication reason=warmup wall_unix_ms=184691 monotonic_us=176710123'
        r = publication_timing(log, 1000000, 360, clocks)
        self.assertEqual(r['events'][0]['at_seconds'], 175.710123)
        self.assertEqual(r['clock_offset_change_us'], -39000)
        self.assertEqual(r['monotonic_events'], 1)

    def test_legacy_and_new_startup_rows_keep_separate_precision(self):
        log = ('node.sovereign_identity.replication reason=topology wall_unix_ms=4745\n'
               'node.sovereign_identity.replication reason=warmup wall_unix_ms=94710 monotonic_us=86710123')
        r = publication_timing(log, 1000000, 360, [{'monotonic_us': 1000000, 'unix_us': 9000000}])
        self.assertEqual([e['clock'] for e in r['events']], ['legacy_wall_mapping', 'same_host_monotonic'])
        self.assertEqual([e['at_seconds'] for e in r['events']], [-4.255, 85.710123])
        self.assertEqual([e['timestamp_resolution_us'] for e in r['events']], [1000, 1])

    def test_foreign_absolute_clock_origin_falls_back_explicitly(self):
        r = publication_timing('node.sovereign_identity.replication reason=warmup wall_unix_ms=94710 monotonic_us=3025486710123',
                               1000000, 360, [{'monotonic_us': 1000000, 'unix_us': 9000000}])
        self.assertEqual(r['invalid_monotonic_markers'], 1)
        self.assertEqual(r['monotonic_events'], 0)
        self.assertEqual(r['events'][0]['clock'], 'legacy_wall_mapping')

    def test_missing_clock_samples_and_missing_markers_are_unknown(self):
        r = publication_timing('node.sovereign_identity.replication reason=warmup wall_unix_ms=123', 1000000, 360, [])
        self.assertIsNone(r['events'][0]['at_seconds'])
        self.assertEqual(r['events'][0]['clock'], 'unknown')
        self.assertFalse(publication_timing('ordinary log', 1000000, 360, [])['available'])


if __name__ == '__main__':
    unittest.main()
