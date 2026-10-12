import json
import unittest
from analyze_relay_cell_timing import analyze


def row(stage, at, extra='', seq=50, size=100):
    marker = 'media.cell.sample' if stage == 'received' else 'ipc.rt_trace.sealed_sample'
    return (f'{marker} epoch=0123456789abcdef seq={seq} bytes={size} '
            f'stage={stage} at_ms={at} dst=deadbeef hop=abcdefab {extra}')


class TimingAttributionTest(unittest.TestCase):
    def test_receiver_ages_overlap_and_are_not_added(self):
        result = analyze({'loopback_only': True}, [row('relay_queued', 1000),
            row('received', 1100, 'delivery_daemon_age_us=20000 delivery_sdk_age_us=5000')])
        spans = result['spans']
        self.assertEqual(spans['origin_enqueue_to_receiver_ipc_encode']['max_ms'], 80)
        self.assertEqual(spans['receiver_ipc_encode_to_sdk_read']['max_ms'], 15)
        self.assertNotIn('0123456789abcdef', json.dumps(result))
        self.assertNotIn('deadbeef', json.dumps(result))

    def test_fanout_duplicate_is_not_arbitrarily_matched(self):
        result = analyze({'loopback_only': True}, [row('relay_queued', 1000),
            row('relay_queued', 1001), row('received', 1100),
            row('relay_queued', 1200, seq=100), row('received', 1210, seq=100)])
        self.assertEqual(result['ambiguous_cells_skipped'], 1)
        self.assertEqual(result['spans']['relay_queued_to_received']['count'], 1)
        self.assertEqual(result['spans']['relay_queued_to_received']['max_ms'], 10)

    def test_missing_receiver_age_is_unknown_and_clock_contradiction_is_rejected(self):
        result = analyze({'loopback_only': True}, [row('relay_queued', 1000), row('received', 1100)])
        self.assertNotIn('origin_enqueue_to_receiver_ipc_encode', result['spans'])
        with self.assertRaises(ValueError):
            analyze({'loopback_only': True}, [row('relay_queued', 1200), row('received', 1100)])
        with self.assertRaises(ValueError):
            analyze({'loopback_only': True}, [row('received', 1100,
                'delivery_daemon_age_us=100 delivery_sdk_age_us=200')])

    def test_requires_same_process_fixture_and_does_not_zero_inverted_observations(self):
        with self.assertRaises(ValueError):
            analyze({'loopback_only': False}, [row('relay_queued', 1000), row('received', 1100)])
        result = analyze({'loopback_only': True}, [row('socket_written', 1001),
            row('daemon_read', 1000), row('handler_enter', 1002)])
        self.assertEqual(result['inverted_observations_skipped'], 1)
        self.assertNotIn('socket_written_to_daemon_read', result['spans'])


if __name__ == '__main__':
    unittest.main()
