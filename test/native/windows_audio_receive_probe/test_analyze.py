import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from analyze import qualify


def fixture(silence=False):
    output = dict(success=True, sessionState=1, appMuted=False, outputMuted=False,
                  appVolumePercent=100, outputVolumePercent=56)
    rows = [dict(kind='start', result=0, output=output)]
    for index in range(66):
        seconds = index * 0.2
        tone = not silence and any(a <= seconds < b for a, b in
                                   [(1.5, 3), (5, 6.5), (8.5, 10)])
        rows.append(dict(kind='sample', seconds=seconds,
                         session_peak=0.03 if tone else 0,
                         stats=dict(audio_capture_start_result=-1,
                                    audio_playout_start_result=1, worker_stalled=0,
                                    audio_rx_pkts=min(index * 10, 600),
                                    audio_output_emitted_samples=min(index * 9600, 576000),
                                    audio_output_level_band=3 if tone else 0)))
    rows.append(dict(kind='finish', delivery_failures=0, registered=0))
    job = dict(finished=True, exitCode=0, session=1, mediaSha='fixture-sha')
    return rows, job


class OracleTest(unittest.TestCase):
    def test_completed_pattern_and_silence_controls(self):
        for silence in (False, True):
            rows, job = fixture(silence)
            self.assertTrue(qualify(rows, job, 'fixture-sha', silence=silence)['qualified'])

    def test_packet_durations_require_their_own_received_counts(self):
        for packet_ms in (40, 60):
            rows, job = fixture()
            with self.assertRaisesRegex(ValueError, 'rtp_not_observed'):
                qualify(rows, job, 'fixture-sha', packet_ms=packet_ms)
            for index, row in enumerate(rows[1:-1]):
                row['stats']['audio_rx_pkts'] = min(index * 200 // packet_ms,
                                                   12000 // packet_ms)
            self.assertTrue(qualify(rows, job, 'fixture-sha',
                                    packet_ms=packet_ms)['qualified'])

    def test_missing_native_exit_code_is_not_success(self):
        rows, job = fixture()
        job['exitCode'] = None
        with self.assertRaisesRegex(ValueError, 'job_not_qualified'):
            qualify(rows, job, 'fixture-sha')

    def test_foreign_or_changed_engine_is_not_success(self):
        rows, job = fixture()
        with self.assertRaisesRegex(ValueError, 'job_not_qualified'):
            qualify(rows, job, 'different-sha')

    def test_constant_noise_is_not_the_pattern(self):
        rows, job = fixture()
        for row in rows[1:-1]:
            row['session_peak'] = 0.03
        with self.assertRaisesRegex(ValueError, 'pattern_not_observed'):
            qualify(rows, job, 'fixture-sha')

    def test_all_three_bursts_must_reach_windows_session(self):
        rows, job = fixture()
        for row in rows[1:-1]:
            if row['seconds'] > 8:
                row['session_peak'] = 0
        with self.assertRaisesRegex(ValueError, 'pattern_not_observed'):
            qualify(rows, job, 'fixture-sha')

    def test_native_rtp_and_pcm_are_required_in_addition_to_meter(self):
        rows, job = fixture()
        frozen = copy.deepcopy(rows)
        for row in frozen[1:-1]:
            row['stats']['audio_rx_pkts'] = 600
        with self.assertRaisesRegex(ValueError, 'rtp_not_observed'):
            qualify(frozen, job, 'fixture-sha')
        rows[-2]['stats']['audio_output_emitted_samples'] = 0
        with self.assertRaisesRegex(ValueError, 'pcm_not_emitted'):
            qualify(rows, job, 'fixture-sha')

    def test_unknown_meter_and_incomplete_cleanup_are_not_success(self):
        rows, job = fixture()
        rows[1]['session_peak'] = -1
        with self.assertRaisesRegex(ValueError, 'session_meter_unavailable'):
            qualify(rows, job, 'fixture-sha')
        rows, job = fixture()
        rows[-1]['registered'] = 1
        with self.assertRaisesRegex(ValueError, 'incomplete_cleanup'):
            qualify(rows, job, 'fixture-sha')

    def test_silence_control_rejects_signal(self):
        rows, job = fixture()
        with self.assertRaisesRegex(ValueError, 'silence_control_audible'):
            qualify(rows, job, 'fixture-sha', silence=True)

    def test_cli_never_exports_private_parser_error(self):
        with tempfile.TemporaryDirectory(prefix='xveil-receive-oracle-') as directory:
            path = Path(directory)
            (path/'rows.jsonl').write_text('{PRIVATE_AUDIO_METADATA')
            (path/'job.json').write_text('{}')
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('analyze.py')),
                                     str(path/'rows.jsonl'), str(path/'job.json'),
                                     '--engine-sha', 'fixture-sha'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(json.loads(result.stdout),
                             {'qualified': False, 'reason': 'invalid_input'})
            self.assertNotIn('PRIVATE_AUDIO_METADATA', result.stdout + result.stderr)
            self.assertNotIn(str(path), result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
