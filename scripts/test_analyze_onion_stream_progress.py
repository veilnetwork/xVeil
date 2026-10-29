import json
import math
from pathlib import Path
import subprocess
import sys
import unittest

from analyze_onion_stream_progress import analyze_driver, analyze_progress


class StreamProgressTests(unittest.TestCase):
    def test_native_and_logcat_rows_optional_rtt_and_distinct_streams(self):
        result = analyze_driver([
            'onion-stream-driver[11]: now=0 srtt=None rto=2000ms oo=0 consec_rto=0',
            '1234 I veilnode: onion-stream-driver[11]: now=8000 srtt=Some(120) rto=8000ms oo=3 consec_rto=2',
            'onion-stream-driver[19]: now=4 srtt=Some(50) rto=1000ms oo=0',
        ])
        self.assertEqual(result['streams_observed'], 2)
        self.assertEqual(result['longest_observed_stream_span_ms'], 8000)
        self.assertEqual(result['streams_with_rto_events'], 1)
        self.assertEqual(result['streams_with_out_of_order_data'], 1)
        self.assertEqual(result['observed_maxima']['srtt'], 120)
        self.assertEqual(result['observed_maxima']['rto'], 8000)
        self.assertIsNone(result['observed_maxima']['blocked_age'])

    def test_only_allowlisted_numbers_are_exported(self):
        secret = 'PRIVATE_SENTINEL_never_export'
        result = analyze_driver([
            f'{secret} node=10.20.30.40 onion-stream-driver[987654321]: now=1 '
            f'peer={secret} path=/private/{secret} password={secret} rto=1000ms oo=0'
        ])
        text = json.dumps(result)
        for value in [secret, '10.20.30.40', '987654321', '/private/']:
            self.assertNotIn(value, text)
        self.assertNotIn(secret, json.dumps(analyze_progress([
            {'seconds': 1, 'written': 4, 'message': secret, 'path': secret}
        ])))

    def test_stream_cap_bounds_retained_state_and_reports_omissions(self):
        result = analyze_driver(f'onion-stream-driver[{i}]: now=1 rto=1000ms'
                                for i in range(4098))
        self.assertEqual(result['streams_observed'], 4096)
        self.assertEqual(result['omitted_summaries_at_stream_cap'], 2)

    def test_small_reverse_flights_are_distinct_from_receiver_window_stalls(self):
        result = analyze_driver([
            'onion-stream-driver[1]: now=1 phase=SynSent rwnd=0 inflight=1 consec_rto=1',
            'onion-stream-driver[1]: now=2 phase=Established rwnd=8192 inflight=8 consec_rto=1 oo_bytes=40',
            'onion-stream-driver[1]: now=3 phase=Established rwnd=8192 inflight=8 consec_rto=2',
            'onion-stream-driver[1]: now=4 phase=Established rwnd=0 inflight=1024 consec_rto=1',
            'onion-stream-driver[1]: now=5 phase=Established inflight=1024 consec_rto=1',
            'onion-stream-driver[1]: now=6 phase=Established inflight=0 pending=8 consec_rto=2',
            'onion-stream-driver[1]: now=7 phase=Established inflight=10 pending=8 consec_rto=2',
        ])
        self.assertEqual(result['established_zero_window_samples'], 1)
        self.assertEqual(result['small_flight_rto_samples'], 3)
        self.assertEqual(result['small_flight_rto_with_buffered_incoming_data_samples'], 1)
        self.assertEqual(result['small_pending_rto_samples'], 1)

    def test_progress_separates_initial_gap_trailing_wait_and_regression(self):
        result = analyze_progress([
            {'seconds': 1, 'written': 0}, {'seconds': 3, 'written': 10},
            {'seconds': 4, 'written': 0}, {'seconds': 5, 'written': 10},
            {'seconds': 9, 'written': 20}, {'seconds': 12, 'written': 20},
        ])
        self.assertEqual(result['first_observed_progress_seconds'], 3)
        self.assertEqual(result['max_gap_after_first_progress_seconds'], 6)
        self.assertEqual(result['trailing_no_progress_seconds'], 3)
        self.assertEqual(result['regressive_observations'], 1)
        self.assertEqual(result['observed_high_water_bytes'], 20)

    def test_malformed_progress_and_cli_errors_do_not_disclose_paths(self):
        for value in [math.nan, math.inf, -1, True, 'secret']:
            with self.assertRaises(ValueError):
                analyze_progress([{'seconds': value, 'written': 1}])
        with self.assertRaises(ValueError):
            analyze_progress([{'seconds': 3, 'written': 1}, {'seconds': 2, 'written': 2}])
        secret = '/PRIVATE_SENTINEL_never_export/missing'
        run = subprocess.run([sys.executable, str(Path(__file__).with_name(
            'analyze_onion_stream_progress.py')), '--endpoint-log', secret],
            capture_output=True, text=True)
        self.assertNotEqual(run.returncode, 0)
        self.assertNotIn(secret, run.stdout + run.stderr)


if __name__ == '__main__':
    unittest.main()
