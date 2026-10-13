import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('source_frames', Path(__file__).with_name('analyze-source-frames.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def frame(first=1, last=2, **changes):
    fields = dict(local_slot=2, epoch='0123', first_seq=first, last_seq=last,
                  cells=last-first+1, planned_cells=last-first+1, expired_cells=0,
                  packets=last-first+1, raw_bytes=1200, contiguous='true', sequence_limit=4096)
    fields.update(changes)
    return 'media.source_frame_trace '+ ' '.join(f'{k}={v}' for k, v in fields.items())+'\n'


def cell(n, stage='budget_admit'):
    return f'media.source_cell_trace local_slot=2 epoch=0123 seq={n} wire_bytes=1000 stage={stage}\n'


class SourceFrames(unittest.TestCase):
    def test_partial_frame_is_not_reported_as_end_to_end_packet_loss(self):
        result = module.analyze(frame(last=12)+''.join(cell(n) for n in range(1, 8))+
                                ''.join(cell(n, 'budget_drop') for n in range(8, 13)))
        self.assertEqual(result['partially_shed_source_frames'], 1)
        self.assertTrue(result['complete_within_declared_scope'])
        self.assertTrue(result['admission_is_not_delivery'])
        self.assertEqual(result['observed_frame_wire_bytes']['max'], 12000)

    def test_later_expiry_is_not_counted_as_surviving_admission(self):
        result = module.analyze(frame()+cell(1)+cell(1, 'queue_expired')+cell(2, 'queue_expired'))
        self.assertEqual(result['partially_shed_source_frames'], 0)
        self.assertEqual(result['fully_shed_source_frames'], 1)

    def test_missing_trace_rows_are_unknown(self):
        result = module.analyze(frame()+cell(1))
        self.assertEqual(result['unobserved_cells'], 1)
        self.assertEqual(result['partially_shed_source_frames'], 0)
        self.assertFalse(result['complete_within_declared_scope'])

    def test_native_expiry_and_nonce_range_boundary_are_separate(self):
        result = module.analyze(frame(expired_cells=1, planned_cells=3)+cell(1)+cell(2)+
                                frame(4096, 4097)+cell(4096))
        self.assertEqual(result['native_partial_expiry_frames'], 1)
        self.assertEqual(result['boundary_or_noncontiguous_rows'], 1)

    def test_noncontiguous_frames_and_capped_diagnostics_cannot_prove_completeness(self):
        result = module.analyze(frame(contiguous='false')+cell(1)+cell(2))
        self.assertEqual(result['bounded_frames'], 0)
        self.assertFalse(result['complete_within_declared_scope'])
        result = module.analyze(frame()+cell(1)+cell(2)+frame(3, 4, contiguous='false'))
        self.assertFalse(result['complete_within_declared_scope'])
        self.assertEqual(result['noncontiguous_rows'], 1)
        result = module.analyze(frame()+cell(1)+cell(2)+'media.source_trace_limit rows=65536')
        self.assertTrue(result['trace_capped'])
        self.assertFalse(result['complete_within_declared_scope'])

    def test_repeated_admission_does_not_charge_wire_size_twice(self):
        result = module.analyze(frame()+cell(1)+cell(1)+cell(2))
        self.assertEqual(result['observed_frame_wire_bytes']['max'], 2000)


if __name__ == '__main__':
    unittest.main()
