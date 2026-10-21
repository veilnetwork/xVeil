import unittest

from analyze_physical_pcm import analyze_path


class PhysicalPcmTest(unittest.TestCase):
    def samples(self, skip=None):
        capture, received = [], []
        for tick in range(10):
            frequency = 600 if tick % 2 == 0 else 900
            at = tick + .01
            capture.append(dict(source_at=at, t=at + .001,
                                source_freq=frequency, source_tick=tick))
            if tick == skip:
                continue
            for delta in [.125, .135]:
                received.append(dict(t=at + delta, freq=frequency, rms=8000))
        return capture, received

    def test_latency_is_based_on_actual_capture_with_clock_envelope(self):
        a, b = self.samples()
        path = analyze_path(a, b, 9, delay_correction_low=-.01,
                            delay_correction_high=.02)
        phase = path['phases'][0]
        self.assertEqual(phase['matched'], 4)
        self.assertEqual(phase['unmatched'], 0)
        self.assertAlmostEqual(phase['max_ms'], 125)
        self.assertAlmostEqual(phase['max_clock_interval_ms'][0], 115)
        self.assertAlmostEqual(phase['max_clock_interval_ms'][1], 145)

    def test_lost_period_is_not_rematched_to_a_later_repeated_tone(self):
        a, b = self.samples(skip=4)
        path = analyze_path(a, b, 9)
        self.assertGreater(path['phases'][0]['unmatched'], 0)
        self.assertGreater(path['phases'][0]['max_ms'], 2000)
        self.assertEqual(path['matching'], 'ordinal_from_actual_capture_start')

    def test_explicit_phases_do_not_invent_a_route_handover(self):
        a, b = self.samples()
        path = analyze_path(a, b, 9,
                            phase_ranges=[(0, 3, 'wifi_audio'),
                                          (3, 20, 'wifi_video')])
        self.assertEqual([p['phase'] for p in path['phases']],
                         ['wifi_audio', 'wifi_video'])
        self.assertEqual([p['matched'] for p in path['phases']], [3, 6])
        self.assertEqual(path['phases'][1]['until_seconds'], 9)
        self.assertTrue(all(p['unmatched'] == 0 for p in path['phases']))


if __name__ == '__main__':
    unittest.main()
