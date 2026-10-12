"""Protect timing attribution against trace order, padding and clock ambiguity."""
import unittest

from analyze_relay_rtp_timing import analyze


class RtpTimingTest(unittest.TestCase):
    def test_pairs_by_packet_identity_not_stop_order_and_ignores_padding(self):
        # Receive block order is reversed relative to sender teardown order.
        rows = '''audio.rtp.send.begin count=2
audio.rtp.send seq=65535 timestamp=4294967200 attempted_us=21000000 admitted_us=21001000 accepted=1
audio.rtp.send seq=0 timestamp=860 attempted_us=21020000 admitted_us=21021000 accepted=1
audio.rtp.send.begin count=1
audio.rtp.send seq=4 timestamp=100 attempted_us=10000000 admitted_us=10001000 accepted=1
audio.rtp.ingress.begin count=1
audio.rtp.ingress seq=4 timestamp=100 arrived_us=10051000 drained_us=10052000 payload_bytes=20
audio.rtp.ingress.begin count=3
audio.rtp.ingress seq=65535 timestamp=4294967200 arrived_us=21301000 drained_us=21302000 payload_bytes=20
audio.rtp.ingress seq=0 timestamp=860 arrived_us=21071000 drained_us=21073000 payload_bytes=20
audio.rtp.ingress seq=8 timestamp=0 arrived_us=22000000 drained_us=22002000 payload_bytes=0'''
        result = analyze(dict(loopback_only=True, stand_start_monotonic_us=0,
                              duration_seconds=60), rows.splitlines())
        self.assertEqual(result['unmatched_payload_rows'], 0)
        competing, audio = result['phases']
        self.assertEqual((competing['source_trace_block'], competing['phase']), (0, 'competing'))
        self.assertEqual(competing['admitted_to_ingress'],
                         dict(count=2, max_ms=300., p95_ms=300.))
        self.assertEqual(competing['ingress_to_webrtc']['max_ms'], 2.)
        self.assertEqual(audio['admitted_to_ingress']['max_ms'], 50.)

    def test_refuses_ambiguous_packet_identity(self):
        row = 'audio.rtp.send seq=1 timestamp=100 attempted_us=10000000 admitted_us=10001000 accepted=1'
        with self.assertRaisesRegex(ValueError, 'Ambiguous'):
            analyze(dict(loopback_only=True, stand_start_monotonic_us=0,
                         duration_seconds=60),
                    ['audio.rtp.send.begin count=1', row,
                     'audio.rtp.send.begin count=1', row])

    def test_refuses_cross_device_clock_assumptions(self):
        with self.assertRaisesRegex(ValueError, 'same-process'):
            analyze(dict(loopback_only=False), [])

    def test_refuses_negative_transport_time(self):
        with self.assertRaisesRegex(ValueError, 'clock order'):
            analyze(dict(loopback_only=True, stand_start_monotonic_us=0,
                         duration_seconds=60), [
                'audio.rtp.send.begin count=1',
                'audio.rtp.send seq=1 timestamp=1 attempted_us=10000000 admitted_us=10001000 accepted=1',
                'audio.rtp.ingress.begin count=1',
                'audio.rtp.ingress seq=1 timestamp=1 arrived_us=10000000 drained_us=10002000 payload_bytes=20'])


if __name__ == '__main__':
    unittest.main()
