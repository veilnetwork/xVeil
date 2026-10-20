"""Trace retention must not alter blind FIFO admission or its byte schedule."""
import gc
import unittest
from unittest.mock import patch

from udp_fifo_shaper import UdpShaper, WireTrace


class TraceRetentionTest(unittest.TestCase):
    def test_completed_rows_roundtrip_and_late_completion_after_wrap(self):
        trace = WireTrace(2)
        old = trace.add({'at': 1.0, 'direction': 0, 'link': 2, 'bytes': 100,
                         'pending': 0, 'ready': 1.1, 'queue_ms': 100.0})
        sent = trace.add({'at': 2.0, 'direction': 1, 'link': 0, 'bytes': 200,
                          'pending': 1, 'ready': 2.1, 'queue_ms': 100.0})
        sent.update(sent_at=2.101, release_lateness_ms=1.0)
        trace.finish(sent)
        dropped = trace.add({'at': 3.0, 'direction': 0, 'link': 1, 'bytes': 300,
                             'pending': 2, 'queue_ms': 200.0, 'dropped': True})
        trace.finish(dropped)
        old.update(sent_at=3.1, release_lateness_ms=2000.0)
        trace.finish(old)  # The first row has already been evicted.
        self.assertEqual(list(trace), [dict(sent), dict(dropped)])
        self.assertIs(type(list(trace)[0]['bytes']), int)
        self.assertIs(type(list(trace)[1]['dropped']), bool)
        self.assertNotIn('sent_at', list(trace)[1])

    def test_retained_archive_does_not_grow_the_gc_object_graph_per_packet(self):
        shaper = UdpShaper(('127.0.0.1', 9), trace=True, trace_capacity=5000)
        shaper.stop()
        shaper.rate_bps = 1
        shaper.max_queue_ms = 1
        # One queued packet; all following arrivals are dropped and complete
        # immediately. Retaining their metadata must not leave 5000 mutable
        # containers for the collector to walk during a timed capture.
        gc.collect()
        before = len(gc.get_objects())
        for _ in range(5000):
            shaper.enqueue(0, None, None, bytes(1000), 0)
        after = len(gc.get_objects())
        self.assertLess(after - before, 100)
        self.assertEqual(shaper.trace_events, 5000)
        self.assertEqual(len(shaper.trace_rows), 5000)
        self.assertEqual(sum(row.get('dropped', False)
                             for row in shaper.trace_rows), 4999)

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
