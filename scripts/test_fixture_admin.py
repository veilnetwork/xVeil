import errno
import json
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from unittest.mock import patch

import fixture_admin


class HalfCloseRaceSocket:
    def __init__(self, family, closed, error):
        self.socket = socket.socket(family)
        self.closed = closed
        self.error = error

    def __getattr__(self, name):
        return getattr(self.socket, name)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.socket.close()

    def shutdown(self, _how):
        if not self.closed.wait(2):
            raise TimeoutError('test server did not close')
        raise OSError(self.error, 'simulated half-close race after real reply')


class FixtureAdminTest(unittest.TestCase):
    def exchange(self, response, half_close_error):
        with tempfile.TemporaryDirectory(dir='/private/tmp/') as directory:
            path = Path(directory) / 'admin.sock'
            closed = threading.Event()
            requests = []
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(path))
                server.listen()
                server.settimeout(2)

                def serve():
                    try:
                        with server.accept()[0] as peer:
                            with peer.makefile('rb') as reader:
                                requests.append(json.loads(reader.readline()))
                            if response is not None:
                                peer.sendall((json.dumps(response) + '\n').encode())
                    finally:
                        closed.set()

                thread = threading.Thread(target=serve)
                thread.start()
                try:
                    with patch.object(fixture_admin, '_open_socket',
                                      lambda family: HalfCloseRaceSocket(family, closed, half_close_error)):
                        result = fixture_admin.request_admin(path, 'metrics')
                    self.assertEqual(requests, [{'version': 1, 'command': {'command': 'metrics'}}])
                    return result
                finally:
                    thread.join(3)
                    self.assertFalse(thread.is_alive())

    def test_complete_reply_survives_peer_close_before_half_close(self):
        reply = {'result': {'packets': 42}}
        self.assertEqual(self.exchange(reply, errno.ENOTCONN), reply)

    def test_empty_reply_is_still_an_error(self):
        with self.assertRaises(json.JSONDecodeError):
            self.exchange(None, errno.ENOTCONN)

    def test_other_socket_errors_are_not_hidden(self):
        with self.assertRaises(OSError) as error:
            self.exchange({'result': {}}, errno.EPERM)
        self.assertEqual(error.exception.errno, errno.EPERM)


if __name__ == '__main__':
    unittest.main()
