import copy
import unittest

from verify_call_observation import inspect


def capture():
    return {'mode': 'denied', 'qualified': True, 'events': [
        {'kind': 'incoming', 'at': 1}, {'kind': 'five-fresh-samples', 'at': 7},
        {'kind': 'sustained-observation-complete', 'at': 28}], 'samples': [
            {'role': role, 'at': at, 'call': {
                'callId': 'private-test-call', 'status': 'active', 'transport': 'relay',
                'mediaStats': {'audio_rx_pkts': at, 'audio_rx_native_age_ms': 50}}}
            for at in (7, 10, 15, 20, 28) for role in ('phone', 'mac')]}


class ObservationGuard(unittest.TestCase):
    def test_fresh_pair_passes_without_exporting_call_id(self):
        result = inspect(capture())
        self.assertTrue(result['strictFreshRxQualified'])
        self.assertNotIn('private-test-call', str(result))

    def test_old_green_flag_does_not_hide_a_later_stall(self):
        value = capture()
        value['samples'][3]['call']['mediaStats']['audio_rx_native_age_ms'] = 3443
        self.assertFalse(inspect(value)['strictFreshRxQualified'])

    def test_empty_endpoint_or_other_call_does_not_pass(self):
        value = capture()
        value['samples'] = [row for row in value['samples'] if row['role'] == 'phone']
        self.assertFalse(inspect(value)['strictFreshRxQualified'])
        value = capture()
        value['samples'][3]['call']['callId'] = 'another-call'
        self.assertFalse(inspect(value)['strictFreshRxQualified'])

    def test_short_observation_does_not_pass(self):
        value = copy.deepcopy(capture())
        value['events'][-1]['at'] = 10
        self.assertFalse(inspect(value)['strictFreshRxQualified'])


if __name__ == '__main__':
    unittest.main()
