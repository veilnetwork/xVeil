#!/usr/bin/env python3
"""Protect latency evidence against incomplete or ambiguous trace matching."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "audio_flight", Path(__file__).with_name("analyze-audio-flight.py"))
flight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flight)

SUMMARY = {"stand_start_monotonic_us": 1_000_000,
           "duration_seconds": 30, "video_requested": True}
SEND = ("audio.rtp.send seq=7 timestamp=48000 attempted_us=7000000 "
        "admitted_us=7000100 packet_bytes=40 accepted=1\n")
RECEIVE = ("audio.rtp.ingress seq=7 timestamp=48000 arrived_us=7020000 "
           "drained_us=7020500 payload_bytes=28\n")
TRACE = ("audio.rtp.send.begin count=1\n" + SEND +
         "audio.rtp.ingress.begin count=1\n" + RECEIVE)


class AudioFlightEvidenceTest(unittest.TestCase):
    def test_distinguishes_delivery_admission_and_native_queue(self):
        direction = flight.analyze(TRACE, SUMMARY)["directions"][0]
        phase = direction["phases"][0]
        self.assertEqual(phase["sdk_and_network"]["max_ms"], 20)
        self.assertEqual(phase["sdk_admission"]["max_ms"], .1)
        self.assertEqual(phase["native_drain"]["max_ms"], .5)
        self.assertEqual(direction["matched_nonempty_packets"], 1)

    def test_does_not_guess_between_colliding_or_replayed_sender_records(self):
        trace = TRACE.replace("send.begin count=1", "send.begin count=2")
        trace = trace.replace(SEND, SEND + SEND)
        direction = flight.analyze(trace, SUMMARY)["directions"][0]
        self.assertEqual(direction["ambiguous_trace_rows"], 1)
        self.assertEqual(direction["matched_nonempty_packets"], 0)
        self.assertIsNone(direction["phases"][0]["sdk_and_network"])

    def test_capped_or_rejected_send_is_unmatched_and_not_counted_as_loss(self):
        trace = TRACE.replace("accepted=1", "accepted=0")
        result = flight.analyze(trace, SUMMARY)
        self.assertTrue(result["capped_trace_rows_are_not_loss"])
        self.assertEqual(result["directions"][0]["unmatched_trace_rows"], 1)

    def test_rejects_truncated_dump(self):
        with self.assertRaisesRegex(ValueError, "incomplete"):
            flight.analyze(TRACE.replace(RECEIVE, ""), SUMMARY)

    def test_rejects_incompatible_clock_origin(self):
        summary = dict(SUMMARY, stand_start_monotonic_us=100_000_000)
        with self.assertRaisesRegex(ValueError, "origin"):
            flight.analyze(TRACE, summary)

    def test_rejects_receive_before_send(self):
        trace = TRACE.replace("arrived_us=7020000", "arrived_us=6000000")
        with self.assertRaisesRegex(ValueError, "negative"):
            flight.analyze(trace, SUMMARY)

    def test_cannot_shorten_a_recorded_stand_by_overriding_duration(self):
        with self.assertRaisesRegex(ValueError, "recorded stand duration"):
            flight.analyze(TRACE, SUMMARY, duration_seconds=25)


if __name__ == "__main__":
    unittest.main()
