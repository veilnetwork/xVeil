"""Trace retention must not alter blind FIFO admission or its byte schedule."""
import unittest
from unittest.mock import patch

from udp_fifo_shaper import UdpShaper


class TraceRetentionTest(unittest.TestCase):
    def test_capacity_only_changes_retained_metadata(self):
        shapers = [UdpShaper(('127.0.0.1', 9), trace=True, trace_capacity=n)
                   for n in (3, 20)]
        try:
            # Freeze the real worker before comparing deterministic admissions;
            # stop() joins it and closes every owned socket.
            for shaper in shapers:
                shaper.stop()
                shaper.rate_bps = 1024000
            with patch('udp_fifo_shaper.time.monotonic', return_value=10.0):
                for shaper in shapers:
                    for i in range(12):
                        shaper.enqueue(0, None, None, bytes(1000 + i), 0)
            left, right = shapers
            self.assertEqual(left.stats, right.stats)
            self.assertEqual(left.next_at, right.next_at)
            self.assertEqual([row[:5] for row in left.queues[0]],
                             [row[:5] for row in right.queues[0]])
            self.assertEqual(left.trace_events, 12)
            self.assertEqual(right.trace_events, 12)
            self.assertEqual(len(left.trace_rows), 3)
            self.assertEqual(len(right.trace_rows), 12)
            self.assertEqual(list(left.trace_rows), list(right.trace_rows)[-3:])
            self.assertFalse(any(key in row for row in right.trace_rows
                                 for key in ('data', 'address', 'role')))
        finally:
            for shaper in shapers:
                if shaper.worker.is_alive():
                    shaper.stop()

    def test_capacity_is_bounded_before_opening_sockets(self):
        for capacity in (0, -1, 1000001, True, '100'):
            with self.subTest(capacity=capacity):
                with patch('udp_fifo_shaper.socket.socket') as opened:
                    with self.assertRaises(ValueError):
                        UdpShaper(('127.0.0.1', 9), trace=True,
                                  trace_capacity=capacity)
                    opened.assert_not_called()


if __name__ == '__main__':
    unittest.main()
