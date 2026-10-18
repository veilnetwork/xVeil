import unittest

from analyze_group_audio_peak import attribute, capture_phase_name


class GroupPeakTest(unittest.TestCase):
    def fixture(self):
        # Two encoder lifetimes both start at input index zero. The sender's
        # actual offset wraps the second packet's RTP timestamp to 1904.
        source = '''audio.encode.begin ssrc=7 count=1 limit=8 inputs=4 seen=1 rtp_hz=48000
audio.encode ssrc=7 timestamp=0 first_us=1000000 first_index=0 encoded_us=1035000 blocks=4 bytes=40
audio.encode.begin ssrc=7 count=1 limit=8 inputs=4 seen=1 rtp_hz=48000
audio.encode ssrc=7 timestamp=1920 first_us=1040000 first_index=0 encoded_us=1078000 blocks=4 bytes=40'''.splitlines()
        receiver = '''audio.rtp.ingress.begin count=1 limit=8 ssrc=7
audio.rtp.ingress seq=9 timestamp=1904 arrived_us=1100000 drained_us=1100020 payload_bytes=40'''.splitlines()
        captures = [dict(source_at=1+i/100) for i in range(10)]
        peak = dict(source_at_seconds=1.06, decoded_at_seconds=1.15)
        codec = [dict(sender=dict(rtp_origin=4294967280))]
        return peak, 0, captures, codec, source, receiver

    def test_encoder_restart_uses_capture_clock_and_actual_rtp_offset(self):
        result = attribute(*self.fixture())
        self.assertEqual(result['encoder_input_index'], 0)
        self.assertEqual(result['rtp_timestamp'], 1904)
        self.assertAlmostEqual(result['total_ms'], 90)
        expected = dict(capture_to_encoded=18, encoded_to_ingress=22,
                        ingress_to_webrtc=.02, webrtc_to_pcm_edge=49.98)
        for name, value in expected.items():
            self.assertAlmostEqual(result['spans_ms'][name], value)

    def test_missing_or_duplicate_receiver_packet_is_not_guessed(self):
        args = list(self.fixture())
        for receiver in [args[-1][:-1], args[-1]+args[-1]]:
            with self.assertRaises(ValueError):
                attribute(*args[:-1], receiver)

    def test_wrong_or_changing_rtp_origin_is_rejected(self):
        args = list(self.fixture())
        for codec in [[dict(sender=dict(rtp_origin=4294967279))],
                      args[3]+[dict(sender=dict(rtp_origin=100))]]:
            args[3] = codec
            with self.assertRaises(ValueError):
                attribute(*args)

    def test_truncated_encoder_or_receiver_logs_cannot_qualify_peak(self):
        for index in (4, 5):
            args = list(self.fixture())
            args[index] = [line.replace('count=1', 'count=2') for line in args[index]]
            with self.assertRaisesRegex(ValueError, 'Incomplete'):
                attribute(*args)

    def test_reversed_pipeline_or_ambiguous_capture_is_rejected(self):
        args = list(self.fixture())
        args[-1] = [line.replace('drained_us=1100020', 'drained_us=1090000')
                    for line in args[-1]]
        with self.assertRaisesRegex(ValueError, 'clock order'):
            attribute(*args)
        args = list(self.fixture())
        args[2].append(dict(source_at=1.06))
        with self.assertRaisesRegex(ValueError, 'ambiguous capture'):
            attribute(*args)

    def test_diagnostic_load_labels_preserve_full_contention_distinction(self):
        for kind in ('both', 'files', 'video'):
            summary = dict(video_file_load=kind == 'both', load_kind=kind)
            self.assertEqual(capture_phase_name(summary, 'audio-only'), 'audio-only')
            self.assertEqual(capture_phase_name(summary, 'audio-video-file'),
                             'audio-video-file' if kind == 'both' else 'audio-'+kind)
        with self.assertRaisesRegex(ValueError, 'Unknown'):
            capture_phase_name(dict(video_file_load=True, load_kind='unknown'),
                               'audio-video-file')
        with self.assertRaisesRegex(ValueError, 'Inconsistent'):
            capture_phase_name(dict(video_file_load=True, load_kind='files'),
                               'audio-video-file')

    def fanout_fixture(self):
        args = list(self.fixture())
        args[4] += '''audio.group.send.begin ssrc=7 count=2 limit=8 seen=2
audio.group.send channel=100 seq=9 timestamp=1904 attempted_us=1079000 admitted_us=1080000 packet_bytes=52 accepted=1
audio.group.send channel=200 seq=9 timestamp=1904 attempted_us=1081000 admitted_us=1082000 packet_bytes=52 accepted=1'''.splitlines()
        return args

    def test_fanout_copy_is_joined_by_receiver_channel(self):
        result = attribute(*self.fanout_fixture(), source_channel=200)
        self.assertEqual(result['native_send']['channel'], 200)
        self.assertEqual(result['native_send_spans_ms'], dict(
            encoded_to_native_send=3, native_send_admission=1,
            native_admission_to_ingress=18))
        self.assertAlmostEqual(sum(result['native_send_spans_ms'].values()),
                               result['spans_ms']['encoded_to_ingress'])

    def test_missing_channel_mapping_never_guesses_a_fanout_copy(self):
        for channel in (None, 0, -1, 300):
            with self.assertRaises(ValueError):
                attribute(*self.fanout_fixture(), source_channel=channel)

    def test_wrong_sequence_rejected_even_when_timestamp_matches(self):
        args = self.fanout_fixture()
        args[4] = [line.replace('channel=200 seq=9', 'channel=200 seq=10')
                   for line in args[4]]
        with self.assertRaisesRegex(ValueError, 'native fanout send'):
            attribute(*args, source_channel=200)

    def test_wrong_native_group_ssrc_does_not_silently_skip_attribution(self):
        args = self.fanout_fixture()
        args[4] = [line.replace('audio.group.send.begin ssrc=7',
                               'audio.group.send.begin ssrc=8')
                   for line in args[4]]
        with self.assertRaisesRegex(ValueError, 'Missing native trace'):
            attribute(*args, source_channel=200)

    def test_rejected_or_reversed_or_truncated_native_send_is_not_attributed(self):
        for before, after in [('accepted=1', 'accepted=0'),
                              ('admitted_us=1082000', 'admitted_us=1080000'),
                              ('admitted_us=1082000', 'admitted_us=1101000'),
                              ('seen=2', 'seen=3')]:
            args = self.fanout_fixture()
            args[4] = [line.replace(before, after) for line in args[4]]
            with self.assertRaises(ValueError):
                attribute(*args, source_channel=200)


if __name__ == '__main__':
    unittest.main()
