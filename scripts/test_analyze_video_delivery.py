import unittest

from analyze_video_delivery import audit, analyze


def packet(stage='s', at_us=1_000_000, seq=7, payload=20, result=0):
    return dict(stage=stage, at_us=at_us, seq=seq, payload=payload,
                result=result, ssrc=1, timestamp=9)


class VideoDeliveryTest(unittest.TestCase):
    def test_late_retry_cannot_hide_original_in_call_loss(self):
        result = audit([packet(), packet(at_us=11_000_000)], 0, 10)
        self.assertEqual(result['in_call_missing_payload'], 1)
        self.assertEqual(result['missing'][0]['accepted_attempts'], 2)
        self.assertEqual(result['missing'][0]['first_accepted_seconds'], 1)

    def test_failed_original_does_not_make_late_acceptance_in_call(self):
        result = audit([packet(result=-1), packet(at_us=11_000_000)], 0, 10)
        self.assertEqual(result['in_call_missing_payload'], 0)
        self.assertEqual(result['missing'][0]['scope'], 'after_capture_end')

    def test_padding_and_shutdown_are_explicitly_separate(self):
        rows = [packet(payload=0), packet(seq=8, at_us=8_000_000),
                packet(seq=9, at_us=10_000_000)]
        result = audit(rows, 0, 10)
        self.assertEqual(result['in_call_missing_payload'], 0)
        self.assertEqual(result['in_call_missing_padding'], 1)
        self.assertEqual([r['scope'] for r in result['missing']],
                         ['in_call', 'tail_censored', 'after_capture_end'])

    def test_ingress_and_native_delivery_are_different_witnesses(self):
        result = audit([packet(), packet('r'), packet(seq=8),
                        packet('r', seq=8), packet('d', seq=8)], 0, 10)
        self.assertEqual(result['successful_not_observed_at_ingress'], 0)
        self.assertEqual(result['received_not_delivered'], 1)

    def test_packet_identity_includes_timestamp_and_payload(self):
        rows = [packet(), dict(packet('r'), timestamp=10), packet('r', payload=0)]
        self.assertEqual(audit(rows, 0, 10)['in_call_missing_payload'], 1)

    def test_never_infer_cross_device_clock_alignment(self):
        with self.assertRaisesRegex(ValueError, 'clock'):
            analyze(None)


if __name__ == '__main__':
    unittest.main()
