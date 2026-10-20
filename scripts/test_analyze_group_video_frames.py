import tempfile
from pathlib import Path
import unittest

from analyze_group_video_frames import originals, match_images, metadata


class FrameAttributionTest(unittest.TestCase):
    def test_padding_retries_and_other_peers_do_not_extend_original_span(self):
        def row(seq, at, payload=1, channel=7):
            return dict(stage='s', channel=channel, timestamp=5, seq=seq,
                        at_us=at, payload=payload, marker=int(seq == 2), result=0)
        rows = [row(1, 10), row(2, 30), row(1, 1000),
                row(3, 5000, payload=0), row(2, 9000, channel=8)]
        self.assertEqual([r['at_us'] for r in originals(rows, 7)[5]], [10, 30])
        with self.assertRaisesRegex(ValueError, 'Missing group'):
            originals([dict(r, channel=0) for r in rows], 7)

    def test_random_timestamp_offset_wrap_and_skipped_encoding(self):
        images = [dict(timestamp=0xfffffff0, at_us=1),
                  dict(timestamp=0, at_us=2), dict(timestamp=10, at_us=3)]
        frames = {0x10: [dict(at_us=1)], 0x2a: [dict(at_us=4)]}
        offset, mapping = match_images(images, frames)
        self.assertEqual(offset, 32)
        self.assertEqual(mapping[0x2a], images[2])

    def test_ambiguous_clock_offset_is_not_guessed(self):
        with self.assertRaisesRegex(ValueError, 'ambiguous'):
            match_images([dict(timestamp=1, at_us=1), dict(timestamp=2, at_us=2)],
                         {100: [dict(at_us=3)]})

    def test_partial_or_truncated_metadata_never_qualifies(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'metadata'
            header = 'video.decode.begin id=7 count=1 seen=1 ssrc=3\n'
            row = 'video.decode.frame id=7 timestamp=8 at_us=10 ssrc=3 width=80 height=60\n'
            footer = 'video.decode.end id=7 write_ok=1\n'
            path.write_text(header+row)
            with self.assertRaisesRegex(ValueError, 'Incomplete'):
                metadata(path, 'video.decode', 'frame')
            path.write_text(header.replace('seen=1', 'seen=2')+row+footer)
            with self.assertRaisesRegex(ValueError, 'truncated'):
                metadata(path, 'video.decode', 'frame')
            path.write_text(header+row+footer)
            self.assertEqual(metadata(path, 'video.decode', 'frame')[0]['timestamp'], 8)


if __name__ == '__main__':
    unittest.main()
