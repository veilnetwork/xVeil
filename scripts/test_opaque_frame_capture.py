import json
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path

from opaque_frame_capture import OpaqueFrameCapture, sanitize, MAX_CAPTURE_ROWS_PER_NODE
from analyze_opaque_frame_capture import analyze
from tcp_fifo_shaper import kernel_unread_bytes


IDS = ['01'*32, '02'*32]


def frame(direction, at, body=b'opaque cipher preview'):
    return dict(type='capture_frame', e2e_plaintext=False, src_id=IDS[0], dst_id=IDS[1],
                direction=direction, ts_us=at, family=4, msg_type=1,
                body_len=300, body_hex=body.hex())


def captured(direction, at, body=b'opaque cipher preview'):
    observer = 0 if direction == 'tx' else 1
    row, reason = sanitize(frame(direction, at, body), observer, {x:i for i,x in enumerate(IDS)})
    assert reason is None
    return row


def evidence(rows):
    return dict(format='xveil-opaque-frame-capture-v1',
                clock=dict(monotonic_us=0, wall_us=0, uncertainty_us=1), rows=rows,
                ack_nodes=[0,1], reader_errors=[], readers_exited=True)


SUMMARY = dict(loopback_only=True, stand_start_monotonic_us=0, duration_seconds=90)


class OpaqueCaptureTest(unittest.TestCase):
    def test_full_run_capture_keeps_an_explicit_finite_limit(self):
        capture = OpaqueFrameCapture(Path('/private/tmp'), IDS, limit=MAX_CAPTURE_ROWS_PER_NODE)
        self.assertEqual(capture.limit, MAX_CAPTURE_ROWS_PER_NODE)
        for limit in [0, MAX_CAPTURE_ROWS_PER_NODE + 1, True, 1.5]:
            with self.assertRaises(ValueError):
                OpaqueFrameCapture(Path('/private/tmp'), IDS, limit=limit)

    def test_kernel_backlog_snapshot_does_not_consume_or_change_bytes(self):
        left, right = socket.socketpair()
        try:
            left.sendall(b'opaque kernel backlog')
            self.assertEqual(kernel_unread_bytes(right), len(b'opaque kernel backlog'))
            self.assertEqual(right.recv(128), b'opaque kernel backlog')
            self.assertEqual(kernel_unread_bytes(right), 0)
        finally:
            left.close()
            right.close()

    def test_plaintext_unknown_and_truncated_preview_privacy(self):
        known = {x:i for i,x in enumerate(IDS)}
        event = frame('tx', 1)
        event['e2e_plaintext'] = True
        self.assertEqual(sanitize(event, 0, known), (None, 'nonopaque'))
        del event['e2e_plaintext']
        self.assertEqual(sanitize(event, 0, known), (None, 'nonopaque'))
        event = frame('tx', 1)
        event['dst_id'] = '03'*32
        self.assertEqual(sanitize(event, 0, known), (None, 'unknown_node'))
        row = captured('tx', 1)
        text = json.dumps(row)
        self.assertNotIn(IDS[0], text)
        self.assertNotIn(frame('tx', 1)['body_hex'], text)
        self.assertEqual(row['body_len'], 300)
        self.assertLess(row['preview_len'], row['body_len'])

    def test_one_hop_timing_and_repeated_previews_are_not_guessed(self):
        rows = [captured('tx', 20_000_000), captured('rx', 20_040_000)]
        result = analyze(SUMMARY, evidence(rows))
        self.assertEqual(result['hops'][0]['phases'][1]['capture_to_dispatch']['max_ms'], 40)
        self.assertNotIn('preview_sha256', json.dumps(result))
        result = analyze(SUMMARY, evidence(rows + [captured('tx', 20_001_000)]))
        self.assertEqual(result['ambiguous_preview_groups'], 1)
        self.assertEqual(result['hops'], [])

    def test_missing_capture_is_not_loss_and_inverted_clock_is_rejected(self):
        result = analyze(SUMMARY, evidence([captured('tx', 20_000_000)]))
        self.assertEqual(result['incomplete_preview_groups'], 1)
        self.assertTrue(result['missing_captures_are_not_message_loss'])
        with self.assertRaises(ValueError):
            analyze(SUMMARY, evidence([captured('tx', 2), captured('rx', 1)]))
        with self.assertRaises(ValueError):
            analyze(dict(SUMMARY, loopback_only=False), evidence([]))

    def test_fragmented_admin_stream_is_sanitized_and_disconnect_stops_reader(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as directory:
            root = Path(directory)
            (root/'0').mkdir()
            server = socket.socket(socket.AF_UNIX)
            server.bind(str(root/'0'/'admin.sock'))
            server.listen()
            # A one-observer fixture can only see known nodes. This test sends
            # a self-observation and plaintext: neither can escape sanitation.
            def serve():
                connection, _ = server.accept()
                with connection:
                    request = connection.recv(4096)
                    self.assertIn(b'debug_capture', request)
                    ack = json.dumps(dict(result=dict(type='ack'), error=None)).encode()+b'\n'
                    connection.sendall(ack[:7]); connection.sendall(ack[7:])
                    event = frame('tx', 1)
                    event['dst_id'] = IDS[0]
                    connection.sendall((json.dumps(dict(result=event, error=None))+'\n').encode())
                    event['e2e_plaintext'] = True
                    connection.sendall((json.dumps(dict(result=event, error=None))+'\n').encode())
                    # Keep the socket open without frames: stop must wake recv.
                    connection.recv(1)
            worker = threading.Thread(target=serve)
            worker.start()
            capture = OpaqueFrameCapture(root, IDS[:1])
            try:
                capture.start()
                deadline = time.monotonic()+1
                while time.monotonic()<deadline and sum(capture.snapshot()['rejected'].values())<2:
                    time.sleep(.005)
            finally:
                capture.stop()
                worker.join(1)
                server.close()
            snapshot = capture.snapshot()
            self.assertFalse(worker.is_alive())
            self.assertTrue(snapshot['readers_exited'])
            self.assertEqual(snapshot['ack_nodes'], [0])
            self.assertEqual(snapshot['rows'], [])
            self.assertEqual(snapshot['rejected']['nonopaque'], 1)
            self.assertEqual(snapshot['rejected']['invalid_direction'], 1)
            self.assertEqual(snapshot['reader_errors'], [])
            self.assertEqual(snapshot['events_per_node'], [2])
            self.assertEqual(snapshot['capture_limit_reached_nodes'], [])


if __name__ == '__main__':
    unittest.main()
