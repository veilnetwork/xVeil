import unittest

from pcm_timing import input_edges


class InputTimingTests(unittest.TestCase):
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
