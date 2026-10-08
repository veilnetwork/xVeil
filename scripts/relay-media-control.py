#!/usr/bin/env python3
"""Exercise sealed media over a neutral relay using actual loopback QUIC.

Requires Python 3.11+ and a Veil SDK built with node-embedded. This is a
transport control, not an acoustic test or a mobile-network quality gate.
Every identity is a distinct stand identity; no application profile is opened.
Raw logs, packet observations and keys remain in an owner-only directory.
Only counters are printed. --compete-video --rate-kbps 1024 adds a constrained
transport comparison. RTP payloads are synthetic; no codec or adaptive
media-engine feedback is present.
"""
import argparse, hashlib, re, tempfile
from udp_fifo_shaper import UdpShaper
import ctypes as C
import json, os, socket, time, tomllib, traceback
from pathlib import Path
os.umask(0o077)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sdk', type=Path, required=True)
parser.add_argument('--compete-video', action='store_true', help='Offer synthetic video RTP after 12 seconds of audio-only baseline; not a codec/playout test')
parser.add_argument('--rate-kbps', type=int, default=0, help='Aggregate blind FIFO cap per UDP direction; 0 leaves transport unrestricted')
parser.add_argument('--directory', type=Path, help='Private stand directory; reuse only a fixture created by this script')
args = parser.parse_args()
if args.rate_kbps < 0:
    parser.error('--rate-kbps must be nonnegative')
sdk_path = args.sdk.resolve(strict=True)
if args.directory is None:
    ROOT = Path(tempfile.mkdtemp(prefix='xveil-relay-control-', dir='/private/tmp'))
else:
    ROOT = args.directory.absolute()
    if ROOT.exists():
        if ROOT.is_symlink() or not (ROOT / 'fixture.json').is_file():
            parser.error('Existing directory is not an owned relay-control fixture')
        if json.loads((ROOT / 'fixture.json').read_text()).get('format') != 'xveil-relay-control-v1':
            parser.error('Unrecognised fixture marker')
    else:
        ROOT.mkdir(mode=0o700)
if ROOT.stat().st_uid != os.getuid() or ROOT.stat().st_mode & 0o077:
    parser.error('Fixture directory must be owner-only')
for index in range(3):
    if (ROOT / str(index)).is_symlink():
        parser.error('Fixture node directories must not be symbolic links')
(ROOT / 'fixture.json').write_text(json.dumps({'format': 'xveil-relay-control-v1', 'sdk_sha256': hashlib.sha256(sdk_path.read_bytes()).hexdigest()}))
os.chdir(ROOT)
log_path = ROOT / 'runtime.log'
log_file = log_path.open('w')
os.dup2(log_file.fileno(), 2)
SDK = C.CDLL(str(sdk_path))
P = C.c_void_p
E = C.POINTER(P)

def fn(name, args, result):
    f = getattr(SDK, name)
    f.argtypes = args
    f.restype = result
    return f
init = fn('veil_config_init', [C.c_uint32, E], P)
free = fn('veil_free_string', [P], None)
start = fn('veil_node_start', [C.c_char_p, C.c_size_t, E], P)
stop = fn('veil_node_stop_timeout', [P, C.c_uint64], C.c_int)
connect = fn('veil_connect', [C.c_char_p, C.c_size_t, E], P)
close = fn('veil_close', [P], None)
bind = fn('veil_bind_named', [P, C.c_char_p, C.c_size_t, C.c_char_p, C.c_size_t, C.c_uint32, E], P)
appclose = fn('veil_app_close', [P], None)
nodeid = fn('veil_get_node_id', [P, P, E], C.c_int)
appid = fn('veil_app_get_app_id', [P, P], C.c_int)
recv = fn('veil_media_start_direct_receiver', [P, C.c_char_p, C.c_size_t, C.c_char_p, C.c_size_t, E], C.c_int)
openmedia = fn('veil_media_open_relay_channel', [P, P, P, C.c_uint32, P, P, E], C.c_uint64)
send = fn('veil_media_send_datagram', [C.c_uint64, P, C.c_size_t], C.c_int)
mediaclose = fn('veil_media_close_channel', [C.c_uint64], None)
CALLBACK = C.CFUNCTYPE(None, P, P, C.c_size_t)
callback = fn('veil_media_set_recv_callback', [C.c_uint64, CALLBACK, P], C.c_int)
trace = fn('veil_debug_set_rt_trace', [C.c_int], None)
secondary_sender = fn('veil_media_channel_set_secondary_sender', [C.c_uint64, P, E], C.c_int)
shaper = None

def checked(f, *args):
    err = P()
    v = f(*args, C.byref(err))
    if err.value:
        detail = C.string_at(err).decode(errors='replace')
        free(err)
        raise RuntimeError(f.__name__ + ': ' + detail)
    return v

def admin(index, command):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(4)
        s.connect(str(ROOT / str(index) / 'admin.sock'))
        request = {'version': 1, 'command': {'command': command}}
        s.sendall((json.dumps(request) + '\n').encode())
        s.shutdown(socket.SHUT_WR)
        with s.makefile('rb') as reader:
            return json.loads(reader.readline())
identities = []
extra_handles = []
extra_apps = []
secondary_apps = []
nodes = []
handles = []
apps = []
channels = []
callbacks = []
result = {'loopback_only': True, 'cellular_call_proof': False, 'ok': False}
try:
    for index in range(3):
        directory = ROOT / str(index)
        directory.mkdir(mode=0o700, exist_ok=True)
        existing = directory / 'node.toml'
        if existing.exists():
            config = existing.read_text()
        else:
            text = checked(init, 0)
            config = C.string_at(text).decode()
            free(text)
        identities.append(tomllib.loads(config)['Identity'])
    ports = []
    for _ in identities:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(('127.0.0.1', 0))
        ports.append(s.getsockname()[1])
        s.close()
    if args.rate_kbps:
        shaper = UdpShaper([('127.0.0.1', port) for port in ports])
    for index, identity in enumerate(identities):
        directory = ROOT / str(index)
        lines = ['persist_enabled = false', '[global]', 'meeting_points = "off"', 'builtin_seed_policy = "never"', 'admin_socket = ' + json.dumps('unix://' + str(directory / 'admin.sock')), '[Identity]']
        for key in ['algo', 'public_key', 'private_key', 'nonce', 'node_id']:
            lines.append(key + ' = ' + json.dumps(identity[key]))
        lines += ['[anonymity]', 'relay_capable = true', '[ipc]', 'enabled = true', 'socket_uri = ' + json.dumps('unix://' + str(directory / 'ipc.sock')), '[[listen]]', 'id = "0x00000001"', 'transport = ' + json.dumps('quic://127.0.0.1:' + str(ports[index]))]
        if shaper is not None:
            lines.append('advertise = ' + json.dumps('quic://127.0.0.1:' + str(shaper.ports[index])))
        peers = [1, 2] if index == 0 else [0]
        for peer in peers:
            other = identities[peer]
            lines += ['[[peers]]', 'peer_id = ' + json.dumps('0x' + format(peer + 1, '08x')), 'public_key = ' + json.dumps(other['public_key']), 'nonce = ' + json.dumps(other['nonce']), 'algo = ' + json.dumps(other['algo']), 'transport = ' + json.dumps('quic://127.0.0.1:' + str(shaper.ports[peer] if shaper is not None else ports[peer]))]
        path = directory / 'node.toml'
        path.write_text('\n'.join(lines) + '\n')
        raw = str(path).encode()
        value = checked(start, raw, len(raw))
        assert value
        nodes.append(value)
    trace(1)
    for index in range(3):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                value = admin(index, 'sessions')
                (ROOT / ('sessions-' + str(index) + '.json')).write_text(json.dumps(value))
                rows = value.get('result', {}).get('sessions', [])
                expected = 2 if index == 0 else 1
                if len(rows) >= expected and all((row.get('state') == 'active' for row in rows)):
                    break
            except Exception:
                pass
            time.sleep(0.25)
        else:
            raise RuntimeError('No session on node ' + str(index))
    for index in (1, 2):
        uri = str(ROOT / str(index) / 'ipc.sock').encode()
        handle = checked(connect, uri, len(uri))
        assert handle
        handles.append(handle)
        app = checked(bind, handle, b'xveil-control', 13, b'media', 5, 0)
        assert app
        apps.append(app)
        secondary_handle = checked(connect, uri, len(uri))
        assert secondary_handle
        extra_handles.append(secondary_handle)
        secondary_app = checked(bind, secondary_handle, b'xveil-control', 13, b'media', 5, 1)
        assert secondary_app
        extra_apps.append(secondary_app)
        secondary_apps.append(secondary_app)
    ids = []
    appids = []
    for handle, app in zip(handles, apps):
        nid = C.create_string_buffer(32)
        aid = C.create_string_buffer(32)
        assert checked(nodeid, handle, nid) == 0
        assert appid(app, aid) == 0
        ids.append(nid)
        appids.append(aid)
        assert checked(recv, app, b'xveil-control', 13, b'media', 5) == 0
    keys = [os.urandom(32), os.urandom(32)]
    received = [[], []]
    video_received = [0, 0]
    video_sent = [0, 0]
    sent = [{}, {}]
    for index in range(2):
        ch = checked(openmedia, apps[index], ids[1 - index], appids[1 - index], 0, keys[index], keys[1 - index])
        assert ch
        channels.append(ch)
        assert checked(secondary_sender, ch, secondary_apps[index]) == 0

        def receive(context, payload, size, index=index):
            raw = C.string_at(payload, size)
            if raw[1] & 127 == 111:
                received[index].append((time.monotonic(), int.from_bytes(raw[12:16], 'big')))
            else:
                video_received[index] += 1
        cb = CALLBACK(receive)
        callbacks.append(cb)
        assert callback(ch, cb, None) == 0
    time.sleep(4)
    total = 1800 if args.compete_video else 500
    if shaper is not None:
        shaper.rate_bps = args.rate_kbps * 1000
    phase_at = []
    startat = time.monotonic()
    for seq in range(total):
        target = startat + seq * 0.02
        time.sleep(max(0, target - time.monotonic()))
        raw = bytes([128, 111]) + seq.to_bytes(2, 'big') + (seq * 960).to_bytes(4, 'big') + b'CTRL' + seq.to_bytes(4, 'big') + bytes(144)
        for index, ch in enumerate(channels):
            sent[index][seq] = time.monotonic()
            assert send(ch, raw, len(raw)) == 0
            if args.compete_video and seq >= 600:
                for packet in range(2):
                    video = bytes([128, 224]) + (seq * 2 + packet).to_bytes(2, 'big') + ((seq * 2 + packet) * 3000).to_bytes(4, 'big') + b'VIDE' + (seq * 2 + packet).to_bytes(4, 'big') + bytes(944)
                    rc = send(ch, video, len(video))
                    if rc == 0:
                        video_sent[index] += 1
        if seq in [0, min(599, total - 1), total - 1]:
            phase_at.append({'seq': seq, 't': time.monotonic() - startat, 'shaper': [dict(x) for x in shaper.stats] if shaper else []})
    time.sleep(2)
    result['directions'] = []
    result['video_sent'] = video_sent
    result['video_received'] = video_received
    result['neutral_shaper'] = shaper.stats if shaper else []
    result['rate_kbps'] = args.rate_kbps
    result['synthetic_video_offered'] = args.compete_video
    result['phase_observations'] = phase_at
    result['phases'] = []
    result['audio_samples'] = [{'received_at': at - startat, 'sequence': seq, 'delay_ms': (at - sent[1 - index][seq]) * 1000, 'direction': index} for index in range(2) for at, seq in received[index] if seq in sent[1 - index]]
    phases = [(0, 600, 'audio-only'), (600, total, 'audio-video')] if args.compete_video else [(0, total, 'audio-only')]
    for lo, hi, name in phases:
        directions = []
        for index in range(2):
            times = [(at - sent[1 - index][seq]) * 1000 for at, seq in received[index] if lo <= seq < hi]
            times.sort()
            directions.append({'received': len(times), 'sent': hi - lo, 'max_ms': max(times, default=None), 'p95_ms': times[int(0.95 * (len(times) - 1))] if times else None})
        result['phases'].append({'name': name, 'directions': directions})
    for index in range(2):
        latencies = [(at - sent[1 - index][seq]) * 1000 for at, seq in received[index] if seq in sent[1 - index]]
        gaps = [(b[0] - a[0]) * 1000 for a, b in zip(received[index], received[index][1:])]
        result['directions'].append({'sent': total, 'received': len(received[index]), 'unique': len(set((seq for _, seq in received[index]))), 'max_delay_ms': max(latencies, default=None), 'max_receive_gap_ms': max(gaps, default=None)})
    captured = log_path.read_text()
    hops = re.findall('ipc.rt_trace.relay_admission[^\\n]*hop=([a-f0-9]+)[^\\n]*datagram_transport=(true|false)', captured)
    relay_prefix = identities[0]['node_id'][:8]
    result['neutral_source_admission_samples'] = len(hops)
    result['neutral_datagram_route_verified'] = bool(hops) and all((hop == relay_prefix and ready == 'true' for hop, ready in hops))
    result['independent_datagram_admissions'] = len(re.findall('session.rt_trace.datagram_admission[^\\n]*independent=true', captured))
    result['ok'] = result['neutral_datagram_route_verified'] and all((x['unique'] == total and x['received'] == total and (x['max_delay_ms'] < 200) for x in result['directions']))
except Exception:
    (ROOT / 'failure.txt').write_text(traceback.format_exc())
    result['ok'] = False
    result['failure_saved_privately'] = True
finally:
    if shaper is not None:
        result['neutral_shaper_final'] = shaper.stats
        shaper.stop()
        result['shaper_failed'] = shaper.failure
        result['ok'] = result['ok'] and shaper.failure is None
    for ch in reversed(channels):
        mediaclose(ch)
    for app in reversed(extra_apps):
        appclose(app)
    for handle in reversed(extra_handles):
        close(handle)
    for app in reversed(apps):
        appclose(app)
    for handle in reversed(handles):
        close(handle)
    result['node_stop_results'] = [stop(node, 5000) for node in reversed(nodes)]
    result['ok'] = result['ok'] and all((code == 0 for code in result['node_stop_results']))
    result['remaining_fixture_sockets'] = len(list(ROOT.glob('*/*.sock')))
    result['ok'] = result['ok'] and result['remaining_fixture_sockets'] == 0
    samples = result.pop('audio_samples', [])
    (ROOT / 'audio-samples.json').write_text(json.dumps(samples))
    (ROOT / 'summary.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result), flush=True)
    raise SystemExit(0 if result['ok'] else 1)
