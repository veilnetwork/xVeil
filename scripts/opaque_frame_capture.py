"""Bounded, payload-free observation of an owned loopback SDK fixture.

Uses the existing admin capture stream. Plaintext events and unknown identities
are rejected before hashing. Only a preview digest, lengths and local indices
leave the reader; preview hashes cannot prove full-body equality.
"""
import hashlib
import json
import socket
import threading
import time
from collections import Counter


def sanitize(event, observer, known):
    if event.get('e2e_plaintext') is not False:
        return None, 'nonopaque'
    if type(event.get('src_id')) is not str or type(event.get('dst_id')) is not str:
        return None, 'invalid_frame'
    source = known.get(event.get('src_id', '').lower().removeprefix('0x'))
    target = known.get(event.get('dst_id', '').lower().removeprefix('0x'))
    if source is None or target is None:
        return None, 'unknown_node'
    direction = event.get('direction')
    if ((direction == 'tx' and source != observer)
            or (direction == 'rx' and target != observer)
            or direction not in ('tx', 'rx') or source == target):
        return None, 'invalid_direction'
    try:
        body = bytes.fromhex(event['body_hex'])
        fields = {key: event[key] for key in ('ts_us', 'family', 'msg_type', 'body_len')}
        if (len(body) > 256 or not body
                or any(type(v) is not int for v in fields.values())
                or fields['ts_us'] < 0 or not 0 <= fields['family'] <= 255
                or not 0 <= fields['msg_type'] <= 65535
                or not len(body) <= fields['body_len'] <= 16 * 1024 * 1024):
            return None, 'invalid_frame'
    except (KeyError, ValueError, TypeError):
        return None, 'invalid_frame'
    return dict(source=source, target=target, direction=direction,
                at_us=fields['ts_us'], family=fields['family'],
                msg_type=fields['msg_type'], body_len=fields['body_len'],
                preview_len=len(body), preview_sha256=hashlib.sha256(body).hexdigest()), None


class OpaqueFrameCapture:
    def __init__(self, root, identities, limit=4096):
        self.root = root
        self.known = {value.lower().removeprefix('0x'): i for i, value in enumerate(identities)}
        if len(self.known) != len(identities) or not 1 <= limit <= 4096:
            raise ValueError('Capture requires distinct fixture identities and a bounded limit')
        self.limit = limit
        self.rows = []
        self.rejected = Counter()
        self.acks = []
        self.errors = []
        self.eof = []
        self.sockets = []
        self.threads = []
        self.lock = threading.Lock()
        self.stopped = threading.Event()
        before = time.monotonic_ns() // 1000
        wall = time.time_ns() // 1000
        after = time.monotonic_ns() // 1000
        self.clock = dict(monotonic_us=(before + after) // 2,
                          wall_us=wall, uncertainty_us=after - before)

    def start(self):
        for index in range(len(self.known)):
            connection = socket.socket(socket.AF_UNIX)
            self.sockets.append(connection)
            connection.settimeout(1)
            connection.connect(str(self.root / str(index) / 'admin.sock'))
            connection.sendall((json.dumps({'version': 1, 'command': {
                'command': 'debug_capture', 'filter_node_id': None,
                'filter_family': None, 'limit': self.limit}}) + '\n').encode())
            connection.settimeout(.2)
            thread = threading.Thread(target=self._read, args=(index, connection),
                                      name='stand-opaque-capture-' + str(index))
            self.threads.append(thread)
            thread.start()

    def _read(self, index, connection):
        pending = b''
        try:
            while not self.stopped.is_set():
                try:
                    data = connection.recv(4096)
                except socket.timeout:
                    continue
                if not data:
                    with self.lock:
                        self.eof.append(index)
                    break
                pending += data
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    if len(line) > 8192:
                        raise ValueError('Oversized capture response')
                    response = json.loads(line)
                    if response.get('error'):
                        raise ValueError('Capture command failed')
                    event = response.get('result') or {}
                    if event.get('type') == 'ack':
                        with self.lock:
                            self.acks.append(index)
                    elif event.get('type') == 'capture_frame':
                        row, rejection = sanitize(event, index, self.known)
                        with self.lock:
                            if rejection:
                                self.rejected[rejection] += 1
                            elif len(self.rows) < self.limit * len(self.known):
                                self.rows.append(row)
                            else:
                                self.rejected['local_limit'] += 1
                if len(pending) > 8192:
                    raise ValueError('Oversized unterminated capture response')
            if pending and not self.stopped.is_set():
                raise ValueError('Incomplete capture response')
        except Exception as error:
            if not self.stopped.is_set():
                with self.lock:
                    # Do not retain server text, identities or raw input.
                    self.errors.append(dict(observer=index, error_type=type(error).__name__))

    def stop(self):
        self.stopped.set()
        for connection in self.sockets:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()
        for thread in self.threads:
            thread.join(2)

    def snapshot(self):
        with self.lock:
            return dict(format='xveil-opaque-frame-capture-v1', clock=self.clock,
                        limit_per_node=self.limit, expected_nodes=len(self.known),
                        ack_nodes=sorted(set(self.acks)), eof_nodes=sorted(set(self.eof)),
                        reader_errors=list(self.errors), rejected=dict(self.rejected),
                        readers_exited=all(not t.is_alive() for t in self.threads),
                        rows=list(self.rows))
