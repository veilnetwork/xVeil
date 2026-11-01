import json
import unittest

from analyze_physical_handover import analyze


def capture():
    secret = 'PRIVATE_CALL_CANARY'
    return {
        'events': [{'kind': 'place-return', 'call': {'callId': secret}},
                   {'kind': 'wifi-disable-return', 'at': 5}],
        'samples': [
            {'role': role, 'at': tick + offset, 'call': {
                'callId': secret, 'peer': 'PRIVATE_PEER_CANARY',
                'status': 'active', 'transport': 'p2p', 'mediaStats': {
                    'running': True, 'worker_stalled': 0,
                    'audio_rx_native_age_ms': 100, 'audio_rx_pkts': 10,
                    'media_epoch': 1}}}
            for tick in range(46)
            for role, offset in [('phone', 0), ('windows', 0.01)]],
    }


class HandoverSummaryTest(unittest.TestCase):
    def test_complete_fresh_capture(self):
        self.assertTrue(analyze(capture())['qualityObservationQualified'])

    def test_null_is_a_lost_call_even_if_ended_was_never_sampled(self):
        data = capture()
        for row in data['samples']:
            if row['role'] == 'windows' and row['at'] >= 25:
                row['call'] = None
        result = analyze(data)
        self.assertFalse(result['callSurvivalVerified'])
        self.assertFalse(result['qualityObservationQualified'])
        self.assertEqual(result['endpoints']['windows']['firstCallLostAfterCutMs'], 20010)

    def test_a_different_active_call_cannot_replace_the_test_call(self):
        data = capture()
        data['samples'][-1]['call']['callId'] = 'PRIVATE_OTHER_CANARY'
        self.assertFalse(analyze(data)['callSurvivalVerified'])

    def test_empty_samples_are_not_vacuous_success(self):
        data = capture()
        data['samples'] = []
        self.assertFalse(analyze(data)['qualityObservationQualified'])

    def test_short_or_sparse_capture_cannot_prove_survival(self):
        for sparse in [False, True]:
            data = capture()
            data['samples'] = [r for r in data['samples'] if
                               (r['at'] < 8 or (sparse and r['at'] >= 44))]
            self.assertFalse(analyze(data)['callSurvivalVerified'])

    def test_active_ui_without_a_running_audio_receiver_is_not_quality(self):
        for field, value in [('running', False), ('worker_stalled', 1),
                             ('audio_rx_native_age_ms', -1),
                             ('audio_rx_native_age_ms', None)]:
            data = capture()
            data['samples'][-1]['call']['mediaStats'][field] = value
            self.assertFalse(analyze(data)['qualityObservationQualified'])

    def test_epoch_reset_cannot_hide_a_preceding_outage(self):
        data = capture()
        data['samples'][30]['call']['mediaStats']['audio_rx_native_age_ms'] = 14000
        data['samples'][-1]['call']['mediaStats']['media_epoch'] = 3
        result = analyze(data)
        self.assertTrue(result['callSurvivalVerified'])
        self.assertFalse(result['qualityObservationQualified'])
        self.assertIsNone(result['endpoints']['phone']['continuousAudioGapUpperBoundMs'])

    def test_outputs_never_include_captured_ids_or_extra_private_fields(self):
        data = capture()
        data['private'] = {'path': '/PRIVATE_PATH', 'token': 'PRIVATE_TOKEN'}
        result = json.dumps(analyze(data))
        for canary in ['PRIVATE_CALL', 'PRIVATE_PEER', 'PRIVATE_PATH', 'PRIVATE_TOKEN']:
            self.assertNotIn(canary, result)


if __name__ == '__main__':
    unittest.main()
