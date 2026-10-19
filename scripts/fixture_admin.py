"""One request to the fixture's newline-delimited Unix admin API."""
import errno
import json
import socket

_open_socket = socket.socket


def request_admin(path, command):
    with _open_socket(socket.AF_UNIX) as connection:
        connection.settimeout(4)
        connection.connect(str(path))
        request = {'version': 1, 'command': {'command': command}}
        connection.sendall((json.dumps(request) + '\n').encode())
        try:
            connection.shutdown(socket.SHUT_WR)
        except OSError as error:
            # The server may have already sent its complete reply and closed.
            # Darwin then rejects half-close despite a readable response.
            if error.errno != errno.ENOTCONN:
                raise
        with connection.makefile('rb') as reader:
            # Missing/invalid replies still fail; no retry can repeat a command.
            return json.loads(reader.readline())
