import copy
import unittest

from analyze_stimulus import analyze


def fixture():
    windows = []
    at = 0
    for kind, duration in [('quiet', 5), ('speech', 6), ('quiet', 6),
                           ('speech', 6), ('quiet', 6), ('speech', 6), ('quiet', 5)]:
        windows.append({'kind': kind, 'from': at, 'to': at + duration})
        at += duration
    case = {'completed': True, 'samples': [], 'phases': [], 'restoredNS': {'ns': 1}}
    sources = []
    tick = 0
    for index, ns in enumerate([1, 0, 1]):
        start = (index * 45 + 1) * 10**9
        sources.append([
            {'event': 'playback_started', 'uptime_ns': start, 'frames': 640000,
             'rate': 16000, 'streamOutputVerified': True, 'systemDefaultUnchanged': True},
            {'event': 'playback_finished', 'completionReceived': True,
             'renderedFrames': 640000, 'systemDefaultUnchanged': True},
        ])
        case['phases'].append({'completed': True, 'sourceExitCode': 0,
                               'control': {'ns': ns, 'aec': 1, 'agc': 1,
                                           'mediaEpochUnchanged': True}})
        for window in windows:
            for offset in [1.5, 2.5]:
                tick += 1
                value = 3 if window['kind'] == 'speech' else 1
                states = {}
                for role in ['phone', 'windows']:
                    states[role] = {'call': {
                        'callId': 'fixture-call', 'status': 'active',
                        'mediaStats': {'audio_output_duration_ms': tick * 1000,
                                       'audio_tx_pkts': tick * 20,
                                       'audio_rx_pkts': tick * 20,
                                       'audio_input_level_band': value,
                                       'audio_output_level_band': value,
                                       'audio_capture_start_result': 1,
                                       'audio_playout_start_result': 1,
                                       'audio_aec_enabled': 1,
                                       'audio_agc_enabled': 1,
                                       'audio_ns_enabled': ns if role == 'phone' else 1,
                                       'media_epoch': 1}}}
                case['samples'].append({'uptime_ns': start + int((window['from'] + offset) * 1e9),
                                         'states': states})
    return case, {'windows': windows, 'durationSeconds': at}, sources


class GateTest(unittest.TestCase):
    def test_three_timed_pulses_at_both_endpoints(self):
        self.assertTrue(analyze(*fixture())['patternEstablished'])

    def test_continuous_noise_is_not_speech_pattern(self):
        case, pattern, sources = fixture()
        for sample in case['samples']:
            for state in sample['states'].values():
                state['call']['mediaStats']['audio_input_level_band'] = 3
                state['call']['mediaStats']['audio_output_level_band'] = 3
        self.assertFalse(analyze(case, pattern, sources)['patternEstablished'])

    def test_peaks_outside_stimulus_do_not_qualify(self):
        case, pattern, sources = fixture()
        for sample in case['samples']:
            for state in sample['states'].values():
                stats = state['call']['mediaStats']
                stats['audio_input_level_band'] = 4 - stats['audio_input_level_band']
                stats['audio_output_level_band'] = 4 - stats['audio_output_level_band']
        self.assertFalse(analyze(case, pattern, sources)['patternEstablished'])

    def test_cached_stats_repeated_many_times_are_one_observation(self):
        case, pattern, sources = fixture()
        for i in range(0, len(case['samples']), 2):
            case['samples'][i + 1]['states'] = copy.deepcopy(case['samples'][i]['states'])
        self.assertFalse(analyze(case, pattern, sources)['patternEstablished'])

    def test_source_exit_without_played_back_witness_is_invalid(self):
        case, pattern, sources = fixture()
        sources[1][1]['completionReceived'] = False
        with self.assertRaises(ValueError):
            analyze(case, pattern, sources)

    def test_replaced_call_is_not_one_session(self):
        case, pattern, sources = fixture()
        case['samples'][-1]['states']['phone']['call']['callId'] = 'another-call'
        with self.assertRaises(ValueError):
            analyze(case, pattern, sources)

    def test_native_processing_must_match_the_control(self):
        case, pattern, sources = fixture()
        case['samples'][0]['states']['phone']['call']['mediaStats']['audio_ns_enabled'] = 0
        with self.assertRaises(ValueError):
            analyze(case, pattern, sources)

    def test_capture_alone_does_not_qualify_the_remote_output(self):
        case, pattern, sources = fixture()
        for sample in case['samples']:
            sample['states']['windows']['call']['mediaStats']['audio_output_level_band'] = 1
        self.assertFalse(analyze(case, pattern, sources)['patternEstablished'])

    def test_rebuilt_media_is_not_the_same_session(self):
        case, pattern, sources = fixture()
        case['samples'][-1]['states']['phone']['call']['mediaStats']['media_epoch'] = 2
        with self.assertRaises(ValueError):
            analyze(case, pattern, sources)


if __name__ == '__main__':
    unittest.main()
