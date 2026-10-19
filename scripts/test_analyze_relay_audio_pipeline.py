import unittest

from analyze_relay_audio_pipeline import analyze


class AudioPipelineTest(unittest.TestCase):
    def fixture(self):
        summary = dict(loopback_only=True, stand_start_monotonic_us=0, duration_seconds=60)
        lines = '''audio.rtp.anchor source=0 ssrc=7 offset=48
audio.encode.begin ssrc=7 count=1 limit=24000 inputs=2 seen=1 rtp_hz=48000
audio.encode ssrc=7 timestamp=4294967280 first_us=21001000 first_index=0 encoded_us=21012000 blocks=2 bytes=20
audio.rtp.send.begin count=1 limit=24000 ssrc=7
audio.rtp.send seq=4 timestamp=32 attempted_us=21014000 admitted_us=21015000 accepted=1
audio.rtp.ingress.begin count=1 limit=24000 ssrc=7
audio.rtp.ingress seq=4 timestamp=32 arrived_us=21035000 drained_us=21036000 payload_bytes=20'''.splitlines()
        pcm = [dict(side=0, source_tick=i, source_at=21+i*.01, t=21.0005+i*.01,
                    source_freq=1000, freq=0, rms=0) for i in range(2)]
        pcm.append(dict(side=1, source_tick=0, source_at=21.049, t=21.05,
                        source_freq=500, freq=1000, rms=10000))
        return summary, lines, pcm

    def test_actual_offset_and_input_index_join_across_timestamp_wrap(self):
        result = analyze(*self.fixture())
        self.assertEqual(result['capture_index_verified'], {'0': True})
        self.assertEqual(result['attributed_edges'], 1)
        self.assertEqual(result['unmatched_payload_rows'], 0)
        self.assertFalse(result['native_trace_limit_may_have_been_reached'])
        edge = result['largest_pcm_edges'][0]
        self.assertEqual(edge['total_ms'], 50.)
        self.assertEqual(edge['spans_ms'], dict(capture_to_encoded=12., encoded_to_send=2.,
            send_to_sdk=1., sdk_to_ingress=20., ingress_to_webrtc=1., webrtc_to_pcm_edge=14.))

    def test_wrong_offset_is_not_guessed_from_packet_order(self):
        summary, lines, pcm = self.fixture()
        lines[0] = lines[0].replace('offset=48', 'offset=49')
        result = analyze(summary, lines, pcm)
        self.assertEqual(result['attributed_edges'], 0)
        self.assertEqual(result['unmatched_payload_rows'], 1)

    def test_optional_render_trace_joins_the_exact_wrapped_marker(self):
        summary, lines, pcm = self.fixture()
        lines += '''audio.playout.begin count=2 observed=2 limit=8
audio.playout entered_us=21040000 exited_us=21040020 rtp_timestamp=4294967088 speech_type=0 muted=0 skipped=0 fallback=0
audio.playout entered_us=21050000 exited_us=21050020 rtp_timestamp=272 speech_type=0 muted=0 skipped=0 fallback=0
audio.rtp.begin count=1 observed=1 limit=8
audio.rtp received_us=21036001 ssrc=7 sequence=4 rtp_timestamp=32'''.splitlines()
        result = analyze(summary, lines, pcm)
        self.assertTrue(result['native_playout_trace_present'])
        edge = result['largest_pcm_edges'][0]
        self.assertEqual(edge['total_ms'], 50.)
        self.assertEqual(edge['render_clock']['marker_rtp_timestamp'], 32)
        self.assertEqual(edge['render_clock']['source_to_clock_bracket_ms'], [40.02, 50.02])
        # The original signal edge remains the gate. A frame clock does not
        # prove exactly when the codec emits that tone's samples.
        self.assertEqual(edge['render_clock']['clock_bracket_to_pcm_edge_ms'], [-.02, 9.98])

    def test_missing_input_cannot_qualify_capture_index_alignment(self):
        summary, lines, pcm = self.fixture()
        result = analyze(summary, lines, pcm[1:])
        self.assertEqual(result['capture_index_verified'], {'0': False})
        self.assertEqual(result['attributed_edges'], 0)

    def test_ambiguous_anchor_and_reversed_clocks_are_rejected(self):
        summary, lines, pcm = self.fixture()
        with self.assertRaisesRegex(ValueError, 'Ambiguous'):
            analyze(summary, lines+[lines[0]], pcm)
        with self.assertRaisesRegex(ValueError, 'clock order'):
            analyze(summary, [x.replace('encoded_us=21012000', 'encoded_us=21016000') for x in lines], pcm)

    def test_missing_ingress_does_not_manufacture_a_receiver_span(self):
        summary, lines, pcm = self.fixture()
        result = analyze(summary, lines[:-1], pcm)
        self.assertEqual(result['attributed_edges'], 0)
        self.assertEqual(result['unattributed_edges']['input_packet_not_observed_at_receiver'], 1)


if __name__ == '__main__':
    unittest.main()
