import ctypes as C
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from group_process_files import ProcessFileLoad


class FakeFixture:
    def __init__(self):
        self.callbacks = []

    def bind_app(self, participant, module, flags):
        return 1, 2, C.create_string_buffer(bytes([20 + participant]) * 32)

    def checked(self, function, *args):
        return function(*args)

    def fn(self, name, args, result):
        if name == 'veil_app_set_recv_handler':
            def register(app, callback, context):
                self.receive = callback
                return 0
            return register
        return lambda *args: 0


class ProcessFileTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir='/private/tmp/')
        self.addCleanup(self.directory.cleanup)
        self.fixture = FakeFixture()
        self.load = ProcessFileLoad(self.fixture, 0, Path(self.directory.name))
        self.payload = bytes(range(256)) * 2048
        self.tx_key, self.rx_key = b't' * 32, b'r' * 32
        self.participants = [dict(identity=bytes([i + 1]) * 32,
                                  file_app=bytes([i + 20]) * 32) for i in range(3)]
        self.load.configure(self.participants, self.payload, self.tx_key, self.rx_key,
                            hashlib.sha256(self.payload).hexdigest())
        self.load.arm(0, 10)

    def deliver(self, index, arrived=5, *, corrupt=False, foreign=False):
        nonce = index.to_bytes(12, 'big')
        block = self.payload[index * 2048:(index + 1) * 2048]
        encrypted = bytearray(nonce + AESGCM(self.rx_key).encrypt(nonce, block, b'group-codec-file-v1'))
        if corrupt:
            encrypted[-1] ^= 1
        sender = self.participants[1 if foreign else 2]
        memory = C.create_string_buffer(sender['identity'] + sender['file_app'] + bytes(encrypted))
        address = C.addressof(memory)
        with patch('group_process_files.time.monotonic', return_value=arrived):
            self.fixture.receive(None, address, address + 32, 0, 0, address + 64, len(encrypted))

    def test_exact_complete_payload_hash_and_completion_time(self):
        for i in reversed(range(self.load.blocks)):
            self.deliver(i)
        frozen = self.load.freeze()
        self.assertTrue(frozen['hash_matches'])
        self.assertEqual(frozen['received'], 524288)
        self.assertEqual(frozen['missing_chunks'], 0)
        self.assertEqual(frozen['completion_seconds'], 5)
        self.assertEqual(frozen['authentication_errors'], 0)

    def test_late_final_fragment_cannot_turn_deadline_failure_into_success(self):
        for i in range(self.load.blocks - 1):
            self.deliver(i)
        frozen = self.load.freeze()
        self.deliver(self.load.blocks - 1, arrived=10.001)
        later = self.load.freeze()
        self.assertFalse(frozen['hash_matches'])
        self.assertFalse(later['hash_matches'])
        self.assertEqual(later['missing_chunks'], 1)
        self.assertEqual(later['late_fragments'], 1)
        self.assertIsNone(later['completion_seconds'])

    def test_foreign_sender_and_bad_tag_do_not_count_as_received_bytes(self):
        self.deliver(0, foreign=True)
        self.deliver(1, corrupt=True)
        frozen = self.load.freeze()
        self.assertEqual(frozen['received'], 0)
        self.assertEqual(frozen['authentication_errors'], 2)

    def test_duplicate_is_reported_without_inflating_byte_count(self):
        self.deliver(0)
        self.deliver(0)
        frozen = self.load.freeze()
        self.assertEqual(frozen['received'], 2048)
        self.assertEqual(frozen['duplicates'], 1)


if __name__ == '__main__':
    unittest.main()
