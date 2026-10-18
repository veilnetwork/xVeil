import tempfile
import unittest
from pathlib import Path

from analyze_video_cc import read_cc


class ControllerTraceTest(unittest.TestCase):
    def parse(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'trace'
            path.write_text(text)
            return read_cc(path)

    def test_large_clock_and_multiple_controllers_stay_separate(self):
        text = ''.join(f'video.cc.begin id={i} rows=1 seen=1\n'
                       f'video.cc.sample id={i} at_us=166214345949\n'
                       f'video.cc.end id={i} write_ok=1\n' for i in [1, 2])
        r = self.parse(text)
        self.assertEqual(set(r), {1, 2})
        self.assertEqual(r[1]['samples'][0]['at_us'], 166214345949)

    def test_partial_truncated_or_repeated_captures_are_refused(self):
        valid = ('video.cc.begin id=1 rows=1 seen=1\n'
                 'video.cc.sample id=1 at_us=166214345949\n'
                 'video.cc.end id=1 write_ok=1\n')
        for text in ['', valid.replace('seen=1', 'seen=2'),
                     valid.replace('write_ok=1', 'write_ok=0'),
                     valid.rsplit('video.cc.end', 1)[0], valid + valid,
                     valid.replace('rows=1 seen=1', 'rows=2 seen=2').replace(
                         'video.cc.end', 'video.cc.sample id=1 at_us=166214345949\nvideo.cc.end')]:
            with self.assertRaises(ValueError):
                self.parse(text)


if __name__ == '__main__':
    unittest.main()
