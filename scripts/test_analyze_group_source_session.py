import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from analyze_group_source_session import analyze, attribute


class SourceSessionTest(unittest.TestCase):
    def fixture(self):
        sdk = dict(epoch='0123456789abcdef', cell_sequence=5709, sealed_bytes=100,
                   observations_us=dict(handler_enter=100, relay_queued=110,
                                        sdk_authenticated=250))
        common = dict(epoch=sdk['epoch'], seq='5709', local_slot='0', wire_bytes='400',
                      body_len='300', family='1', msg_type='2', body_preview_sha256='a'*64)
        return sdk, [dict(common, stage='budget_admit', monotonic_us='120', connection_trace_id='0'),
                     dict(common, stage='datagram_accepted', monotonic_us='130', connection_trace_id='17')]

    def test_late_exact_cell_joins_to_source_connection(self):
        result = attribute(*self.fixture())
        self.assertEqual(result['connection_trace_id'], 17)
        self.assertEqual(result['spans_ms']['handler_enter_to_budget_admit'], .02)
        self.assertEqual(result['spans_ms']['budget_admit_to_authenticated_receiver'], .13)

    def test_missing_duplicate_or_other_fanout_cannot_guess(self):
        for mode in ('missing', 'duplicate', 'other_epoch'):
            sdk, rows = self.fixture()
            if mode == 'missing': rows.pop()
            elif mode == 'duplicate': rows.append(copy.deepcopy(rows[1]))
            else: rows[1]['epoch'] = 'fedcba9876543210'
            with self.assertRaisesRegex(ValueError, 'Missing or ambiguous'):
                attribute(sdk, rows)

    def test_remote_slot_and_frame_mismatch_are_rejected(self):
        for key, value in [('local_slot', '1'), ('wire_bytes', '401'),
                           ('body_len', '301'), ('body_preview_sha256', 'b'*64)]:
            sdk, rows = self.fixture()
            rows[1][key] = value
            with self.assertRaises(ValueError): attribute(sdk, rows)
        sdk, rows = self.fixture()
        for row in rows: row['local_slot'] = '1'
        with self.assertRaisesRegex(ValueError, 'private local primary'): attribute(sdk, rows)

    def test_unknown_reversed_or_unwitnessed_transport_is_rejected(self):
        for index, key, value in [(0, 'monotonic_us', '-1'), (0, 'monotonic_us', '99'),
                                  (1, 'monotonic_us', '119'), (1, 'connection_trace_id', '0')]:
            sdk, rows = self.fixture()
            rows[index][key] = value
            with self.assertRaises(ValueError): attribute(sdk, rows)

    def test_async_completion_offsets_are_not_fabricated_causal_spans(self):
        sdk, rows = self.fixture()
        sdk['observations_us']['relay_queued'] = 125
        rows[1]['monotonic_us'] = '260'
        result = attribute(sdk, rows)
        self.assertEqual(result['post_completion_offsets_ms']['relay_queued_to_budget_admit'], -.005)
        self.assertEqual(result['post_completion_offsets_ms']['datagram_accepted_to_authenticated_receiver'], -.01)

    def test_capture_loader_rejects_either_exhausted_trace_budget(self):
        sdk, rows = self.fixture()
        text = ''.join('media.source_cell_trace ' + ' '.join(
            key+'='+value for key, value in row.items())+'\n' for row in rows)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            with patch('analyze_group_source_session.analyze_sdk',
                       side_effect=lambda _: {'sdk': sdk, 'limits': []}):
                (path/'native.log').write_text(text)
                self.assertEqual(analyze(path)['source_session']['connection_trace_id'], 17)
                for marker in ('media.source_trace_limit', 'media.source_accepted_trace_limit'):
                    (path/'native.log').write_text(text+marker+' rows=65536\n')
                    with self.assertRaisesRegex(ValueError, 'truncated'):
                        analyze(path)


if __name__ == '__main__':
    unittest.main()
