import unittest

from pcm_timing import capture_coverage, input_edges


class InputTimingTests(unittest.TestCase):
    def test_capture_must_cover_both_directions_from_start_to_finish(self):
        rows = [{'side': side, 'source_at': at}
                for side in (0, 1) for at in (.005, 59.995)]
        self.assertTrue(capture_coverage(rows, 60)['verified'])
        for selected in (rows[:2], rows[2:], rows[:-1]):
            self.assertFalse(capture_coverage(selected, 60)['verified'])

    def test_loading_after_the_origin_cannot_qualify_a_partial_capture(self):
        rows = [{'side': side, 'source_at': at}
                for side in (0, 1) for at in (42.6, 359.99)]
        result = capture_coverage(rows, 360)
        self.assertFalse(result['verified'])
        self.assertEqual(result['directions'][0]['first_seconds'], 42.6)

    def test_local_playout_delay_cannot_move_the_input_edge(self):
        rows = [
            {'source_at': 20.0, 't': 20.002, 'source_freq': 500, 'source_tick': 0},
            {'source_at': 21.01, 't': 21.08, 'source_freq': 1000, 'source_tick': 101},
            {'source_at': 21.02, 't': 21.09, 'source_freq': 1000, 'source_tick': 102},
        ]
        edges = input_edges(rows)
        rendered_at = 21.19
        self.assertAlmostEqual((rendered_at - edges[-1][0]) * 1000, 180)
        self.assertEqual(edges[-1][2], 101)
        for row in rows:
            row['t'] += 0.5
        self.assertEqual(input_edges(rows), edges)

    def test_a_clock_order_violation_cannot_produce_a_shorter_delay(self):
        with self.assertRaises(ValueError):
            input_edges([
                {'source_at': 21.08, 't': 21.01, 'source_freq': 500, 'source_tick': 0}
            ])


if __name__ == '__main__':
    unittest.main()
