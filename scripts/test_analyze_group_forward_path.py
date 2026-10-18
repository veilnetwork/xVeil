import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from analyze_group_forward_path import analyze, attribute


class ForwardPathTest(unittest.TestCase):
    def fixture(self):
        identity = dict(epoch='0123456789abcdef', seq='2252')
        sdk = dict(epoch=identity['epoch'], cell_sequence=2252, sealed_bytes=235,
                   receiver_sdk_peer='11223344', source_sdk_peer='55667788',
                   observations_us=dict(sdk_authenticated=500))
        endpoint = [dict(identity, stage='sealed', monotonic_us='100', sealed_sha256='a'*64),
                    dict(identity, stage='received', monotonic_us='510', sealed_sha256='a'*64)]
        common = dict(opaque_sha256='a'*64, opaque_bytes='235')
        rows = [dict(common, node=node, peer=peer, stage=stage, monotonic_us=str(at))
                for node, peer, stage, at in [
                    ('11223344', '99aabbcc', 'transport_selected', 120),
                    ('99aabbcc', '11223344', 'dispatch_enter', 200),
                    ('99aabbcc', '11223344', 'dispatch_return', 220),
                    ('99aabbcc', '55667788', 'transport_selected', 210),
                    ('55667788', '99aabbcc', 'dispatch_enter', 480),
                    ('55667788', '99aabbcc', 'dispatch_return', 490)]]
        return sdk, endpoint, rows

    def test_exact_opaque_path_separates_hops_and_relay_queue(self):
        result = attribute(*self.fixture())
        self.assertEqual(result['relay_node'], '99aabbcc')
        self.assertEqual(result['spans_ms']['relay_dispatch_enter_to_relay_transport_selected'], .01)
        self.assertEqual(result['dispatch_duration_ms']['relay'], .02)
        self.assertAlmostEqual(sum(result['spans_ms'].values()), .38)

    def test_absent_duplicate_or_other_peer_cannot_guess_a_path(self):
        for mode in ('absent', 'duplicate', 'other_peer', 'extra'):
            sdk, endpoint, rows = copy.deepcopy(self.fixture())
            if mode == 'absent': rows.pop(2)
            elif mode == 'duplicate': rows.append(copy.deepcopy(rows[0]))
            elif mode == 'other_peer': rows[1]['peer'] = 'deadbeef'
            else: rows.append(dict(rows[1], node='deadbeef'))
            with self.assertRaises(ValueError): attribute(sdk, endpoint, rows)

    def test_authenticated_payload_digest_and_length_must_match(self):
        for value in ('-', 'b'*64):
            sdk, endpoint, rows = self.fixture()
            endpoint[1]['sealed_sha256'] = value
            with self.assertRaises(ValueError): attribute(sdk, endpoint, rows)
        sdk, endpoint, rows = self.fixture(); rows[2]['opaque_bytes'] = '236'
        with self.assertRaises(ValueError): attribute(sdk, endpoint, rows)

    def test_unknown_or_reversed_clocks_are_rejected(self):
        for index, at in [(0, '-1'), (1, '100'), (2, '190'), (3, '510'), (5, '479')]:
            sdk, endpoint, rows = self.fixture(); rows[index]['monotonic_us'] = at
            with self.assertRaises(ValueError): attribute(sdk, endpoint, rows)

    def test_dispatch_returns_can_follow_downstream_receipt(self):
        sdk, endpoint, rows = self.fixture()
        rows[2]['monotonic_us'] = '520'; rows[5]['monotonic_us'] = '530'
        result = attribute(sdk, endpoint, rows)
        self.assertEqual(result['observations_us']['sdk_authenticated'], 500)
        self.assertAlmostEqual(sum(result['spans_ms'].values()), .38)

    def test_endpoint_authentication_and_distinct_relay_are_required(self):
        sdk, endpoint, rows = self.fixture(); endpoint[1]['monotonic_us'] = '499'
        with self.assertRaises(ValueError): attribute(sdk, endpoint, rows)
        sdk, endpoint, rows = self.fixture(); rows[0]['peer'] = sdk['source_sdk_peer']
        with self.assertRaisesRegex(ValueError, 'distinct one-relay'): attribute(sdk, endpoint, rows)

    def test_truncated_capture_is_rejected_before_path_attribution(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path/'native.log').write_text('delivery.opaque_trace_limit rows=524288\n')
            with patch('analyze_group_forward_path.analyze_session', return_value={}):
                with self.assertRaisesRegex(ValueError, 'truncated'): analyze(path)


if __name__ == '__main__':
    unittest.main()
