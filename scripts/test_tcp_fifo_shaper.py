"""Real socket checks for aggregate shaping, byte integrity, EOF and shutdown."""
import asyncio
import collections
import concurrent.futures
import json
import os
import socket
import subprocess
import sys
import threading
import time
import unittest

from tcp_fifo_shaper import ReaderArrivalTrace, TcpShaper
from process_tcp_shaper import ProcessTcpShaper


class TcpShaperTest(unittest.TestCase):
    shaper_type = TcpShaper

    def assert_worker_exited(self, shaper):
        self.assertFalse(shaper.worker.is_alive())

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
            self.shaper_type([target, target], scope='per-target')

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
        shaper = self.shaper_type(targets, trace=True, scope=scope)
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
        self.assert_worker_exited(shaper)
        self.assertFalse(server.is_alive())
        self.assertTrue(all(not thread.is_alive() for thread in echoes))
        self.assertEqual(failures, [])

    def test_stop_closes_idle_connections(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen(1)
            listener.settimeout(3)
            shaper = self.shaper_type([listener.getsockname()])
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
            self.assert_worker_exited(shaper)


class ProcessTcpShaperTest(TcpShaperTest):
    shaper_type = ProcessTcpShaper

    def assert_worker_exited(self, shaper):
        self.assertEqual(shaper.process.poll(), 0)
        self.assertFalse(shaper.reader.is_alive())

    def test_dead_worker_fails_stop_and_closes_control_handles(self):
        shaper = self.shaper_type([('127.0.0.1', 1)])
        self.assertNotEqual(shaper.pid, os.getpid())
        self.assertEqual(shaper.pid, shaper.process.pid)
        shaper.process.kill()
        shaper.process.wait(timeout=5)
        with self.assertRaises((BrokenPipeError, RuntimeError)):
            shaper.stop()
        self.assertIsNotNone(shaper.process.poll())
        self.assertFalse(shaper.reader.is_alive())
        self.assertTrue(shaper.process.stdin.closed)
        self.assertTrue(shaper.process.stdout.closed)


class ShaperRuntimeIsolationTest(unittest.TestCase):
    def test_parent_gil_stall_cannot_delay_isolated_network(self):
        # Echo endpoint AND timed sender live outside this runtime. Otherwise
        # blocking the test's GIL would pause the witness, hiding the defect.
        witness_source = '''
import socket, threading, time, json
listener=socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(1)
print(listener.getsockname()[1],flush=True)
def echo():
    conn,_=listener.accept()
    with conn:
        while data:=conn.recv(4096): conn.sendall(data)
thread=threading.Thread(target=echo);thread.start()
port=int(input())
with socket.create_connection(('127.0.0.1',port),3) as conn:
    conn.settimeout(3);conn.sendall(b'warm');assert conn.recv(4)==b'warm'
    print('ready',flush=True);assert input()=='go';time.sleep(.1)
    began=time.monotonic();conn.sendall(b'check');data=conn.recv(5)
    print(json.dumps(dict(seconds=time.monotonic()-began,exact=data==b'check')),flush=True)
thread.join(3);listener.close()
'''
        observed = {}
        for label, factory in [('thread', TcpShaper), ('process', ProcessTcpShaper)]:
            witness = subprocess.Popen([sys.executable, '-u', '-c', witness_source],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       text=True, bufsize=1)
            shaper = None
            try:
                target = ('127.0.0.1', int(witness.stdout.readline()))
                shaper = factory([target])
                witness.stdin.write(str(shaper.ports[0]) + '\n')
                witness.stdin.flush()
                self.assertEqual(witness.stdout.readline().strip(), 'ready')
                old_interval = sys.getswitchinterval()
                try:
                    sys.setswitchinterval(2)
                    witness.stdin.write('go\n'); witness.stdin.flush()
                    until = time.monotonic() + .9
                    while time.monotonic() < until:
                        pass
                finally:
                    sys.setswitchinterval(old_interval)
                result = json.loads(witness.stdout.readline())
                self.assertTrue(result['exact'])
                observed[label] = result['seconds']
                self.assertEqual(witness.wait(timeout=5), 0)
            finally:
                if shaper is not None:
                    shaper.stop()
                if witness.poll() is None:
                    witness.kill(); witness.wait(timeout=5)
                witness.stdin.close(); witness.stdout.close()
        print('parent-GIL witness seconds:', observed, flush=True)
        self.assertGreater(observed['thread'], .65)
        self.assertLess(observed['process'], .4)


if __name__ == '__main__':
    unittest.main()
