import json
import unittest

from analyze_physical_udp_delivery import analyze


EPOCH = '1234567890abcdef'
DIGEST = 'fedcba0987654321'


def accepted(connection=7):
    return [
        f'media.source_cell_trace local_slot=0 epoch={EPOCH} seq=1 '
        'stage=budget_admit monotonic_us=1000',
        f'media.source_cell_trace local_slot=0 epoch={EPOCH} seq=1 '
        f'stage=datagram_accepted monotonic_us=1200 connection_trace_id={connection}',
    ]


def udp(stage, at, kernel=0, connection=7, size=1200, grouped=False):
    return (f'quic.udp_wire.sample stage={stage} at_ms={at} digest={DIGEST} '
            f'bytes={size} kernel_recv_ns={kernel} '
            f'kernel_grouped={str(grouped).lower()} connection_trace_id={connection}')


class PhysicalUdpDeliveryTest(unittest.TestCase):
    brackets = [{'low_ns': -40_000_000, 'high_ns': -40_000_000}] * 2

    def score(self, first, second, brackets=None):
        return analyze(first, second, self.brackets if brackets is None else brackets)

    def test_cross_clock_intervals_and_receiver_polling(self):
        first = accepted() + [udp('send', 1000), udp('receive', 1143, 1_140_000_000)]
        second = accepted() + [udp('receive', 1083, 1_080_000_000), udp('send', 1140)]
        report = self.score(first, second)
        for direction in report['directions']:
            self.assertEqual(direction['matched_datagrams'], 1)
            self.assertEqual(direction['socket_to_peer_kernel_lower_bounds_ms']['max_ms'], 39)
            self.assertEqual(direction['socket_to_peer_kernel_upper_bounds_ms']['max_ms'], 40)
            self.assertEqual(direction['peer_kernel_to_poll_upper_bounds_ms']['max_ms'], 4)
        self.assertEqual(report['endpoints'][0]['budget_to_quic_acceptance_ms']['max_ms'], .2)
        output = json.dumps(report)
        for private in [EPOCH, DIGEST, 'kernel_recv_ns', 'connection_trace_id', 'low_ns']:
            self.assertNotIn(private, output)

    def test_offset_envelope_uses_both_extremes_not_midpoint(self):
        report = self.score(accepted() + [udp('send', 1000)],
                            [udp('receive', 1083, 1_080_000_000)],
                            [{'low_ns': -50_000_000, 'high_ns': -45_000_000},
                             {'low_ns': -40_000_000, 'high_ns': -30_000_000}])
        d = report['directions'][0]
        self.assertEqual(report['wall_offset_envelope_width_ms'], 20)
        self.assertEqual(d['socket_to_peer_kernel_lower_bounds_ms']['max_ms'], 29)
        self.assertEqual(d['socket_to_peer_kernel_upper_bounds_ms']['max_ms'], 50)

    def test_negative_lower_bound_is_not_hidden(self):
        report = self.score(accepted() + [udp('send', 1000)],
                            [udp('receive', 1041, 1_040_000_000)])
        d = report['directions'][0]
        self.assertEqual(d['socket_to_peer_kernel_lower_bounds_ms']['max_ms'], -1)
        self.assertEqual(d['socket_to_peer_kernel_upper_bounds_ms']['max_ms'], 0)

    def test_startup_and_teardown_cannot_borrow_clock_brackets(self):
        first = accepted() + [udp('send', 1000)]
        second = [udp('receive', 1083, 1_080_000_000)]
        for start, end, skipped in [(900_000_000, 1_100_000_000, 0),
                                    (1_001_000_000, 1_100_000_000, 1),
                                    (900_000_000, 1_039_000_000, 1)]:
            brackets = [dict(self.brackets[0], at_host_ns=start),
                        dict(self.brackets[1], at_host_ns=end)]
            d = self.score(first, second, brackets)['directions'][0]
            self.assertEqual(d['outside_calibrated_interval_skipped'], skipped)
            self.assertEqual(d['socket_to_peer_kernel_upper_bounds_ms'] is None, bool(skipped))
        with self.assertRaises(ValueError):
            self.score(first, second, [dict(self.brackets[0], at_host_ns=1), self.brackets[1]])

    def test_ambiguous_replays_and_unmatched_are_not_loss(self):
        send = udp('send', 1000)
        receive = udp('receive', 1083, 1_080_000_000)
        for first, second in [(accepted() + [send, send], [receive]),
                              (accepted() + [send], [receive, receive])]:
            d = self.score(first, second)['directions'][0]
            self.assertEqual(d['ambiguous_samples_skipped'], 1)
            self.assertEqual(d['matched_datagrams'], 0)
        report = self.score(accepted() + [send], [])
        self.assertEqual(report['directions'][0]['unmatched_send_samples'], 1)
        self.assertTrue(report['unmatched_samples_are_not_packet_loss_proof'])

    def test_other_connection_is_not_scored(self):
        d = self.score(accepted() + [udp('send', 1000, connection=8)],
                       [udp('receive', 1083, 1_080_000_000)])['directions'][0]
        self.assertEqual(d['matched_datagrams'], 0)

    def test_no_kernel_or_gro_timestamp_cannot_score_one_datagram(self):
        for kernel, grouped, field in [(0, False, 'kernel_timestamp_unavailable'),
                                       (1_080_000_000, True, 'grouped_samples_skipped')]:
            d = self.score(accepted() + [udp('send', 1000)],
                           [udp('receive', 1083, kernel, grouped=grouped)])['directions'][0]
            self.assertEqual(d[field], 1)
            self.assertIsNone(d['socket_to_peer_kernel_upper_bounds_ms'])

    def test_inconsistent_clock_and_lengths_fail_closed(self):
        for receive in [udp('receive', 1083, 1_080_000_000, size=1199),
                        udp('receive', 900, 1_080_000_000),
                        udp('receive', 1000, 990_000_000)]:
            with self.assertRaises(ValueError):
                self.score(accepted() + [udp('send', 1000)], [receive])
        for brackets in [[], self.brackets[:1], [{'low_ns': 1, 'high_ns': 0}] * 2,
                         [{'low_ns': True, 'high_ns': 2}] * 2]:
            with self.assertRaises(ValueError):
                self.score([], [], brackets)

    def test_lifetime_maxima_are_not_packet_percentiles(self):
        rows = accepted() + [
            'datagram_queue_max_us=12000 connection_trace_id=7 event_queue_max_us=400',
            'datagram_queue_max_us=15000 connection_trace_id=7 event_queue_max_us=200',
            'datagram_queue_max_us=99000 connection_trace_id=8 event_queue_max_us=800',
        ]
        public = self.score(rows, [])['endpoints'][0]
        maxima = public['connection_lifetime_maxima_ms']
        self.assertEqual(maxima['datagram_queue_max_ms'], 15)
        self.assertEqual(maxima['event_queue_max_ms'], .4)
        self.assertIsNone(maxima['udp_send_wait_max_ms'])

    def test_ambiguous_local_queue_observations_are_skipped(self):
        public = self.score(accepted() + accepted(), [])['endpoints'][0]
        self.assertEqual(public['ambiguous_local_cells_skipped'], 1)
        self.assertIsNone(public['budget_to_quic_acceptance_ms'])


if __name__ == '__main__':
    unittest.main()
