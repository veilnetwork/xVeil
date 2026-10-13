import unittest
from analyze_tcp_queue_timing import analyze


SUMMARY = {'loopback_only': True, 'duration_seconds': 100,
           'stand_start_monotonic_us': 1000000, 'synthetic_video_source': 'camera'}


def row(seconds, queued, retransmitted, connection=1):
    return (f'transport.tcp_trace.kernel_progress connection={connection} '
            f'monotonic_us={1000000 + int(seconds * 1e6)} queued_max_bytes=Some(99999) '
            f'kernel_now=Ok(KernelSnapshot {{ rtt_us: 4000, rto_us: 200000, '
            f'cwnd_bytes: 10000, send_buffer_bytes: 32768, queued_bytes: Some({queued}), '
            f'notsent_bytes: None, retransmitted_bytes: Some({retransmitted}) }})')


class TcpTimingTests(unittest.TestCase):
    def test_current_queue_not_old_high_water_and_retransmission_delta(self):
        r = analyze(SUMMARY, [row(19, 200, 1000), row(21, 40, 1400), row(23, 60, 1500)], 20, 24)
        self.assertEqual(r['current_snapshot_maxima']['queued_bytes']['max'], 60)
        self.assertEqual(r['retransmitted_bytes_observed_deltas']['sum'], 500)
        self.assertIsNone(r['current_snapshot_maxima']['notsent_bytes']['max'])

    def test_missing_baseline_is_unknown_and_no_connection_id_is_output(self):
        r = analyze(SUMMARY, [row(21, 40, 3000)], 20, 24)
        self.assertIsNone(r['retransmitted_bytes_observed_deltas']['sum'])
        self.assertEqual(r['retransmitted_bytes_observed_deltas']['unknown_connections'], 1)
        self.assertNotIn('connection_id', str(r))

    def test_real_logger_target_delimiter_and_legacy_rows_are_recognized(self):
        wrapped = row(21, 70, 200).replace('transport.tcp_trace.kernel_progress ',
                                        '[INFO transport.tcp_trace.kernel_progress] ')
        legacy = wrapped.replace('monotonic_us=22000000 ', '')
        r = analyze(SUMMARY, [wrapped, legacy], 20, 24)
        self.assertEqual(r['timed_snapshots'], 1)
        self.assertEqual(r['legacy_untimed_rows'], 1)

    def test_legacy_unknown_foreign_and_failed_snapshots_are_not_zero_queues(self):
        lines = ['transport.tcp_trace.kernel_progress connection=1 kernel_now=Ok(...)',
                 'transport.tcp_trace.kernel_progress connection=2 monotonic_us=unknown',
                 row(50000, 10, 10),
                 'transport.tcp_trace.kernel_progress connection=2 monotonic_us=22000000 kernel_now=Err(Unsupported)']
        r = analyze(SUMMARY, lines, 20, 24)
        self.assertEqual([r[k] for k in ['legacy_untimed_rows', 'unknown_clock_rows', 'foreign_clock_rows', 'failed_kernel_snapshots']], [1, 1, 1, 1])
        self.assertIsNone(r['current_snapshot_maxima']['queued_bytes']['max'])

    def test_counter_decrease_is_not_negative_loss(self):
        r = analyze(SUMMARY, [row(19, 1, 200), row(21, 1, 10)], 20, 24)
        self.assertEqual(r['retransmitted_bytes_observed_deltas']['counter_resets'], 1)
        self.assertIsNone(r['retransmitted_bytes_observed_deltas']['sum'])

    def test_foreign_fixture_and_invalid_windows_rejected(self):
        with self.assertRaises(ValueError): analyze(dict(SUMMARY, loopback_only=False), [])
        for a, b in [(-1, 25), (25, 25), (20, 101)]:
            with self.assertRaises(ValueError): analyze(SUMMARY, [], a, b)


if __name__ == '__main__': unittest.main()
