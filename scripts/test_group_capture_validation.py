import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from group_codec_sdk import GroupSdk

spec = importlib.util.spec_from_file_location(
    'group_preflight', Path(__file__).with_name('group-process-preflight.py'))
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class CaptureValidationTest(unittest.TestCase):
    def complete(self):
        return dict(ok=True, duration_seconds=360, load_kind='both',
                    video_file_load=True, end_topology={'verified': True},
                    files=[{}, {}, {}],
                    video_paths=[{'tail_changes': 14,
                                  'frame_witness': 'full-rgba-native-sequence-v1'}
                                 for _ in range(6)])

    def test_old_prefix_hash_capture_cannot_qualify_full_frame_motion(self):
        result = self.complete()
        del result['video_paths'][3]['frame_witness']
        self.assertFalse(preflight.qualifies_full_contention(result))

    def test_full_contention_cannot_qualify_motion_only_video(self):
        for changes in (13, 1, 0):
            result = self.complete()
            result['video_paths'][3]['tail_changes'] = changes
            self.assertFalse(preflight.qualifies_full_contention(result))
        result = self.complete()
        del result['video_paths'][3]['tail_changes']
        self.assertFalse(preflight.qualifies_full_contention(result))

    def test_post_measurement_exception_cannot_keep_a_green_result(self):
        result = self.complete()
        self.assertTrue(preflight.qualifies_full_contention(result))
        # Actual failure: the PCM test had set ok=True, then admin topology
        # verification threw before files/video proofs were assembled.
        result['failure_saved_privately'] = True
        del result['end_topology']; del result['files']; del result['video_paths']
        self.assertFalse(preflight.qualifies_full_contention(result))
        self.assertFalse(preflight.qualifies_full_contention(dict(
            self.complete(), failure_saved_privately=True)))

    def test_missing_proofs_short_diagnostic_and_failed_gate_never_qualify(self):
        for key in ('files', 'video_paths', 'end_topology', 'video_file_load'):
            result = self.complete(); del result[key]
            self.assertFalse(preflight.qualifies_full_contention(result))
        for key, value in [('ok', False), ('duration_seconds', 90),
                           ('load_kind', 'files'), ('end_topology', {'verified': False}),
                           ('files', [{}]), ('video_paths', [{}])]:
            result = self.complete(); result[key] = value
            self.assertFalse(preflight.qualifies_full_contention(result))

    def test_newline_framed_admin_reply_needs_no_half_close(self):
        class Socket:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def settimeout(self, seconds): self.timeout = seconds
            def connect(self, path): self.path = path
            def sendall(self, data): self.sent = data
            def shutdown(self, *_): raise OSError(57, 'Socket is not connected')
            def makefile(self, mode): return io.BytesIO(b'{"version":1,"result":{"sessions":[]}}\n')
        client = Socket()
        sdk = GroupSdk.__new__(GroupSdk); sdk.root = Path('/owned/fixture')
        with patch('group_codec_sdk.socket.socket', return_value=client):
            response = sdk.admin(2, 'sessions')
        self.assertEqual(response['result'], {'sessions': []})
        self.assertEqual(json.loads(client.sent),
                         {'version': 1, 'command': {'command': 'sessions'}})
        self.assertTrue(client.sent.endswith(b'\n'))
        self.assertEqual(client.path, '/owned/fixture/2/admin.sock')


if __name__ == '__main__':
    unittest.main()
