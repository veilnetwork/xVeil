"""Owned four-node SDK star for real three-party group codec fixtures.

Only loopback listeners and an optional blind FIFO shaper are created. Source
selectors are local IPC metadata; the relay receives ordinary opaque frames.
The caller must stop codec/file producers before closing this fixture.
"""
import ctypes as C
import errno
import json
import os
from pathlib import Path
import secrets
import socket
import time
import tomllib

from fixture_paths import validate_unix_fixture_paths
from udp_fifo_shaper import UdpShaper

P = C.c_void_p
E = C.POINTER(P)


class GroupSdk:
    def __init__(self, sdk, directory, rate_kbps=0, *, attach=False, trace=False,
                 trace_capacity=100000):
        self.root = Path(directory).absolute()
        validate_unix_fixture_paths(self.root)
        if attach:
            if not self.root.is_dir():
                raise ValueError('Owned transport fixture is missing')
        else:
            self.root.mkdir(mode=0o700, exist_ok=False)
        self.lib = C.CDLL(str(Path(sdk).resolve(strict=True)), mode=C.RTLD_GLOBAL)
        self.nodes, self.handles, self.apps, self.channels = [], [], [], []
        self.port_reservations = []
        self.ids, self.media_apps, self.media_ids = [], [], []
        self.callbacks = []
        self.shaper = None
        self.rate_kbps = rate_kbps
        self.trace = trace
        self.trace_capacity = trace_capacity
        self.closed = False
        self.stop_results = []
        self.channel_pairs = {}
        self.init = self.fn('veil_config_init', [C.c_uint32, E], P)
        self.free = self.fn('veil_free_string', [P], None)
        self.node_start = self.fn('veil_node_start', [C.c_char_p, C.c_size_t, E], P)
        self.node_stop = self.fn('veil_node_stop_timeout', [P, C.c_uint64], C.c_int)
        self.connect = self.fn('veil_connect', [C.c_char_p, C.c_size_t, E], P)
        self.handle_close = self.fn('veil_close', [P], None)
        self.bind = self.fn('veil_bind_named', [P, P, C.c_size_t, P, C.c_size_t,
                                               C.c_uint32, E], P)
        self.app_close = self.fn('veil_app_close', [P], None)
        self.node_id = self.fn('veil_get_node_id', [P, P, E], C.c_int)
        self.app_id = self.fn('veil_app_get_app_id', [P, P], C.c_int)
        self.channel_open = self.fn('veil_media_open_relay_channel',
                                    [P, P, P, C.c_uint32, P, P, E], C.c_uint64)
        self.channel_close = self.fn('veil_media_close_channel', [C.c_uint64], None)

    def fn(self, name, args, result):
        value = getattr(self.lib, name)
        value.argtypes, value.restype = args, result
        return value

    def checked(self, function, *args):
        error = P()
        result = function(*args, C.byref(error))
        if error.value:
            message = C.string_at(error).decode(errors='replace')
            self.free(error)
            raise RuntimeError(function.__name__ + ': ' + message)
        return result

    def admin(self, index, command):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(4)
            client.connect(str(self.root / str(index) / 'admin.sock'))
            client.sendall((json.dumps({'version': 1, 'command':
                                        {'command': command}}) + '\n').encode())
            client.shutdown(socket.SHUT_WR)
            with client.makefile('rb') as stream:
                return json.loads(stream.readline())

    def bind_app(self, participant, module, flags):
        uri = str(self.root / str(participant + 1) / 'ipc.sock').encode()
        handle = self.checked(self.connect, uri, len(uri))
        if not handle:
            raise RuntimeError('Empty SDK client handle')
        self.handles.append(handle)
        service = b'xveil-group-codec'
        module = module.encode()
        app = self.checked(self.bind, handle, service, len(service),
                           module, len(module), flags)
        if not app:
            raise RuntimeError('Empty SDK application handle')
        self.apps.append(app)
        app_id = C.create_string_buffer(32)
        if self.app_id(app, app_id) != 0:
            raise RuntimeError('SDK application identity unavailable')
        return handle, app, app_id

    def start(self, *, transport_only=False):
        identities, ports = [], []
        for index in range(4):
            (self.root / str(index)).mkdir(mode=0o700)
            raw = self.checked(self.init, 0)
            try:
                identities.append(tomllib.loads(C.string_at(raw).decode())['Identity'])
            finally:
                self.free(raw)
            # Keep later listeners reserved while the other nodes and shaper
            # bind their sockets. An ephemeral port released during PoW setup
            # can be taken by an outbound socket before its listener starts.
            # Stay below the default macOS/Linux ephemeral ranges as well.
            listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                for _ in range(128):
                    try:
                        listener.bind(('127.0.0.1', 10000 + secrets.randbelow(20000)))
                        break
                    except OSError as error:
                        if error.errno != errno.EADDRINUSE:
                            raise
                else:
                    raise RuntimeError('Could not reserve a local UDP listener port')
                ports.append(listener.getsockname()[1])
                self.port_reservations.append(listener)
            except BaseException:
                listener.close()
                raise
        if self.rate_kbps:
            self.shaper = UdpShaper([('127.0.0.1', p) for p in ports],
                                    trace=self.trace, trace_capacity=self.trace_capacity)
            # The caller starts the measured rate only after bootstrap. Each
            # direction has one blind FIFO shared by all target connections.
        self.relay_id = str(identities[0]['node_id']).removeprefix('0x')
        self.node_ids = [str(identity['node_id']).removeprefix('0x') for identity in identities]
        for index, identity in enumerate(identities):
            directory = self.root / str(index)
            lines = ['persist_enabled = false', '[global]',
                     'meeting_points = "off"', 'builtin_seed_policy = "never"',
                     'admin_socket = ' + json.dumps('unix://' + str(directory / 'admin.sock')),
                     '[Identity]']
            lines += [key + ' = ' + json.dumps(identity[key]) for key in
                      ['algo', 'public_key', 'private_key', 'nonce', 'node_id']]
            lines += ['[pex]', 'enabled = false',
                      '[metrics]', 'listen = "tcp://127.0.0.1:0"',
                      '[anonymity]', 'relay_capable = true', '[ipc]', 'enabled = true',
                      'socket_uri = ' + json.dumps('unix://' + str(directory / 'ipc.sock')),
                      '[[listen]]', 'id = "0x00000001"',
                      'transport = ' + json.dumps('quic://127.0.0.1:' + str(ports[index]))]
            # The star is a test network topology, not merely its initial
            # seed list. Otherwise PEX/DHT can create participant-to-participant
            # sessions mid-capture and silently invalidate relay comparisons.
            allowed = [1, 2, 3] if index == 0 else [0]
            lines += ['visibility = "hidden"',
                      'allowlist_node_ids = ' + json.dumps([self.node_ids[p] for p in allowed])]
            if self.shaper:
                lines += ['advertise = ' + json.dumps('quic://127.0.0.1:' +
                                                    str(self.shaper.ports[index]))]
            for peer in ([1, 2, 3] if index == 0 else [0]):
                endpoint = self.shaper.ports[peer] if self.shaper else ports[peer]
                lines += ['[[peers]]', 'peer_id = ' + json.dumps(f'0x{peer + 1:08x}')]
                lines += [key + ' = ' + json.dumps(identities[peer][key]) for key in
                          ['public_key', 'nonce', 'algo']]
                lines += ['transport = ' + json.dumps('quic://127.0.0.1:' + str(endpoint))]
            path = directory / 'node.toml'
            path.write_text('\n'.join(lines) + '\n')
            encoded = str(path).encode()
            self.port_reservations[index].close()
            node = self.checked(self.node_start, encoded, len(encoded))
            if not node:
                raise RuntimeError('Empty SDK node handle')
            self.nodes.append(node)
        self.fn('veil_debug_set_rt_trace', [C.c_int], None)(1)
        for index in range(4):
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                try:
                    state = self.admin(index, 'sessions')
                    sessions = state.get('result', {}).get('sessions', [])
                    if (len(sessions) == (3 if index == 0 else 1) and
                            all(row.get('state') == 'active' for row in sessions)):
                        (self.root / f'sessions-{index}.json').write_text(json.dumps(state))
                        break
                except (OSError, ValueError):
                    pass
                time.sleep(.2)
            else:
                raise RuntimeError(f'Node {index} did not connect to the owned star')

        if transport_only:
            return self
        secondary, feedback = [], []
        receive = self.fn('veil_media_start_direct_receiver',
                          [P, P, C.c_size_t, P, C.c_size_t, E], C.c_int)
        for participant in range(3):
            handle, app, app_id = self.bind_app(participant, 'media', 0)
            identity = C.create_string_buffer(32)
            if self.checked(self.node_id, handle, identity) != 0:
                raise RuntimeError('SDK node identity unavailable')
            self.ids.append(identity)
            self.media_apps.append(app)
            self.media_ids.append(app_id)
            service, module = b'xveil-group-codec', b'media'
            if self.checked(receive, app, service, len(service), module, len(module)) != 0:
                raise RuntimeError('Media receiver refused')
            secondary.append(self.bind_app(participant, 'media', 1)[1])
            feedback.append(self.bind_app(participant, 'media', 5)[1])

        tx = {(a, z): C.create_string_buffer(os.urandom(32))
              for a in range(3) for z in range(3) if a != z}
        self.keys = tx
        set_secondary = self.fn('veil_media_channel_set_secondary_sender',
                                [C.c_uint64, P, E], C.c_int)
        set_feedback = self.fn('veil_media_channel_set_feedback_sender',
                               [C.c_uint64, P, E], C.c_int)
        batching = self.fn('veil_media_channel_set_batching',
                          [C.c_uint64, C.c_int], C.c_int)
        for a in range(3):
            for z in range(3):
                if a == z:
                    continue
                channel = self.checked(self.channel_open, self.media_apps[a],
                                       self.ids[z], self.media_ids[z], 0,
                                       tx[a, z], tx[z, a])
                if not channel:
                    raise RuntimeError('Empty media channel')
                self.channels.append(channel)
                self.channel_pairs[a, z] = channel
                if (self.checked(set_secondary, channel, secondary[a]) != 0 or
                        self.checked(set_feedback, channel, feedback[a]) != 0 or
                        batching(channel, 2) != 0):
                    raise RuntimeError('Independent source setup refused')
        return self

    def verify_topology(self):
        counts = []
        valid = True
        for index in range(4):
            state = self.admin(index, 'sessions')
            (self.root / f'sessions-end-{index}.json').write_text(json.dumps(state))
            sessions = state.get('result', {}).get('sessions', [])
            counts.append(len(sessions))
            valid &= (len(sessions) == (3 if index == 0 else 1) and
                      all(row.get('state') == 'active' for row in sessions))
        return {'verified': valid, 'active_session_counts': counts}

    def close(self):
        if self.closed:
            return
        self.closed = True
        for reservation in self.port_reservations:
            reservation.close()
        for channel in reversed(self.channels):
            self.channel_close(channel)
        for app in reversed(self.apps):
            self.app_close(app)
        for handle in reversed(self.handles):
            self.handle_close(handle)
        try:
            if self.shaper:
                self.shaper.stop()
        finally:
            self.stop_results = [self.node_stop(node, 5000) for node in reversed(self.nodes)]
