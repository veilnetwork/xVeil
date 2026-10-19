import unittest

from audio_render_timing import attribute_render, playout_streams


class RenderClockTest(unittest.TestCase):
    def fixture(self):
        lines = ['audio.playout.begin count=4 observed=4 limit=64']
        for at, stamp in zip(range(1000000, 1040000, 10000),
                             [4294966816, 0, 480, 960]):
            lines.append(f'audio.playout entered_us={at} exited_us={at+20} '
                         f'rtp_timestamp={stamp} speech_type=0 muted=0 skipped=0 fallback=0')
        lines += ['audio.rtp.begin count=1 observed=1 limit=64',
                  'audio.rtp received_us=950000 ssrc=7 sequence=42 rtp_timestamp=4294966816']
        return lines

    def attribute(self, lines=None, **changes):
        args = dict(ssrc=7, packet_timestamp=4294966816, sequence=42,
                    marker_timestamp=240, rtp_hz=48000, source_us=900000,
                    pcm_edge_us=1030020)
        args.update(changes)
        return attribute_render(playout_streams(self.fixture() if lines is None else lines), **args)

    def test_actual_output_clock_wrap_and_later_signal_are_kept_separate(self):
        result = self.attribute()
        self.assertTrue(result['continuous_normal_speech'])
        self.assertEqual(result['source_to_clock_bracket_ms'], [110.02, 120.02])
        self.assertEqual(result['insertion_to_clock_bracket_ms'], [60.02, 70.02])
        self.assertEqual(result['clock_bracket_to_pcm_edge_ms'], [10., 20.])
        self.assertFalse(result['signal_output_proof'])

    def test_exact_frame_clock_needs_no_interpolation(self):
        result = self.attribute(marker_timestamp=480)
        self.assertEqual(result['source_to_clock_bracket_ms'], [120.02, 120.02])

    def test_relative_age_uses_only_recent_past_arrivals_without_sender_clock(self):
        lines = self.fixture()
        lines[-2] = lines[-2].replace('count=1 observed=1', 'count=3 observed=3')
        lines += ['audio.rtp received_us=40000 ssrc=7 sequence=41 rtp_timestamp=4294923136',
                  'audio.rtp received_us=1040000 ssrc=7 sequence=43 rtp_timestamp=9600']
        result = self.attribute(lines)['relative_arrival_clock']
        self.assertEqual(result['packet_count'], 2)
        self.assertEqual(result['floor_witness']['sequence'], 42)
        self.assertEqual(result['clock_age_ms'], [50.02, 50.02])
        self.assertFalse(result['absolute_one_way_latency'])
        # Shifting this entire host's clock cannot change the relative age.
        shifted = [line for line in lines]
        import re
        shifted = [re.sub(r'(entered_us|exited_us|received_us)=(\d+)',
                         lambda m: f'{m[1]}={int(m[2])+50000000}', line) for line in shifted]
        moved = self.attribute(shifted, source_us=50900000,
                               pcm_edge_us=51030020)['relative_arrival_clock']
        self.assertEqual(moved['clock_age_ms'], result['clock_age_ms'])

    def test_no_trace_or_missing_stream_does_not_guess(self):
        self.assertIsNone(self.attribute([]))
        self.assertEqual(self.attribute(ssrc=8)['reason'], 'missing_receiver_stream')
        self.assertEqual(self.attribute(source_us=1025000)['reason'], 'marker_clock_not_bracketed')

    def test_concealment_or_recovery_crossing_cannot_prove_normal_speech(self):
        for old, new in [('speech_type=0', 'speech_type=1'),
                         ('muted=0', 'muted=1'), ('skipped=0', 'skipped=2'),
                         ('rtp_timestamp=480 ', 'rtp_timestamp=4800 ')]:
            lines = self.fixture()
            lines[3] = lines[3].replace(old, new)
            self.assertFalse(self.attribute(lines)['continuous_normal_speech'])

    def test_truncation_ambiguous_stream_and_clock_corruption_are_rejected(self):
        lines = self.fixture()
        for broken in [[line.replace('observed=4', 'observed=5') for line in lines],
                       lines[:-1], lines+lines,
                       [line.replace('exited_us=1010020', 'exited_us=1000000') for line in lines],
                       [line.replace('exited_us=1010020', 'exited_us=1030020') for line in lines],
                       [line.replace('entered_us=1010000', 'entered_us=1000000') for line in lines]]:
            with self.assertRaises(ValueError):
                self.attribute(broken)

    def test_packet_timestamp_and_sequence_must_both_match(self):
        for change in [dict(packet_timestamp=4294966815), dict(sequence=41)]:
            with self.assertRaisesRegex(ValueError, 'packet insertion'):
                self.attribute(**change)
        lines = self.fixture()
        lines[-2] = lines[-2].replace('count=1 observed=1', 'count=2 observed=2')
        with self.assertRaisesRegex(ValueError, 'ambiguous decoder'):
            self.attribute(lines+[lines[-1]])

    def test_interleaved_log_record_cannot_be_reconstructed_as_evidence(self):
        lines = self.fixture()
        lines[2] = lines[2].replace('exited_us=1010020', 'exited_utest video: pushed 60 frames\ns=1010020')
        # The real line reader sees two broken lines, not one repaired row.
        with self.assertRaisesRegex(ValueError, 'Malformed playout'):
            self.attribute('\n'.join(lines).splitlines())


if __name__ == '__main__':
    unittest.main()
