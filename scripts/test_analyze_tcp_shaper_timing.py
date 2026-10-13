import copy
import unittest
from analyze_tcp_shaper_timing import analyze


SUMMARY = {'loopback_only': True, 'session_transport': 'obfs4-tcp',
           'duration_seconds': 100, 'stand_start_monotonic_us': 1000000}
ROW = {'direction': 0, 'link': 17, 'connection': 99, 'bytes': 1280,
       'oldest_byte_arrived_at': 21.01, 'read_at': 21.1,
       'at': 21.13, 'ready': 21.14, 'write_at': 21.15, 'sent_at': 21.16,
       'reader_arrival_unknown_bytes': 0}


def capture(rows):
    return {'startat': 1, 'events': len(rows), 'rows': rows}


class ShaperTimingTests(unittest.TestCase):
    def test_separates_buffering_from_reservation_and_drain(self):
        r = analyze(SUMMARY, capture([ROW]), 20, 21)
        spans = r['directions'][0]['spans']
        for key, expected in [('reader_arrival_to_read', 90), ('read_to_reservation', 30),
                              ('reservation_to_ready', 10), ('ready_to_write', 10),
                              ('write_to_drain', 10), ('reader_arrival_to_write', 140)]:
            self.assertEqual(spans[key]['max_ms'], expected)
        self.assertNotIn("'connection':", str(r))
        self.assertNotIn("'link':", str(r))

    def test_unknown_arrival_and_unfinished_write_are_unknown(self):
        row = dict(ROW, reader_arrival_unknown_bytes=1)
        del row['sent_at']
        r = analyze(SUMMARY, capture([row]), 20, 21)['directions'][0]['spans']
        self.assertIsNone(r['reader_arrival_to_read']['max_ms'])
        self.assertEqual(r['reader_arrival_to_read']['unknown_chunks'], 1)
        self.assertIsNone(r['write_to_drain']['max_ms'])
        self.assertEqual(r['reservation_to_ready']['max_ms'], 10)

    def test_window_uses_read_not_later_reservation(self):
        row = dict(ROW, read_at=21.9, at=22.1, ready=22.2, write_at=22.3, sent_at=22.4)
        r = analyze(SUMMARY, capture([row]), 20, 21)
        self.assertEqual(r['directions'][0]['chunks'], 1)

    def test_evicted_rows_and_empty_direction_are_explicit(self):
        c = dict(capture([ROW]), events=9)
        r = analyze(SUMMARY, c, 20, 21)
        self.assertEqual(r['evicted_chunks'], 8)
        self.assertEqual(r['observed_read_seconds'], [20.1, 20.1])
        self.assertIsNone(r['directions'][1]['spans']['ready_to_write']['max_ms'])

    def test_scope_is_recorded_without_reclassifying_connections(self):
        r = analyze(dict(SUMMARY, shaper_scope='per-target'), capture([ROW]), 20, 21)
        self.assertEqual(r['scope'], 'per-target')
        self.assertTrue(r['capacity_shared_across_connections'])
        with self.assertRaises(ValueError):
            analyze(dict(SUMMARY, shaper_scope='per-media'), capture([ROW]), 20, 21)

    def test_invalid_clocks_and_stage_order_rejected(self):
        for row in [dict(ROW, read_at=5000), dict(ROW, ready=21.0), dict(ROW, at=float('nan'))]:
            with self.assertRaises(ValueError): analyze(SUMMARY, capture([row]), 20, 21)
        c = copy.deepcopy(capture([ROW]))
        c['startat'] = 2
        with self.assertRaises(ValueError): analyze(SUMMARY, c, 20, 21)

    def test_foreign_fixture_and_invalid_windows_rejected(self):
        for summary in [dict(SUMMARY, loopback_only=False), dict(SUMMARY, session_transport='quic')]:
            with self.assertRaises(ValueError): analyze(summary, capture([ROW]))
        for a, b in [(-1, 25), (25, 25), (20, 101)]:
            with self.assertRaises(ValueError): analyze(SUMMARY, capture([ROW]), a, b)


if __name__ == '__main__':
    unittest.main()
