import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from analyze_post_switch_call import analyze


SECRET = 'private-call-capability-do-not-export'


def capture():
    result = {'events': [
        {'kind': 'wifi-disabled', 'at': .1},
        {'kind': 'placed', 'at': .2, 'callId': SECRET},
        {'kind': 'windows-accepted', 'at': .6},
        {'kind': 'qualified', 'at': 8.1}], 'samples': []}
    for at in [.3, 1, 2, 3, 4, 5, 6, 7, 8]:
        for role in ['phone', 'windows']:
            status = 'dialing' if role == 'phone' and at < 3 else 'connecting' if at < 4 else 'active'
            c = {'callId': SECRET, 'peer': 'private-peer', 'status': status,
                 'mediaStats': {'running': True, 'worker_stalled': 0,
                                'audio_rx_pkts': int(at * 10) if at >= 4 else 0,
                                'audio_rx_native_age_ms': 30}}
            if role == 'windows' and at < .6:
                c = None  # No incoming call before acceptance is legitimate.
            result['samples'].append({'at': at, 'role': role, 'call': c})
    return result


class SetupTests(unittest.TestCase):
    def test_invalid_cli_capture_does_not_echo_private_path_or_input(self):
        script = Path(__file__).with_name('analyze_post_switch_call.py')
        with tempfile.TemporaryDirectory(prefix=SECRET) as folder:
            private = Path(folder) / 'capture.json'
            private.write_text(json.dumps({'events': SECRET, 'samples': []}))
            result = subprocess.run([sys.executable, str(script), str(private)],
                                    capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr, 'Invalid setup capture; no private input echoed.\n')

    def test_dialing_and_post_connect_observation_are_separate(self):
        out = analyze(capture())
        self.assertTrue(out['sampledSetupQualified'])
        self.assertEqual(out['callerLastDialingSampleAfterCalleeAcceptMs'], 1400)
        self.assertEqual(out['callerFirstConnectingOrActiveSampleAfterCalleeAcceptMs'], 2400)
        self.assertEqual(out['callerFirstFreshRxAfterFirstConnectingObservationMs'], 1000)

    def test_null_call_after_acceptance_is_a_failure(self):
        data = capture()
        next(r for r in data['samples'] if r['role'] == 'windows' and r['at'] == 2)['call'] = None
        out = analyze(data)
        self.assertFalse(out['sampledSetupQualified'])
        self.assertEqual(out['endpoints']['windows']['missingOrUnexpectedCallSamplesAfterRoleStart'], 1)

    def test_foreign_call_with_fresh_statistics_is_not_ours(self):
        data = capture()
        data['samples'][-1]['call']['callId'] = 'another-private-call'
        out = analyze(data)
        self.assertFalse(out['sampledSetupQualified'])
        self.assertEqual(out['endpoints']['windows']['foreignCallSamples'], 1)

    def test_zero_packets_are_not_fresh_even_with_zero_age(self):
        data = capture()
        for row in data['samples']:
            if row['call']:
                row['call']['mediaStats'].update(audio_rx_pkts=0, audio_rx_native_age_ms=0)
        out = analyze(data)
        self.assertFalse(out['sampledSetupQualified'])
        self.assertIsNone(out['endpoints']['phone']['firstSampledFreshRxAfterCutMs'])

    def test_gaps_in_observation_do_not_qualify(self):
        data = capture()
        data['samples'] = [r for r in data['samples'] if r['at'] not in (2, 3, 4)]
        self.assertFalse(analyze(data)['sampledSetupQualified'])

    def test_only_four_fresh_tail_samples_do_not_qualify(self):
        data = capture()
        for row in data['samples']:
            if row['at'] == 4 and row['call']:
                row['call']['mediaStats']['audio_rx_pkts'] = 0
        self.assertFalse(analyze(data)['sampledSetupQualified'])

    def test_frozen_native_statistics_do_not_prove_sustained_receive(self):
        data = capture()
        for row in data['samples']:
            if row['call'] and row['at'] >= 4:
                row['call']['mediaStats']['audio_rx_pkts'] = 99
        self.assertFalse(analyze(data)['sampledSetupQualified'])

    def test_boolean_worker_state_is_not_a_native_zero_counter(self):
        data = capture()
        for row in data['samples']:
            if row['call']:
                row['call']['mediaStats']['worker_stalled'] = False
        self.assertFalse(analyze(data)['sampledSetupQualified'])

    def test_early_caller_connect_does_not_create_a_negative_start_interval(self):
        data = capture()
        for row in data['samples']:
            if row['role'] == 'phone':
                row['call']['status'] = 'active'
                row['call']['mediaStats']['audio_rx_pkts'] = int(row['at'] * 10)
        self.assertEqual(analyze(data)['callerFirstFreshRxAfterFirstConnectingObservationMs'], 0)

    def test_export_contains_no_capture_identifiers_or_device_labels(self):
        data = capture()
        for row in data['samples']:
            if row['call']:
                row['call']['mediaStats']['capture_microphone_label'] = 'private-device-label'
        out = json.dumps(analyze(data))
        for value in [SECRET, 'private-peer', 'private-device-label']:
            self.assertNotIn(value, out)

    def test_out_of_order_observations_are_rejected(self):
        data = capture()
        data['samples'][0]['at'] = 9
        with self.assertRaises(ValueError):
            analyze(data)

    def test_duplicate_setup_events_are_rejected(self):
        data = capture()
        data['events'].append(copy.deepcopy(data['events'][1]))
        with self.assertRaises(ValueError):
            analyze(data)

    def test_empty_data_is_never_a_pass(self):
        data = capture(); data['samples'] = []
        self.assertFalse(analyze(data)['sampledSetupQualified'])


if __name__ == '__main__':
    unittest.main()
