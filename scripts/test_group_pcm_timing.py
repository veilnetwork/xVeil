import unittest
from group_pcm_timing import analyze_voice_path


def fixture(delay):
    rows = []
    for tick in range(3200):
        at = tick / 100
        source = 600 if int(at) % 2 == 0 else 900
        decoded = (600 if int(at - delay) % 2 == 0 else 900) if at >= delay else 0
        rows.append({'source_at': at, 't': at, 'source_tick': tick,
                     'source_freq': source, 'freq': decoded, 'rms': 6000})
    return rows


class GroupTimingTests(unittest.TestCase):
    def test_real_output_delay_is_measured_for_both_phases(self):
        result = analyze_voice_path(fixture(.05), 30)
        for phase in result['phases']:
            self.assertEqual(phase['missing'], 0)
            self.assertGreater(phase['matched'], 0)
            self.assertAlmostEqual(phase['max_ms'], 50)

    def test_whole_period_backlog_cannot_masquerade_as_low_latency(self):
        result = analyze_voice_path(fixture(2.05), 30)
        self.assertTrue(all(phase['max_ms'] > 2000 for phase in result['phases']))


if __name__ == '__main__':
    unittest.main()
