"""One authenticated encrypted file sender/receiver per isolated SDK process.

Synthetic bytes only. The immutable receive deadline is checked in the actual
application callback, so teardown/analysis cannot make late files pass.
"""
import collections
import ctypes as C
import hashlib
import threading
import time
import traceback

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from group_codec_sdk import P, E


class ProcessFileLoad:
    size = 524288
    block_size = 2048
    blocks = size // block_size

    def __init__(self, fixture, participant, directory):
        self.fixture, self.participant, self.directory = fixture, participant, directory
        self.handle, self.app, self.app_id = fixture.bind_app(participant, 'file', 3)
        self.lock, self.stop_event = threading.Lock(), threading.Event()
        self.thread = None
        self.origin = self.deadline = None
        self.received = {}
        self.queued = self.bad = self.duplicates = self.late = 0
        self.failures = collections.Counter()
        self.completion = None
        self.write_error = False

    def configure(self, participants, outgoing, tx_key, rx_key, expected_hash):
        fixture = self.fixture
        sender, target = (self.participant - 1) % 3, (self.participant + 1) % 3
        identities = [C.create_string_buffer(p['identity']) for p in participants]
        apps = [C.create_string_buffer(p['file_app']) for p in participants]
        handler_type = C.CFUNCTYPE(None, P, P, P, C.c_uint8, C.c_uint64, P, C.c_size_t)
        event_type = C.CFUNCTYPE(None, P, C.c_uint8, P, C.c_size_t)
        handler = fixture.fn('veil_app_set_recv_handler', [P, handler_type, P, E], C.c_int)
        events = fixture.fn('veil_set_event_handler', [P, event_type, P, E], C.c_int)
        free_buf = fixture.fn('veil_free_buf', [P, C.c_size_t], None)
        send = fixture.fn('veil_send_on_local_lane',
                          [P, P, P, C.c_uint32, P, C.c_size_t, C.c_uint8, C.c_uint8, E], C.c_int)
        self.expected_hash = expected_hash
        tx, rx = AESGCM(tx_key), AESGCM(rx_key)
        if len(outgoing) != self.size:
            raise ValueError('The qualification file must contain exactly 512 KiB')

        @event_type
        def event(_, kind, data, size):
            try:
                if kind == 4:
                    raw = C.string_at(data, size) if size else b''
                    code = str(int.from_bytes(raw, 'big')) if size == 2 else 'unknown'
                    with self.lock:
                        self.failures[code] += 1
            finally:
                if size:
                    free_buf(data, size)

        @handler_type
        def receive(_, node, app, provenance, reply, data, size):
            arrived = time.monotonic()
            try:
                if (C.string_at(node, 32) != participants[sender]['identity'] or
                        C.string_at(app, 32) != participants[sender]['file_app']):
                    raise ValueError('Foreign fixture sender')
                raw = C.string_at(data, size)
                index = int.from_bytes(raw[:12], 'big')
                if not 0 <= index < self.blocks:
                    raise ValueError('Invalid file fragment')
                block = rx.decrypt(raw[:12], raw[12:], b'group-codec-file-v1')
                if len(block) != self.block_size:
                    raise ValueError('Invalid file fragment size')
                with self.lock:
                    if self.deadline is None or arrived > self.deadline:
                        self.late += 1
                    else:
                        if index in self.received:
                            self.duplicates += 1
                        self.received[index] = block
                        if len(self.received) == self.blocks and self.completion is None:
                            self.completion = arrived - self.origin
            except Exception:
                with self.lock:
                    self.bad += 1
            finally:
                free_buf(node, 64 + size)

        fixture.callbacks.extend([event, receive])
        if (fixture.checked(events, self.handle, event, None) or
                fixture.checked(handler, self.app, receive, None)):
            raise RuntimeError('File callbacks refused')

        def write():
            try:
                for index in range(self.blocks):
                    if self.stop_event.is_set():
                        break
                    nonce = index.to_bytes(12, 'big')
                    block = outgoing[index * self.block_size:(index + 1) * self.block_size]
                    encoded = nonce + tx.encrypt(nonce, block, b'group-codec-file-v1')
                    if fixture.checked(send, self.app, identities[target], apps[target],
                                       3, encoded, len(encoded), 4, 0):
                        raise RuntimeError('Reliable file enqueue refused')
                    with self.lock:
                        self.queued += len(block)
            except Exception:
                with self.lock:
                    self.write_error = True
                (self.directory / 'file-failure.txt').write_text(traceback.format_exc())

        self.write = write

    def arm(self, origin, deadline):
        self.origin, self.deadline = origin, deadline

    def start(self):
        self.thread = threading.Thread(target=self.write, name='group-file', daemon=True)
        self.thread.start()

    def freeze(self):
        with self.lock:
            data = b''.join(self.received[i] for i in sorted(self.received))
            return {'queued': self.queued, 'received': len(data),
                    'missing_chunks': self.blocks - len(self.received),
                    'hash_matches': len(data) == self.size and
                    hashlib.sha256(data).hexdigest() == self.expected_hash,
                    'completion_seconds': self.completion,
                    'authentication_errors': self.bad, 'duplicates': self.duplicates,
                    'async_failures': dict(self.failures), 'write_error': self.write_error,
                    'late_fragments': self.late}

    def stop(self):
        self.stop_event.set()
        if self.thread:
            self.thread.join(5)
        return self.thread is None or not self.thread.is_alive()
