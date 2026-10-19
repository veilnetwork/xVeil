import copy
import unittest

from opaque_packet_route import attribute_route


class OpaqueRouteTest(unittest.TestCase):
    def fixture(self):
        rows = []
        for stage, node, peer, at in [
            ('transport_selected', '11111111', '22222222', 110),
            ('dispatch_enter', '22222222', '11111111', 180),
            ('transport_selected', '22222222', '33333333', 190),
            ('dispatch_return', '22222222', '11111111', 200),
            ('dispatch_enter', '33333333', '22222222', 260),
            ('dispatch_return', '33333333', '22222222', 270),
        ]:
            rows.append(dict(stage=stage, node=node, peer=peer,
                             monotonic_us=str(at), opaque_bytes='50',
                             opaque_sha256='a'*64))
        return rows

    def analyze(self, rows):
        return attribute_route('a'*64, rows, source='11111111',
                               receiver='33333333', sealed_us=100,
                               received_us=300, sealed_bytes=50)

    def test_path_joins_bytes_and_direction_without_ordering_log_lines(self):
        result = self.analyze(reversed(self.fixture()))
        self.assertEqual([hop['selection_to_dispatch_ms'] for hop in
                          result['hops']], [.07, .07])
        self.assertEqual(result['relay_processing'][0]['ingress_to_selection_ms'], .01)
        self.assertAlmostEqual(result['seal_to_first_selection_ms'] +
                               sum(r['selection_to_dispatch_ms'] for r in result['hops']) +
                               sum(r['ingress_to_selection_ms'] for r in result['relay_processing']) +
                               result['last_dispatch_to_authenticated_ms'],
                               result['sealed_to_authenticated_ms'])

    def test_missing_duplicate_and_disconnected_observations_are_rejected(self):
        rows = self.fixture()
        for i in range(len(rows)):
            for bad in [rows[:i]+rows[i+1:], rows+[rows[i]]]:
                with self.assertRaises(ValueError):
                    self.analyze(bad)
        extra = dict(rows[0], node='44444444', peer='55555555')
        with self.assertRaises(ValueError):
            self.analyze(rows+[extra])

    def test_wrong_size_peer_clock_and_stage_cannot_qualify_a_route(self):
        for index, key, value in [(0, 'opaque_bytes', '51'),
                                   (1, 'peer', '55555555'),
                                   (1, 'monotonic_us', '105'),
                                   (3, 'monotonic_us', '170'),
                                   (4, 'monotonic_us', '-1'),
                                   (4, 'monotonic_us', '301'),
                                   (0, 'stage', 'wire_sent')]:
            rows = copy.deepcopy(self.fixture())
            rows[index][key] = value
            with self.assertRaises(ValueError):
                self.analyze(rows)

    def test_another_ciphertext_is_not_a_substitute_for_a_missing_hop(self):
        rows = self.fixture()
        rows[1]['opaque_sha256'] = 'b'*64
        with self.assertRaises(ValueError):
            self.analyze(rows)

    def test_dispatch_return_can_follow_authentication_without_extending_hop(self):
        rows = self.fixture()
        rows[-1]['monotonic_us'] = '310'
        self.assertEqual(self.analyze(rows)['sealed_to_authenticated_ms'], .2)

    def test_relay_loop_cannot_be_interpreted_as_a_completed_route(self):
        rows = self.fixture()
        rows[2]['peer'] = '11111111'
        with self.assertRaises(ValueError):
            self.analyze(rows)


if __name__ == '__main__':
    unittest.main()
