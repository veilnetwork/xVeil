import unittest

from analyze_direct_source import attribute
from analyze_source_frame import frame_charge


class SourceFrameTest(unittest.TestCase):
    def setUp(self):
        self.native, self.seals, self.decisions = [], [], []
        # Actual packet sizes from the physical seven-cell regression. The
        # RTP sequence crosses wrap to exercise ordering by owned cell nonce.
        for i, raw in enumerate([930, 930, 930, 931, 931, 931, 931]):
            packet = dict(stage='s', ssrc=7, seq=(65533 + i) % 65536,
                          timestamp=9, payload=raw - 20, result=0,
                          at_us=1000 + i, bytes=raw, marker=int(i == 6))
            self.native.append(packet)
            self.native.append(dict(packet, at_us=5000 + i))
            seal = dict(stage='sealed', ssrc='7', rtp_seq=str(packet['seq']),
                        timestamp='9', payload_bytes=str(packet['payload']),
                        monotonic_us=str(1100 + i), epoch='1234567890abcdef',
                        seq=str(1137 + i))
            self.seals.append(seal)
            self.decisions.append(dict(epoch=seal['epoch'], seq=seal['seq'],
                                       local_slot='2', monotonic_us=str(1200 + i),
                                       stage='budget_drop', wire_bytes=str(raw + 316)))
        self.frames = [dict(epoch=self.seals[0]['epoch'], first_seq='1137',
                            last_seq='1143', cells='7', planned_cells='7',
                            expired_cells='0', packets='7', raw_bytes='6514',
                            sealed_bytes='6766', contiguous='true', local_slot='2')]
        self.anchor = attribute(self.native[:2], self.seals, self.decisions)

    def run_frame(self):
        return frame_charge(self.native, self.seals, self.decisions, self.frames, self.anchor)

    def test_exact_captured_work_cost_includes_all_seals_and_envelopes_once(self):
        result = self.run_frame()
        self.assertEqual(result['raw_rtp_bytes'], 6514)
        self.assertEqual(result['sealed_bytes'], 6766)
        self.assertEqual(result['seal_bytes_per_cell'], 36)
        self.assertEqual(result['envelope_bytes_per_cell'], 280)
        self.assertEqual(result['whole_work_charge_bytes'], 8726)
        self.assertTrue(all(p['source_verdict'] == 'budget_drop' for p in result['first_attempts']))

    def test_partial_expired_or_ambiguous_frame_cannot_establish_a_cost(self):
        original = self.frames[0]
        for fields in [dict(expired_cells='1'), dict(planned_cells='8'),
                       dict(contiguous='false'), dict(packets='8')]:
            self.frames = [dict(original, **fields)]
            with self.assertRaises(ValueError): self.run_frame()
        for frames in [[], [original, original]]:
            self.frames = frames
            with self.assertRaises(ValueError): self.run_frame()

    def test_missing_first_attempt_seal_cannot_be_replaced_by_retransmission(self):
        self.seals[2]['monotonic_us'] = '5102'
        with self.assertRaisesRegex(ValueError, 'seal'): self.run_frame()

    def test_nonuniform_route_and_mismatched_byte_totals_are_refused(self):
        self.decisions[2]['wire_bytes'] = '1300'
        with self.assertRaisesRegex(ValueError, 'uniform'): self.run_frame()
        self.decisions[2]['wire_bytes'] = '1246'
        self.frames[0]['raw_bytes'] = '6515'
        with self.assertRaisesRegex(ValueError, 'byte counts'): self.run_frame()

    def test_missing_marker_and_foreign_ownership_are_refused(self):
        self.native[-2]['marker'] = self.native[-1]['marker'] = 0
        with self.assertRaisesRegex(ValueError, 'marker'): self.run_frame()
        self.native[-2]['marker'] = self.native[-1]['marker'] = 1
        self.frames[0]['local_slot'] = '3'
        with self.assertRaisesRegex(ValueError, 'ownership'): self.run_frame()


if __name__ == '__main__': unittest.main()
