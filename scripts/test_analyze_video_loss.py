import tempfile
from pathlib import Path
import unittest

from analyze_video_loss import direction, read_trace


def packet(seq, at, stage='s', result=0):
    return dict(ssrc=7, seq=seq, timestamp=seq, at_us=at, stage=stage,
                result=result, payload=1, bytes=13, marker=1)


def report(highest, lost, fraction, at):
    return dict(reporter=8, ssrc=7, fraction=fraction, lost=lost,
                highest=highest, jitter=0, lsr=0, dlsr=0,
                stage='s', at_us=at, result=0)


class VideoLossTest(unittest.TestCase):
    def test_late_packet_and_local_rejection_are_distinct(self):
        sends = [packet(i, i-99, result=int(i == 104)) for i in range(100, 106)]
        deliveries = [packet(i, t, 'd') for i, t in [(100, 6), (102, 12), (101, 55), (103, 62), (105, 76)]]
        receives = [dict(r, stage='r', at_us=r['at_us']-1) for r in deliveries]
        reports = [report(100, 0, 0, 7), report(102, 1, 127, 20),
                   report(102, 0, 0, 56), report(103, 0, 0, 65), report(105, 1, 127, 80)]
        result = direction(dict(rtp=sends, rr=[]), dict(rtp=receives+deliveries, rr=reports))
        self.assertEqual(result['accepted_not_received'], [])
        self.assertEqual(result['loss_report_count'], 2)
        self.assertEqual(result['loss_reports'][0]['gaps'][0]['later_delivered_after_report_ms'], .035)
        last = result['loss_reports'][1]
        self.assertEqual(last['fraction_from_report_deltas'], 127)
        self.assertEqual(last['gaps'][0]['source_rejected'], 1)
        self.assertEqual(last['gaps'][0]['source_accepted'], 0)

    def test_repeated_nonzero_fraction_with_unchanged_range_is_visible(self):
        rows = [packet(100, 1), packet(102, 3)]
        receiver = [dict(r, stage=stage, at_us=r['at_us']+1)
                    for r in rows for stage in ['r', 'd']]
        reports = [report(100, 0, 0, 3), report(102, 1, 127, 5), report(102, 1, 127, 6)]
        result = direction(dict(rtp=rows, rr=[]), dict(rtp=receiver, rr=reports))
        self.assertTrue(result['loss_reports'][1]['unchanged_range_and_loss'])
        self.assertEqual(result['loss_reports'][1]['fraction_from_report_deltas'], 0)

    def test_receiver_first_packet_after_wrap_is_not_a_65536_packet_gap(self):
        sends = [packet(65535, 1), packet(0, 2), packet(1, 3)]
        receiver = [dict(r, stage=stage, at_us=r['at_us']+1)
                    for r in sends[1:] for stage in ['r', 'd']]
        result = direction(dict(rtp=sends, rr=[]), dict(rtp=receiver, rr=[report(0,0,0,3), report(1,0,0,5)]))
        self.assertEqual(result['accepted_not_received'], [(-1, 65535)])

    def test_truncation_and_missing_footer_never_qualify(self):
        with tempfile.TemporaryDirectory() as root:
            p=Path(root)/'trace'
            p.write_text('video.loss.begin id=1 packets=0 packet_seen=1 reports=0 report_seen=0 malformed=0\nvideo.loss.end id=1 write_ok=1\n')
            with self.assertRaisesRegex(ValueError, 'truncated'):
                read_trace(p)
            p.write_text('video.loss.begin id=1 packets=0 packet_seen=0 reports=0 report_seen=0 malformed=0\n')
            with self.assertRaises(ValueError): read_trace(p)


if __name__ == '__main__': unittest.main()
