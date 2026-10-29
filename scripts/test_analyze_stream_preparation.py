import json
from pathlib import Path
import subprocess
import sys
import unittest

from analyze_stream_preparation import analyze, MAX_SAMPLES, MAX_SCOPES


class PreparationTests(unittest.TestCase):
    def test_snapshots_use_per_mux_high_water_not_sum_of_repeated_snapshots(self):
        value = analyze([
            'onion-stream-mux[1]: received=10 inbox_full=2 inbox_full_ack=1',
            'onion-stream-mux[1]: received=11 inbox_full=2 inbox_full_ack=1',
            'onion-stream-mux[2]: received=5 inbox_full=0 inbox_full_ack=0',
        ])
        self.assertEqual(value['mux_scopes_observed'], 2)
        self.assertEqual(value['mux_totals']['received'], 16)
        self.assertEqual(value['mux_totals']['inbox_full'], 2)
        self.assertEqual(value['mux_totals']['inbox_full_ack'], 1)
        self.assertIsNone(value['mux_totals']['inbox_closed'])
        self.assertIsNone(analyze([])['mux_totals']['inbox_full'])

    def test_preparation_separates_address_classes_and_stage_kinds(self):
        value = analyze([
            'INFO onion-stream.stage stage=receiver_ads elapsed_ms=3501 result=1 local=0 address_kind=2 count=3',
            'INFO onion-stream.stage stage=relay_directory elapsed_ms=0 result=1 local=1 address_kind=0 count=1',
            'outbound stream rendezvous filter for private resolve_ms=3502',
            'outbound circuit ready for private circuit_open_ms=10 confirm_ms=20 publish_ms=3',
        ])
        stages = value['preparation_stages']
        self.assertEqual(stages['receiver_ads/result1/local0/address2']['max_ms'], 3501)
        self.assertEqual(stages['relay_directory/result1/local1/address0']['max_ms'], 0)
        self.assertEqual(value['outbound_preparation']['resolve_ms']['max_ms'], 3502)
        self.assertEqual(value['outbound_preparation']['confirm_ms']['max_ms'], 20)
        self.assertEqual(value['outbound_preparation']['publish_ms']['max_ms'], 3)

    def test_raw_identifiers_and_unknown_stage_names_never_escape(self):
        secret = 'PRIVATE_SENTINEL'
        value = analyze([
            f'{secret} onion-stream-mux[987654321]: received=1 inbox_full=0 peer={secret}',
            f'onion-stream.stage stage={secret} elapsed_ms=1 result=1 local=0 address_kind=0 count=1',
            f'outbound circuit ready for {secret} circuit_open_ms=3 path=/private/{secret}',
        ])
        rendered = json.dumps(value)
        self.assertNotIn(secret, rendered)
        self.assertNotIn('987654321', rendered)
        self.assertNotIn('/private/', rendered)
        self.assertEqual(value['preparation_stages'], {})

    def test_observation_caps_are_explicit(self):
        value = analyze(f'onion-stream-mux[{i}]: received=1 inbox_full=0' for i in range(MAX_SCOPES + 1))
        self.assertEqual(value['mux_scopes_observed'], MAX_SCOPES)
        self.assertEqual(value['omitted_at_observation_cap'], 1)
        row = 'onion-stream.stage stage=receiver_ads elapsed_ms=1 result=1 local=0 address_kind=0 count=1'
        value = analyze([row] * (MAX_SAMPLES + 1))
        self.assertEqual(value['omitted_at_observation_cap'], 1)

    def test_cli_io_error_does_not_echo_the_private_input_path(self):
        secret = '/PRIVATE_SENTINEL/missing-log'
        result = subprocess.run([sys.executable, str(Path(__file__).with_name(
            'analyze_stream_preparation.py')), '--log', secret], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(secret, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
