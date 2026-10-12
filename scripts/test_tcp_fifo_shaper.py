"""Real socket checks for aggregate shaping, byte integrity, EOF and shutdown."""
import collections
import concurrent.futures
import os
import socket
import threading
import time
import unittest

from tcp_fifo_shaper import TcpShaper


class TcpShaperTest(unittest.TestCase):
    def test_competing_connections_share_rate_and_preserve_bytes(self):
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(2)
        listener.settimeout(8)
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
                for _ in range(2):
                    conn, _ = listener.accept()
                    thread = threading.Thread(target=echo, args=(conn,))
                    echoes.append(thread)
                    thread.start()
            except Exception as error:
                failures.append(type(error).__name__)

        server = threading.Thread(target=serve)
        server.start()
        shaper = TcpShaper([listener.getsockname()], trace=True)
        shaper.rate_bps = 128000
        barrier = threading.Barrier(2)
        payloads = [os.urandom(16384), os.urandom(16384)]

        def transfer(payload):
            with socket.create_connection(('127.0.0.1', shaper.ports[0]), 8) as conn:
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
                results = list(pool.map(transfer, payloads))
            self.assertEqual([data for data, _ in results], payloads)
            # 32 KiB across two connections share 128 kbit/s, rather than each
            # receiving that capacity. Allow clock precision and final chunk.
            self.assertGreater(max(elapsed for _, elapsed in results), 1.9)
            self.assertIsNone(shaper.failure)
            for stat in shaper.stats:
                self.assertEqual(stat['sent_bytes'], 32768)
                self.assertEqual(stat['received_bytes'], 32768)
                self.assertEqual(stat['drops'], 0)
            by_direction = collections.defaultdict(list)
            for row in shaper.trace_rows:
                self.assertLessEqual(set(row), {
                    'at', 'direction', 'link', 'bytes', 'pending', 'ready',
                    'queue_ms', 'sent_at', 'release_lateness_ms'})
                by_direction[row['direction']].append(row)
            for rows in by_direction.values():
                reservations = [row['ready'] for row in rows]
                self.assertEqual(reservations, sorted(reservations))
                span = reservations[-1] - rows[0]['at']
                self.assertGreaterEqual(span, 32768 * 8 / 128000 - .01)
        finally:
            shaper.stop()
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
