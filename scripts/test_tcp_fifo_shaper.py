"""Real socket checks for aggregate shaping, byte integrity, EOF and shutdown."""
import asyncio
import collections
import concurrent.futures
import os
import socket
import threading
import time
import unittest

from tcp_fifo_shaper import ReaderArrivalTrace, TcpShaper


class TcpShaperTest(unittest.TestCase):
    def test_existing_buffer_is_unknown_and_partial_reads_preserve_arrival_segments(self):
        async def exercise():
            reader = asyncio.StreamReader(limit=4096)
            reader.feed_data(b'old')
            trace = ReaderArrivalTrace(reader)
            reader.feed_data(b'new-data')
            first = await reader.read(5)
            observed = trace.consume(len(first))
            self.assertEqual(first, b'oldne')
            self.assertEqual(observed['reader_arrival_unknown_bytes'], 3)
            self.assertIsNotNone(observed['oldest_byte_arrived_at'])
            second = await reader.read(6)
            rest = trace.consume(len(second))
            self.assertEqual(second, b'w-data')
            self.assertEqual(rest['reader_arrival_unknown_bytes'], 0)
            self.assertEqual(rest['oldest_byte_arrived_at'], observed['oldest_byte_arrived_at'])
            self.assertEqual(len(trace.segments), 0)
        asyncio.run(exercise())

    def test_competing_connections_share_rate_and_preserve_bytes(self):
        self.exercise_competing_connections('aggregate', False)

    def test_per_target_keeps_connections_on_one_target_shared(self):
        self.exercise_competing_connections('per-target', False)

    def test_distinct_targets_have_independent_capacity(self):
        self.exercise_competing_connections('per-target', True)

    def test_duplicate_targets_cannot_multiply_capacity(self):
        target = ('127.0.0.1', 1)
        with self.assertRaises(ValueError):
            TcpShaper([target, target], scope='per-target')

    def exercise_competing_connections(self, scope, distinct_targets):
        listeners = []
        for _ in range(2 if distinct_targets else 1):
            listener = socket.socket()
            listener.bind(('127.0.0.1', 0))
            listener.listen(2)
            listener.settimeout(8)
            listeners.append(listener)
        failures = []
        echoes = []

        def echo(conn):
            try:
                with conn:
                    conn.settimeout(8)
                    while data := conn.recv(4096):
                        conn.sendall(data)
            except Exception as error:
                failures.append(type(error).__name__)

        def serve():
            try:
                for index in range(2):
                    listener = listeners[index if distinct_targets else 0]
                    conn, _ = listener.accept()
                    thread = threading.Thread(target=echo, args=(conn,))
                    echoes.append(thread)
                    thread.start()
            except Exception as error:
                failures.append(type(error).__name__)

        server = threading.Thread(target=serve)
        server.start()
        targets = [listener.getsockname() for listener in listeners]
        shaper = TcpShaper(targets, trace=True, scope=scope)
        shaper.rate_bps = 128000
        barrier = threading.Barrier(2)
        payloads = [os.urandom(16384), os.urandom(16384)]

        def transfer(item):
            index, payload = item
            port = shaper.ports[index if distinct_targets else 0]
            with socket.create_connection(('127.0.0.1', port), 8) as conn:
                conn.settimeout(8)
                barrier.wait(timeout=3)
                began = time.monotonic()
                conn.sendall(payload)
                conn.shutdown(socket.SHUT_WR)
                # Both streams must retain bytes when their readers pause.
                time.sleep(.15)
                received = bytearray()
                while data := conn.recv(4096):
                    received.extend(data)
                return bytes(received), time.monotonic() - began

        try:
            with concurrent.futures.ThreadPoolExecutor(2) as pool:
                results = list(pool.map(transfer, enumerate(payloads)))
            self.assertEqual([data for data, _ in results], payloads)
            # 32 KiB across two connections share 128 kbit/s, rather than each
            # receiving that capacity. Allow clock precision and final chunk.
            elapsed = max(elapsed for _, elapsed in results)
            if distinct_targets:
                self.assertGreater(elapsed, .95)
                self.assertLess(elapsed, 1.9)
            else:
                self.assertGreater(elapsed, 1.9)
            self.assertIsNone(shaper.failure)
            for stat in shaper.stats:
                self.assertEqual(stat['sent_bytes'], 32768)
                self.assertEqual(stat['received_bytes'], 32768)
                self.assertEqual(stat['drops'], 0)
            by_direction = collections.defaultdict(list)
            for row in shaper.trace_rows:
                self.assertLessEqual(set(row), {
                    'at', 'direction', 'link', 'bytes', 'pending', 'ready',
                    'queue_ms', 'sent_at', 'release_lateness_ms', 'connection',
                    'read_at', 'reader_buffer_bytes', 'write_at',
                    'writer_buffer_bytes', 'kernel_reader_bytes',
                    'oldest_byte_arrived_at', 'newest_byte_arrived_at',
                    'reader_arrival_unknown_bytes'})
                self.assertLessEqual(row['read_at'], row['at'])
                self.assertLessEqual(row['ready'], row['write_at'])
                self.assertLessEqual(row['write_at'], row['sent_at'])
                self.assertGreaterEqual(row['reader_buffer_bytes'], 0)
                self.assertGreaterEqual(row['writer_buffer_bytes'], 0)
                self.assertGreaterEqual(row['reader_arrival_unknown_bytes'], 0)
                self.assertLessEqual(row['reader_arrival_unknown_bytes'], row['bytes'])
                if row['oldest_byte_arrived_at'] is not None:
                    self.assertLessEqual(row['oldest_byte_arrived_at'],
                                         row['newest_byte_arrived_at'])
                    self.assertLessEqual(row['newest_byte_arrived_at'], row['read_at'])
                group = (row['direction'], row['link'] if scope == 'per-target' else 0)
                by_direction[group].append(row)
            self.assertEqual(len({row['connection'] for row in shaper.trace_rows}), 2)
            for rows in by_direction.values():
                reservations = [row['ready'] for row in rows]
                self.assertEqual(reservations, sorted(reservations))
                span = reservations[-1] - rows[0]['at']
                charged_bytes = sum(row['bytes'] for row in rows)
                self.assertGreaterEqual(span, charged_bytes * 8 / 128000 - .01)
        finally:
            shaper.stop()
            for listener in listeners:
                listener.close()
            server.join(2)
            for thread in echoes:
                thread.join(2)
        self.assertFalse(shaper.worker.is_alive())
        self.assertFalse(server.is_alive())
        self.assertTrue(all(not thread.is_alive() for thread in echoes))
        self.assertEqual(failures, [])

    def test_stop_closes_idle_connections(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen(1)
            listener.settimeout(3)
            shaper = TcpShaper([listener.getsockname()])
            try:
                with socket.create_connection(('127.0.0.1', shaper.ports[0]), 3) as client:
                    upstream, _ = listener.accept()
                    with upstream:
                        shaper.stop()
                        client.settimeout(2)
                        upstream.settimeout(2)
                        self.assertEqual(client.recv(1), b'')
                        self.assertEqual(upstream.recv(1), b'')
            finally:
                shaper.stop()
            self.assertFalse(shaper.worker.is_alive())


if __name__ == '__main__':
    unittest.main()
