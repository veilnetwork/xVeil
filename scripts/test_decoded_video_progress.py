import unittest
from decoded_video_progress import required_tail_content_changes, summarize


def row(t, side, seq, shade='a'):
    return dict(t=t, side=side, seq=seq, width=320, height=240, sha256=shade*64)


class DecodedVideoProgressTest(unittest.TestCase):
    def test_requires_new_decoded_content_at_both_receivers_near_end(self):
        rows = [row(21, 0, 1), row(46, 0, 10), row(59, 0, 12, 'b'),
                row(21, 1, 1), row(46, 1, 10), row(59, 1, 12, 'b')]
        result = summarize(rows, 60)
        self.assertTrue(result['moving_at_end'])
        self.assertFalse(result['screen_presentation_proof'])
        self.assertEqual(result['directions'][0]['tail_content_changes'], 1)
        self.assertTrue(result['tail_content_verified'])

    def test_full_capture_requires_fourteen_content_changes_in_each_direction(self):
        rows = [row(345 + i, side, i + 1, 'ab'[i % 2])
                for side in (0, 1) for i in range(15)]
        result = summarize(rows, 360)
        self.assertEqual(result['required_tail_content_changes'], 14)
        self.assertTrue(result['tail_content_verified'])
        # A missing final pull still satisfies the old motion-only check.
        rows.pop()
        result = summarize(rows, 360)
        self.assertTrue(result['moving_at_end'])
        self.assertEqual(result['directions'][1]['tail_content_changes'], 13)
        self.assertFalse(result['tail_content_verified'])

    def test_skipped_decoded_frames_do_not_prove_unsampled_content_changes(self):
        rows = [r for side in (0, 1)
                for r in (row(345, side, 1), row(359, side, 30, 'b'))]
        result = summarize(rows, 360)
        self.assertTrue(result['moving_at_end'])
        self.assertFalse(result['tail_content_verified'])

    def test_full_gate_boundary_and_invalid_durations(self):
        self.assertEqual(required_tail_content_changes(359), 1)
        self.assertEqual(required_tail_content_changes(360), 14)
        self.assertEqual(required_tail_content_changes(720), 14)
        for duration in (0, 20, float('nan'), float('inf')):
            with self.assertRaises(ValueError):
                required_tail_content_changes(duration)

    def test_marker_counters_cannot_substitute_for_decoded_frames(self):
        result = summarize([dict(t=59, side=i, seq=0, video_rx_deliver_frames=1000)
                            for i in (0, 1)], 60)
        self.assertFalse(result['moving_at_end'])
        self.assertTrue(all(d['decoded_frame_pulls'] == 0 for d in result['directions']))

    def test_rising_sequence_with_frozen_pixels_is_not_motion(self):
        rows = [row(t, side, seq) for side in (0, 1)
                for t, seq in [(21, 1), (46, 2), (59, 3)]]
        self.assertFalse(summarize(rows, 60)['moving_at_end'])

    def test_early_motion_cannot_qualify_a_frozen_tail_or_missing_receiver(self):
        self.assertFalse(summarize([row(21, 0, 1), row(22, 0, 2, 'b')], 60)['moving_at_end'])
        rows = [row(46, 0, 1), row(59, 0, 2, 'b')]
        self.assertFalse(summarize(rows, 60)['moving_at_end'])

    def test_corrupt_clocks_sequences_and_incomplete_hashes_fail_closed(self):
        for rows in [[row(59, 0, 1), row(58, 0, 2)],
                     [row(58, 0, 1), row(59, 0, 1)],
                     [row(59, 0, 1, '')]]:
            with self.assertRaises(ValueError):
                summarize(rows, 60)


if __name__ == '__main__':
    unittest.main()
