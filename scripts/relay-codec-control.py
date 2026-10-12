#!/usr/bin/env python3
"""Exercise real Opus/VP8 and the application's adapter over a neutral relay.

Requires Python 3.11+, cryptography, Dart, a node-embedded SDK and a WebRTC
media library built with VEIL_MEDIA_TEST_HOOKS=1. Uses no microphone, speaker
or application profile. Tone capture and decoded PCM run independently of
stats/control polling. The real Dart policy receives peer playout feedback
only after authenticated encrypted delivery through the same limited relay.
A blind FIFO limiter never reads or prioritises media. This loopback control
is not proof of physical cellular quality. All raw evidence stays private.
"""
import argparse, base64, hashlib, re, tempfile
import subprocess, threading, collections, math
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from udp_fifo_shaper import UdpShaper
from tcp_fifo_shaper import TcpShaper
from opaque_frame_capture import OpaqueFrameCapture
import ctypes as C
import json, os, socket, time, tomllib, traceback
from pathlib import Path
from pcm_timing import input_edges
os.umask(0o077)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sdk', type=Path, required=True)
parser.add_argument('--transport', choices=['quic', 'tcp', 'obfs4-tcp'], default='quic',
                    help='Loopback transport; TCP checks ordered fallback, obfs4-tcp checks authenticated independent channels')
parser.add_argument('--rate-kbps', type=int, default=0, help='Aggregate blind FIFO cap per direction across all connections; 0 leaves transport unrestricted')
parser.add_argument('--shaper-trace', action='store_true', help='Privately record blind FIFO timing and packet sizes, without payloads or addresses')
parser.add_argument('--chunk-trace', action='store_true', help='Privately correlate generic encrypted-envelope fragments across source and relay stages; not a media classifier')
parser.add_argument('--opaque-frame-capture', action='store_true', help='Boundedly hash opaque admin frame previews on owned fixture nodes; excludes plaintext and unknown identities')
parser.add_argument('--opaque-frame-capture-start-seconds', type=int, default=18,
                    help='Start the bounded opaque capture later to inspect a known periodic spike; default 18 seconds preserves the initial-phase capture')
parser.add_argument('--directory', type=Path, help='Private stand directory; reuse only a fixture created by this script')
parser.add_argument('--media', type=Path, required=True)
parser.add_argument('--adaptive-audio', action='store_true', help='Enable the production 209-byte audio framing hint before startup; requires a protobuf-enabled test-hook media library')
parser.add_argument('--audio-overhead-bytes', type=int, default=209,
                    help='Diagnostic framing estimate for adaptive Opus; default 209 retains production behavior')
parser.add_argument('--compact-media', action='store_true', help='Use compact relay audio batching, as the current application does, instead of the legacy audio/video batch format')
parser.add_argument('--duration', type=int, default=100)
parser.add_argument('--tone-period-ms', type=int, default=1000,
                    help='Tone transition interval; 1010 ms exercises different 10-ms input positions within Opus packets')
parser.add_argument('--feedback-interval-seconds', type=int, default=5,
                    help='Diagnostic feedback cadence; default retains the production five-second cadence')
parser.add_argument('--shared-control-ipc', action='store_true',
                    help='Diagnostic compatibility mode: share control and audio IPC; the application uses separate connections')
parser.add_argument('--compact-call-health', action='store_true',
                    help='Diagnostic compact call-state carrier on a separate IPC sender; requires the optional SDK call-control API, not proof of application integration')
parser.add_argument('--local-source-feedback', action='store_true', help='Feed actual endpoint quality to the shared local producer budget over negotiated IPC')
parser.add_argument('--compete-file', action='store_true', help='Transfer encrypted file chunks through the reliable local DATA lane in each direction during real audio/video; 512 KiB by default')
parser.add_argument('--file-bytes', type=int, default=512*1024, help='Bytes per competing file, a positive multiple of 2048; default keeps the full 512 KiB gate')
parser.add_argument('--no-video', action='store_true', help='Isolate real audio/file coexistence without starting a video encoder; not a full media-priority gate')
parser.add_argument('--screen-video', action='store_true',
                    help='Route synthetic VP8 through the separate screen producer and IPC connection; uses no screen capture')
parser.add_argument('--reannounce-interval-seconds', type=int,
                    help='Diagnostic routing refresh interval, below the unchanged 120-second route TTL; omitted retains production defaults')
args = parser.parse_args()
if args.chunk_trace:
    os.environ['VEIL_DIAG_CHUNKS'] = '1'
if args.rate_kbps < 0 or args.duration < 22:
    parser.error('Rate must be nonnegative and duration at least 22 seconds')
if args.feedback_interval_seconds < 1:
    parser.error('Feedback interval must be at least one second')
if not 500 <= args.tone_period_ms <= 5000:
    parser.error('Tone period must be 500–5000 milliseconds')
if not 1 <= args.audio_overhead_bytes <= 4096 or (not args.adaptive_audio and args.audio_overhead_bytes != 209):
    parser.error('Audio overhead must be 1–4096 bytes and an override requires --adaptive-audio')
if args.reannounce_interval_seconds is not None and not 0 < args.reannounce_interval_seconds < 120:
    parser.error('Diagnostic routing refresh interval must be between 1 and 119 seconds')
if args.file_bytes < 2048 or args.file_bytes % 2048:
    parser.error('File size must be a positive multiple of 2048 bytes')
if args.screen_video and args.no_video:
    parser.error('--screen-video requires video')
if args.compact_call_health and args.shared_control_ipc:
    parser.error('--compact-call-health requires separate control IPC')
if not 1 <= args.opaque_frame_capture_start_seconds < args.duration:
    parser.error('Opaque capture start must fall inside the stand duration')
if not args.opaque_frame_capture and args.opaque_frame_capture_start_seconds != 18:
    parser.error('A capture start override requires --opaque-frame-capture')
sdk_path = args.sdk.resolve(strict=True)
media_path = args.media.resolve(strict=True)
policy_path = Path(__file__).resolve().with_name('relay_codec_policy.dart')
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
SDK = C.CDLL(str(sdk_path), mode=C.RTLD_GLOBAL)
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
mediaclose = fn('veil_media_close_channel', [C.c_uint64], None)
trace = fn('veil_debug_set_rt_trace', [C.c_int], None)
# Mirrors the SDK's stable repr(C) VeilMediaChannelStats (13 plain u64s).
# These are cumulative local IPC/queue maxima, not network-delay measurements.
class MediaChannelStats(C.Structure):
    _fields_ = [(name, C.c_uint64) for name in (
        'video_frames_enqueued', 'video_frames_started', 'video_queue_depth',
        'video_queue_max_depth', 'video_queue_age_max_ms', 'video_queue_holds_75ms',
        'sender_lock_max_ms', 'sender_lock_holds_16ms', 'video_frame_ipc_max_ms',
        'video_frame_ipc_holds_33ms', 'ipc_cell_max_ms', 'ipc_cell_holds_16ms',
        'ipc_send_failures')]
channelstats = fn('veil_media_channel_get_stats',
                  [C.c_uint64, C.POINTER(MediaChannelStats)], C.c_int)

secondary_sender = fn('veil_media_channel_set_secondary_sender', [C.c_uint64, P, E], C.c_int)
screen_sender = fn('veil_media_channel_set_screen_sender', [C.c_uint64, P, E], C.c_int) if args.screen_video else None
screen_select = fn('veil_media_channel_set_screen_sharing', [C.c_uint64, C.c_int], C.c_int) if args.screen_video else None
source_report = fn('veil_app_report_local_source_pressure', [P, C.c_uint8, C.c_uint64, E], C.c_int) if args.local_source_feedback else None
shaper = None
startat = None

def clock_observation():
    before=time.monotonic_ns()//1000
    unix=time.time_ns()//1000
    after=time.monotonic_ns()//1000
    return {'monotonic_us':(before+after)//2,'unix_us':unix,
            'uncertainty_us':after-before}

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
screen_apps = []
nodes = []
handles = []
apps = []
channels = []
callbacks = []
engines=[]
policy=None
media=None
audio_thread=None
audio_stop=threading.Event()
audio_failure=[]
source_feedback_queued=[0,0]
source_feedback_skipped=[0,0]
opaque_capture=None
file_threads=[]
file_stop=threading.Event()
file_lock=threading.Lock()
file_results=[{},{}]
file_started=[None,None]
file_send_failures=[collections.Counter(),collections.Counter()]
file_apps=[]
file_bytes=args.file_bytes
file_payloads=[os.urandom(file_bytes),os.urandom(file_bytes)] if args.compete_file else []
result = {'loopback_only': True, 'cellular_call_proof': False, 'ok': False,
          'session_transport': args.transport,
          'synthetic_video_source': 'screen' if args.screen_video else 'camera',
          'screen_capture_proof': False,
          'duration_seconds': args.duration,
          'feedback_interval_seconds': args.feedback_interval_seconds,
          'independent_control_ipc': not args.shared_control_ipc,
          'competing_file_bytes': file_bytes if args.compete_file else 0}
result['reannounce_interval_seconds_override'] = args.reannounce_interval_seconds
result['opaque_frame_capture_start_seconds'] = args.opaque_frame_capture_start_seconds if args.opaque_frame_capture else None
result['control_carrier'] = 'compact_call_state_diagnostic' if args.compact_call_health else 'authenticated_application_envelope'
try:
    if args.transport == 'obfs4-tcp':
        # Private, disposable fixture key shared by its three loopback nodes.
        # Authenticated obfs4 exposes the auxiliary-stream handle; plain TCP
        # intentionally retains its single ordered connection.
        psk_path = ROOT / 'obfs4_psk.b64'
        psk_path.write_text(base64.b64encode(os.urandom(32)).decode() + '\n')
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
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM if args.transport == 'quic' else socket.SOCK_STREAM)
        s.bind(('127.0.0.1', 0))
        ports.append(s.getsockname()[1])
        s.close()
    if args.rate_kbps:
        shaper_type = UdpShaper if args.transport=='quic' else TcpShaper
        shaper = shaper_type([('127.0.0.1', port) for port in ports], trace=args.shaper_trace)
    for index, identity in enumerate(identities):
        directory = ROOT / str(index)
        lines = ['persist_enabled = false', '[global]', 'meeting_points = "off"', 'builtin_seed_policy = "never"', 'admin_socket = ' + json.dumps('unix://' + str(directory / 'admin.sock')), '[Identity]']
        for key in ['algo', 'public_key', 'private_key', 'nonce', 'node_id']:
            lines.append(key + ' = ' + json.dumps(identity[key]))
        if args.transport == 'obfs4-tcp':
            lines += ['[transport]', 'obfs4_psk_file = ' + json.dumps(str(psk_path))]
        # Local-only runtime counters cover drops before the UDP shaper and
        # after transport receipt. No externally reachable metrics listener.
        lines += ['[metrics]', 'listen = "tcp://127.0.0.1:0"']
        if args.reannounce_interval_seconds is not None:
            lines += ['[routing]', 'reannounce_interval_secs = ' + str(args.reannounce_interval_seconds)]
        lines += ['[anonymity]', 'relay_capable = true', '[ipc]', 'enabled = true', 'socket_uri = ' + json.dumps('unix://' + str(directory / 'ipc.sock')), '[[listen]]', 'id = "0x00000001"', 'transport = ' + json.dumps(args.transport + '://127.0.0.1:' + str(ports[index]))]
        if shaper is not None:
            lines.append('advertise = ' + json.dumps(args.transport + '://127.0.0.1:' + str(shaper.ports[index])))
        peers = [1, 2] if index == 0 else [0]
        for peer in peers:
            other = identities[peer]
            lines += ['[[peers]]', 'peer_id = ' + json.dumps('0x' + format(peer + 1, '08x')), 'public_key = ' + json.dumps(other['public_key']), 'nonce = ' + json.dumps(other['nonce']), 'algo = ' + json.dumps(other['algo']), 'transport = ' + json.dumps(args.transport + '://127.0.0.1:' + str(shaper.ports[peer] if shaper is not None else ports[peer]))]
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
        if args.screen_video:
            screen_handle = checked(connect, uri, len(uri))
            assert screen_handle
            extra_handles.append(screen_handle)
            screen_app = checked(bind, screen_handle, b'xveil-control', 13, b'media', 5, 2)
            assert screen_app
            extra_apps.append(screen_app)
            screen_apps.append(screen_app)
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
    media=C.CDLL(str(media_path),mode=C.RTLD_GLOBAL)
    def mf(name,types,ret):
        f=getattr(media,name);f.argtypes=types;f.restype=ret;return f
    create=mf('veil_media_test_adaptive_codec_create',[C.c_uint64,P,P,C.c_int],P) if args.adaptive_audio else mf('veil_media_test_duplex_codec_create',[C.c_uint64,P,P],P)
    destroy=mf('veil_media_engine_destroy',[P],None)
    capture=mf('veil_media_test_audio_capture_tone',[P,C.c_int],C.c_int)
    playout=mf('veil_media_test_audio_playout_pcm',[P,P,C.c_size_t],C.c_int)
    getstats=mf('veil_media_engine_get_stats',[P],P)
    mfree=mf('veil_media_free_string',[P],None)
    startvideo=mf('veil_media_engine_start_video',[P,C.c_int,C.c_int,C.c_int,C.c_int],C.c_int)
    pause=mf('veil_media_engine_set_video_send_paused',[P,C.c_int],C.c_int)
    budget=mf('veil_media_engine_set_video_budget',[P,C.c_int,C.c_double],C.c_int)
    batching=fn('veil_media_channel_set_batching',[C.c_uint64,C.c_int],C.c_int)
    keys=[os.urandom(32),os.urandom(32)]
    healthkeys=[AESGCM(os.urandom(32)),AESGCM(os.urandom(32))]
    controlapps=[];controlids=[];inbox=[collections.deque(),collections.deque()]
    noncecounter=[0,0];healthsent=[0,0];healthrecv=[0,0];healthbad=[0,0]
    control_attempts=[0,0];control_failures=[0,0]
    # Bounded local timing only: no control contents or destination identifiers.
    # Submission/return measures IPC admission, never end-to-end receipt.
    control_send_samples=collections.deque(maxlen=512)
    handler_type=C.CFUNCTYPE(None,P,P,P,C.c_uint8,C.c_uint64,P,C.c_size_t)
    handler=fn('veil_app_set_recv_handler',[P,handler_type,P,E],C.c_int)
    freebuf=fn('veil_free_buf',[P,C.c_size_t],None)
    normalsend=fn('veil_send',[P,P,P,C.c_uint32,P,C.c_size_t,E],C.c_int)
    controlsend=fn('veil_send_relay_realtime',[P,P,P,C.c_uint32,P,C.c_size_t,E],C.c_int)
    service=os.urandom(16).hex().encode()
    for index in range(2):
        # The application has independent media and signaling IPC clients.
        # An inline control seal/route request on the audio socket would delay
        # subsequent media requests before their network child can admit them.
        control_handle=handles[index]
        if not args.shared_control_ipc:
            uri=str(ROOT / str(index+1) / 'ipc.sock').encode()
            control_handle=checked(connect,uri,len(uri))
            extra_handles.append(control_handle)
        control=checked(bind,control_handle,service,len(service),b'opaque',6,2)
        extra_apps.append(control);controlapps.append(control)
        aid=C.create_string_buffer(32);assert appid(control,aid)==0;controlids.append(aid)
    if args.compete_file:
        filesend=fn('veil_send_on_local_lane',[P,P,P,C.c_uint32,P,C.c_size_t,C.c_uint8,C.c_uint8,E],C.c_int)
        fileids=[];filekeys=[AESGCM(os.urandom(32)),AESGCM(os.urandom(32))]
        event_type=C.CFUNCTYPE(None,P,C.c_uint8,P,C.c_size_t)
        events=fn('veil_set_event_handler',[P,event_type,P,E],C.c_int)
        chunks=[{},{}];file_auth_errors=[0,0];file_duplicates=[0,0]
        for i in range(2):
            uri=str(ROOT / str(i+1) / 'ipc.sock').encode()
            handle=checked(connect,uri,len(uri));extra_handles.append(handle)
            app=checked(bind,handle,service,len(service),b'file',4,3)
            assert app;extra_apps.append(app);file_apps.append(app)
            aid=C.create_string_buffer(32);assert appid(app,aid)==0;fileids.append(aid)
            def receive_file_event(user,kind,data,size,i=i):
                try:
                    if kind==4:  # SDK asynchronous failure, not IPC queue success.
                        raw=C.string_at(data,size) if size else b''
                        code=str(int.from_bytes(raw,'big')) if size==2 else 'unclassified'
                        with file_lock:file_send_failures[i][code]+=1
                finally:
                    if size:freebuf(data,size)
            event_cb=event_type(receive_file_event);callbacks.append(event_cb)
            assert checked(events,handle,event_cb,None)==0
        for i in range(2):
            def receive_file(user,node,app,provenance,reply,data,size,i=i):
                try:
                    assert C.string_at(node,32)==ids[1-i].raw[:32]
                    assert C.string_at(app,32)==fileids[1-i].raw[:32]
                    raw=C.string_at(data,size);index=int.from_bytes(raw[:12],'big')
                    assert 0<=index<file_bytes//2048
                    chunk=filekeys[1-i].decrypt(raw[:12],raw[12:],b'codec-file-v1')
                    assert len(chunk)==2048
                    with file_lock:
                        if index in chunks[i]:file_duplicates[i]+=1
                        chunks[i][index]=chunk
                        file_results[i].update(received=len(chunks[i])*2048,missing_chunks=file_bytes//2048-len(chunks[i]))
                        if len(chunks[i])==file_bytes//2048:
                            data=b''.join(chunks[i][n] for n in range(file_bytes//2048))
                            file_results[i].update(received=len(data),hash_matches=hashlib.sha256(data).digest()==hashlib.sha256(file_payloads[1-i]).digest(),receipt_duration_ms=round((time.monotonic()-file_started[1-i])*1000,1) if file_started[1-i] is not None else None)
                except Exception:file_auth_errors[i]+=1
                finally:freebuf(node,64+size)
            cb=handler_type(receive_file);callbacks.append(cb)
            assert checked(handler,file_apps[i],cb,None)==0
        def write_file(i):
            try:
                began=time.monotonic();file_started[i]=began
                sent=0
                for off in range(0,file_bytes,2048):
                    if file_stop.is_set():break
                    nonce=(off//2048).to_bytes(12,'big')
                    payload=nonce+filekeys[i].encrypt(nonce,file_payloads[i][off:off+2048],b'codec-file-v1')
                    # Local selector 4 is stripped by IPC before the network.
                    # This exercises reliable DATA admission and the app's
                    # encrypted datagram-file fallback, not a direct-only stream.
                    assert checked(filesend,file_apps[i],ids[1-i],fileids[1-i],3,payload,len(payload),4,0)==0
                    sent+=2048
                with file_lock:file_results[i].update(queued=sent,queue_duration_ms=round((time.monotonic()-began)*1000,1))
            except Exception as e:
                with file_lock:file_results[i]['write_error']=type(e).__name__
                (ROOT/f'file-{i}-write-error.log').write_text(traceback.format_exc())
    for index in range(2):
        def receive_health(user,node,app,provenance,reply,data,size,index=index):
            try:
                assert C.string_at(node,32)==ids[1-index].raw[:32]
                assert C.string_at(app,32)==controlids[1-index].raw[:32]
                raw=C.string_at(data,size)
                value=json.loads(healthkeys[1-index].decrypt(raw[:12],raw[12:],b'codec-control-v1'))
                inbox[index].append({'at':int(time.time()*1000),'value':value})
                healthrecv[index]+=1
            except Exception:healthbad[index]+=1
            finally:freebuf(node,64+size)
        cb=handler_type(receive_health);callbacks.append(cb)
        assert checked(handler,controlapps[index],cb,None)==0
        ch=checked(openmedia,apps[index],ids[1-index],appids[1-index],0,keys[index],keys[1-index])
        assert ch;channels.append(ch)
        assert checked(secondary_sender,ch,secondary_apps[index])==0
        if args.screen_video:
            assert checked(screen_sender,ch,screen_apps[index])==0
            assert screen_select(ch,1)==0
        assert batching(ch,2 if args.compact_media else 1)==0
    if args.compact_call_health:
        compact_configure=fn('veil_media_channel_set_control_sender',[C.c_uint64,P,E],C.c_int)
        compact_send=fn('veil_media_send_call_control',[C.c_uint64,P,C.c_size_t],C.c_int)
        compact_poll=fn('veil_media_poll_call_control',[C.c_uint64,P,C.c_size_t],C.c_int)
        compact_buffers=[C.create_string_buffer(768) for _ in range(2)]
        rejected_foreign_control_apps=[]
        for i,ch in enumerate(channels):
            try:
                checked(compact_configure,ch,controlapps[i])
            except RuntimeError:
                rejected_foreign_control_apps.append(True)
            else:
                raise RuntimeError('Compact control accepted a different app identity')
            uri=str(ROOT / str(i+1) / 'ipc.sock').encode()
            handle=checked(connect,uri,len(uri));extra_handles.append(handle)
            app=checked(bind,handle,b'xveil-control',13,b'media',5,4)
            extra_apps.append(app)
            assert checked(compact_configure,ch,app)==0
        result['compact_control_app_identity_verified']=all(rejected_foreign_control_apps)
    os.environ['VEIL_MEDIA_TEST_VIDEO']='1'
    for i,ch in enumerate(channels):
        e=create(ch,ids[i],ids[1-i],args.audio_overhead_bytes) if args.adaptive_audio else create(ch,ids[i],ids[1-i])
        assert e;engines.append(e)
    policylog=(ROOT/'policy.err').open('w')
    policy=subprocess.Popen(['dart',str(policy_path)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=policylog,text=True,bufsize=1,env=dict(os.environ,TMPDIR='/private/tmp/'))
    def command(v):
        policy.stdin.write(json.dumps(v)+'\n');policy.stdin.flush()
        response=policy.stdout.readline()
        if not response:raise RuntimeError('Policy helper stopped')
        return json.loads(response)
    pcm=(C.c_int16*480)();pcmrows=[];samples=[];nativefail=[0,0];pollfail=[0,0]
    # Prime the endpoint certificate cache through ordinary encrypted delivery;
    # control's cached-only path deliberately never initiates DHT discovery.
    for i in range(2):
        nonce=noncecounter[i].to_bytes(12,'big');noncecounter[i]+=1
        payload=nonce+healthkeys[i].encrypt(nonce,json.dumps({'n':0}).encode(),b'codec-control-v1')
        checked(normalsend,controlapps[i],ids[1-i],controlids[1-i],2,payload,len(payload))
    command({'index':0,'op':'ack','pauseOk':False,'budgetOk':False})
    time.sleep(4)
    metrics_before = [admin(i, 'metrics')['result'] for i in range(3)]
    assert all(m.get('metrics_enabled') for m in metrics_before), 'Fixture metrics are disabled'
    (ROOT/'metrics-before.json').write_text(json.dumps(metrics_before))
    if shaper:shaper.rate_bps=args.rate_kbps*1000
    startat=time.monotonic();lasttick=startat;maxscheduler=0;videostarted=False;latestfeedback=[None,None];targets=[None,None]
    clock_observations=[clock_observation()]
    # Bound in-memory timing evidence; never do diagnostic I/O on the PCM
    # thread. Locate host scheduling stalls instead of attributing them to QUIC.
    driver_late_intervals=[];driver_late_count=0
    def audio_loop():
        global maxscheduler,driver_late_count
        try:
            lasttick=time.monotonic();deadline=lasttick;source_tick=0
            while not audio_stop.is_set():
                audio_stop.wait(max(0,deadline-time.monotonic()))
                if audio_stop.is_set():break
                now=time.monotonic();interval_ms=(now-lasttick)*1000;maxscheduler=max(maxscheduler,interval_ms);lasttick=now
                if interval_ms>=20:
                    driver_late_count+=1
                    if len(driver_late_intervals)<128:
                        driver_late_intervals.append({'t':round(now-startat,4),'interval_ms':round(interval_ms,2)})
                freq=500 if int((now-startat)*1000)//args.tone_period_ms%2==0 else 1000
                for i,e in enumerate(engines):
                    source_at=time.monotonic()-startat
                    if capture(e,freq)!=0:nativefail[i]+=1
                    n=playout(e,pcm,480)
                    if n>0:
                        rms=math.sqrt(sum(int(pcm[k])**2 for k in range(n))/n)
                        crossings=sum((pcm[k]>=0)!=(pcm[k-1]>=0) for k in range(1,n))
                        pcmrows.append({'t':time.monotonic()-startat,'side':i,'rms':round(rms,1),'freq':crossings*48000/(2*n),'source_freq':freq,'source_tick':source_tick,'source_at':source_at})
                    else:nativefail[i]+=1
                source_tick+=1
                deadline+=.01
                if deadline<time.monotonic()-.01:deadline=time.monotonic()+.01
        except Exception:
            audio_failure.append(traceback.format_exc())
            audio_stop.set()
    audio_thread=threading.Thread(target=audio_loop,name='stand-pcm');audio_thread.start()
    for tick in range(args.duration*100):
        target=startat+tick*.01;time.sleep(max(0,target-time.monotonic()))
        if args.opaque_frame_capture and tick==100*args.opaque_frame_capture_start_seconds:
            opaque_capture=OpaqueFrameCapture(ROOT, [identity['node_id'] for identity in identities])
            opaque_capture.start()
        if tick%100==0:
            if args.compact_call_health:
                for i,ch in enumerate(channels):
                    for _ in range(8):
                        count=compact_poll(ch,compact_buffers[i],768)
                        if count==0:break
                        if count<0:
                            healthbad[i]+=1
                            break
                        try:
                            raw=compact_buffers[i].raw[:count]
                            value=json.loads(healthkeys[1-i].decrypt(raw[:12],raw[12:],b'codec-control-v1'))
                            inbox[i].append({'at':int(time.time()*1000),'value':value})
                            healthrecv[i]+=1
                        except Exception:healthbad[i]+=1
            prepare=tick>=2000 and not videostarted
            for i,e in enumerate(engines):
                ptr=getstats(e)
                if not ptr:pollfail[i]+=1;continue
                try:stats=json.loads(C.string_at(ptr))
                finally:mfree(ptr)
                feedback=[]
                while inbox[i]:feedback.append(inbox[i].popleft())
                sampled_at=int(time.time()*1000)
                r=command({'index':i,'op':'stats','now':sampled_at,'stats':stats,'feedback':feedback,'prepare':prepare,'videoSendExpected':videostarted and not args.no_video})
                if source_report is not None and r['sourcePressured'] is not None:
                    rc=checked(source_report,apps[i],int(r['sourcePressured']),sampled_at)
                    if rc==0:source_feedback_queued[i]+=1
                    elif rc==1:source_feedback_skipped[i]+=1
                    else:raise RuntimeError('Local source feedback refused')
                latestfeedback[i]=r['feedback'];targets[i]=r['target']
                pauseok=True;budgetok=True
                if r['pause'] is not None:pauseok=pause(e,int(r['pause']))==0
                if r['budget'] is not None:budgetok=budget(e,r['budget']['kbps'],r['budget']['fps'])==0
                command({'index':i,'op':'ack','pauseOk':pauseok,'budgetOk':budgetok})
                samples.append({'t':time.monotonic()-startat,'side':i,'stats':stats,'policy':r,'pause_ok':pauseok,'budget_ok':budgetok})
            if prepare:
                if not args.no_video:
                    for i,e in enumerate(engines):
                        t=targets[i]
                        assert startvideo(e,1,1,t['kbps'],max(1,math.ceil(t['fps'])))==0
                        budget(e,t['kbps'],t['fps'])
                videostarted=True
                if args.compete_file:
                    for i in range(2):
                        thread=threading.Thread(target=write_file,args=(i,),name='stand-file')
                        file_threads.append(thread);thread.start()
            if tick%(100*args.feedback_interval_seconds)==0:
                for i in range(2):
                    nonce=noncecounter[i].to_bytes(12,'big');noncecounter[i]+=1
                    payload=nonce+healthkeys[i].encrypt(nonce,json.dumps(latestfeedback[i]).encode(),b'codec-control-v1')
                    submitted_at=time.monotonic()
                    rc=compact_send(channels[i],payload,len(payload)) if args.compact_call_health else checked(controlsend,controlapps[i],ids[1-i],controlids[1-i],2,payload,len(payload))
                    returned_at=time.monotonic()
                    control_attempts[i]+=1
                    control_send_samples.append({'side':i,
                        'submitted_at_seconds':submitted_at-startat,
                        ('local_queue_admission_ms' if args.compact_call_health else 'ipc_admission_ms'):(returned_at-submitted_at)*1000,
                        'encrypted_application_bytes':len(payload),'result':rc})
                    if rc==0:healthsent[i]+=1
                    else:control_failures[i]+=1
    clock_observations.append(clock_observation())
    audio_stop.set();audio_thread.join(timeout=5)
    assert not audio_thread.is_alive()
    if audio_failure:(ROOT/'audio-thread-failure.txt').write_text(''.join(audio_failure))
    metrics_after = [admin(i, 'metrics')['result'] for i in range(3)]
    (ROOT/'metrics-after.json').write_text(json.dumps(metrics_after))
    counter_names = ['session_tx_drops_total','priority_queue_drops_total',
                     'session_outbox_drops_total','ipc_delivery_drops_total',
                     'send_to_failed_total','dropped_relay_frames_total',
                     'session_write_stalled_total','chunks_reassembled_total',
                     'decrypt_failures_total','app_msg_channel_full_total',
                     'app_msg_channel_closed_total','rate_limit_drops_total']
    result['runtime_counter_deltas'] = [{k:after[k]-before[k] for k in counter_names}
                                      for before,after in zip(metrics_before,metrics_after)]
    (ROOT/'pcm-samples.json').write_text(json.dumps(pcmrows))
    (ROOT/'codec-samples.json').write_text(json.dumps(samples))
    result.update(stand_start_monotonic_us=round(startat*1_000_000),real_opus=True,real_vp8=not args.no_video,video_requested=not args.no_video,application_adapter=True,on_path_encrypted_playout_feedback=True,health_sent=healthsent,health_received_including_bootstrap=healthrecv,health_auth_errors=healthbad,max_driver_interval_ms=round(maxscheduler,2),native_failures=nativefail,poll_failures=pollfail,audio_thread_failures=len(audio_failure))
    result.update(control_send_attempts=control_attempts,
                  control_send_failures=control_failures,
                  control_send_samples=list(control_send_samples),
                  control_send_samples_truncated=sum(control_attempts)>control_send_samples.maxlen)
    result['stand_clock_observations']=clock_observations
    result.update(driver_late_intervals=driver_late_intervals,driver_late_interval_count=driver_late_count)
    result['adaptive_audio'] = args.adaptive_audio
    result['audio_overhead_bytes_override'] = args.audio_overhead_bytes if args.adaptive_audio else None
    result['compact_media'] = args.compact_media
    if args.adaptive_audio:
        result['adaptive_audio_verified'] = all(
            any(x['side'] == side and x['stats'].get('audio_packet_adaptation') == 1
                and x['stats'].get('audio_packet_overhead_bytes') == args.audio_overhead_bytes for x in samples)
            for side in range(2)) and all(
            x['stats'].get('audio_packet_adaptation') == 1
            and x['stats'].get('audio_packet_overhead_bytes') == args.audio_overhead_bytes
            for x in samples)
        result['codec_target_bounds_verified'] = all(
            any(x['side'] == side and x['stats'].get('audio_tx_payload_pkts', 0) > 0 for x in samples)
            for side in range(2)) and all(
            # WebRTC reports -1 until the first payload is encoded. This is
            # unknown startup telemetry, not an out-of-range codec target.
            (x['stats'].get('audio_tx_payload_pkts') == 0
             and x['stats'].get('audio_encoder_target_bps') == -1)
            or 16000 <= x['stats'].get('audio_encoder_target_bps', -1) <= 32000
            for x in samples)
    phases=[]
    for lo,hi,name in [(5,20,'audio-only'),(20,args.duration,'audio-file' if args.no_video and args.compete_file else 'audio-only-continuation' if args.no_video else 'audio-video')]:
        directions=[]
        for i in range(2):
            rows=[x for x in samples if x['side']==i and lo<=x['t']<hi]
            dec=[x for x in pcmrows if x['side']==i and lo<=x['t']<hi]
            quiet=[x for x in dec if x['rms']<500]
            stats=[x['stats'] for x in rows]
            metrics={k:max((s.get(k,0) or 0 for s in stats),default=0) for k in ['audio_delay_ms','audio_jb_ms','audio_interruption_count','audio_interruption_duration_ms','audio_rx_native_age_ms','video_tx_frames','video_rx_deliver_frames']}
            directions.append({'maxima':metrics,'pcm_frames':len(dec),'quiet_pcm_frames':len(quiet),'video_pause_samples':sum(x['policy']['audioReserve'] for x in rows)})
        phases.append({'name':name,'directions':directions})
    # PCM frequency edges expose actual source-to-playout delay, including
    # codec/pacer latency absent from the receive-buffer estimate. No peer
    # quality is fed to the adapter via these local measurement observations.
    result['decoded_pcm_edges'] = []
    result['tone_period_ms'] = args.tone_period_ms
    phase_coverage=[]
    for side in range(2):
        source = [x for x in pcmrows if x['side'] == 1-side]
        rendered = [x for x in pcmrows if x['side'] == side]
        measured_edges=input_edges(source)
        edges=[(at,freq) for at,freq,_ in measured_edges]
        edge_ticks=[tick for at,_,tick in measured_edges if at>=20]
        decoded=[]; last=None
        for x in rendered:
            f = 500 if abs(x['freq']-500)<150 else 1000 if abs(x['freq']-1000)<150 else None
            if f is not None and x['rms']>=500 and f!=last:
                decoded.append((x['t'],f)); last=f
        summaries=[]
        for lo,hi,name in [(5,20,'audio-only'),(20,args.duration,'audio-file' if args.no_video and args.compete_file else 'audio-only-continuation' if args.no_video else 'audio-video')]:
            delays=[]; missing=0
            for i,(at,f) in enumerate(edges):
                if not lo<=at<hi: continue
                end=edges[i+1][0] if i+1<len(edges) else hi
                match=next((t for t,value in decoded if at<=t<end and value==f),None)
                if match is None: missing+=1
                else: delays.append((match-at)*1000)
            delays.sort()
            summaries.append({'name':name,'matched':len(delays),'missing':missing,
                              'p95_ms':delays[int(.95*(len(delays)-1))] if delays else None,
                              'max_ms':max(delays,default=None)})
        durations=sorted({x['stats'].get('audio_tx_packet_duration_ms',0) for x in samples
                          if x['side']==1-side and x['stats'].get('audio_tx_payload_pkts',0)>0})
        positions={str(d):sorted({tick%(d//10) for tick in edge_ticks})
                   for d in durations if d>=10 and d%10==0}
        phase_coverage.append(bool(durations) and all(
            positions.get(str(d))==list(range(d//10)) for d in durations))
        result['decoded_pcm_edges'].append({'side':side,'phases':summaries,
                                           'source_edge_capture_positions':positions})
    result['phases']=phases
    captured=log_path.read_text();hops=re.findall('ipc.rt_trace.relay_admission[^\n]*hop=([a-f0-9]+)[^\n]*datagram_transport=(true|false)',captured)
    result['neutral_datagram_route_verified']=bool(hops) and args.transport=='quic' and all(h==identities[0]['node_id'][:8] and ready=='true' for h,ready in hops)
    expected_ready = 'true' if args.transport=='obfs4-tcp' else 'false'
    result['neutral_ordered_route_verified']=bool(hops) and args.transport!='quic' and all(h==identities[0]['node_id'][:8] and ready==expected_ready for h,ready in hops)
    if args.transport=='obfs4-tcp':
        offers=[line for line in captured.splitlines() if 'session.channels_offered' in line]
        result['independent_ordered_channels_offered_verified']=len(offers)>=4 and all(
            all(field+'=true' in line for field in ['ordered_available', 'peer_flows', 'peer_rotates', 'peer_parallel_ordered'])
            for line in offers)
        independent_slots=collections.Counter(re.findall(
            r'session.realtime_datagram.first_send[^\n]*local_slot=([0-9]+)\s+independent=true', captured))
        required_slots=['0'] if args.no_video else ['0', '3' if args.screen_video else '2']
        result['independent_ordered_media_send_verified']=all(
            independent_slots[slot]>=2 for slot in required_slots)
    route_ok = result['neutral_datagram_route_verified'] if args.transport=='quic' else result['neutral_ordered_route_verified']
    mixed=phases[-1]['directions']
    pcm_ok=all(x['phases'][-1]['missing']==0 and x['phases'][-1]['matched']>0 and x['phases'][-1]['max_ms']<200 for x in result['decoded_pcm_edges'])
    video_ok = all(d['maxima']['video_tx_frames']>0 and d['maxima']['video_rx_deliver_frames']>0 for d in mixed) if not args.no_video else all(d['maxima']['video_tx_frames']==0 and d['maxima']['video_rx_deliver_frames']==0 for d in mixed)
    result['ok']=pcm_ok and video_ok and not audio_failure and maxscheduler<40 and route_ok and not any(nativefail+pollfail+healthbad+control_failures) and all(healthrecv[i]==healthsent[1-i]+1 for i in range(2)) and all(d['maxima']['audio_delay_ms']<200 and d['maxima']['audio_interruption_count']==0 and d['quiet_pcm_frames']==0 for d in mixed)
    result['tone_phase_coverage_verified']=all(phase_coverage)
    if args.tone_period_ms!=1000:result['ok']=result['ok'] and result['tone_phase_coverage_verified']
    if args.transport=='obfs4-tcp':
        result['ok']=result['ok'] and result['independent_ordered_channels_offered_verified'] and result['independent_ordered_media_send_verified']
    if args.adaptive_audio:
        result['ok'] = result['ok'] and result['adaptive_audio_verified'] and result['codec_target_bounds_verified']
    result.update(local_source_feedback=args.local_source_feedback,source_feedback_queued=source_feedback_queued,source_feedback_skipped=source_feedback_skipped,reliable_file_contention=args.compete_file,file_results=file_results if args.compete_file else [])
    if args.local_source_feedback:result['ok']=result['ok'] and all(source_feedback_queued) and not any(source_feedback_skipped)
    if args.compete_file:
        with file_lock:
            for i in range(2):
                file_results[i]['missing_indices'] = sorted(set(range(file_bytes//2048)) - chunks[i].keys())
        result.update(file_auth_errors=file_auth_errors,file_duplicates=file_duplicates,file_async_send_failures=[dict(x) for x in file_send_failures])
        result['ok']=result['ok'] and all(x.get('hash_matches') and x.get('queued')==file_bytes for x in file_results) and not any(file_auth_errors+file_duplicates) and not any(file_send_failures)
except Exception:
    (ROOT/'failure.txt').write_text(traceback.format_exc())
    result['ok']=False;result['failure_saved_privately']=True
finally:
    audio_stop.set()
    if audio_thread is not None:
        audio_thread.join(timeout=5)
        result['audio_thread_exited']=not audio_thread.is_alive()
    file_stop.set()
    # Join producers before closing their application bindings.
    for thread in file_threads:thread.join(timeout=5)
    result['file_threads_exited']=all(not t.is_alive() for t in file_threads)
    result['ok']=result['ok'] and result['file_threads_exited']
    if opaque_capture is not None:
        opaque_capture.stop()
        snapshot=opaque_capture.snapshot()
        (ROOT/'opaque-frame-capture.json').write_text(json.dumps(snapshot))
        result['opaque_frame_capture']={key:value for key,value in snapshot.items() if key!='rows'}
        result['ok']=result['ok'] and snapshot['readers_exited'] and not snapshot['reader_errors'] and len(snapshot['ack_nodes'])==len(identities)
    if policy is not None:
        policy.stdin.close()
        try:policy.wait(timeout=5)
        except subprocess.TimeoutExpired:policy.kill();policy.wait()
        result['policy_exited']=policy.poll() is not None
    for e in reversed(engines):destroy(e)
    # Sample before closing channel handles, after media production has stopped.
    # No per-packet logging or extra polling perturbs the live driver.
    result['local_media_channel_stats'] = []
    for ch in channels:
        snapshot = MediaChannelStats()
        rc = channelstats(ch, C.byref(snapshot))
        result['local_media_channel_stats'].append(
            {name: getattr(snapshot, name) for name, _ in snapshot._fields_}
            if rc == 0 else {'snapshot_error': rc})
        result['ok'] = result['ok'] and rc == 0

    if shaper is not None:
        result['neutral_shaper_final']=shaper.stats
        shaper.stop()
        if shaper.trace_rows is not None:
            (ROOT/'shaper-queues.json').write_text(json.dumps({'startat':startat,'events':shaper.trace_events,'rows':list(shaper.trace_rows)}))
        result['shaper_failed']=shaper.failure
        result['ok']=result['ok'] and shaper.failure is None
    for ch in reversed(channels):mediaclose(ch)
    for app in reversed(extra_apps):appclose(app)
    for h in reversed(extra_handles):close(h)
    for app in reversed(apps):appclose(app)
    for h in reversed(handles):close(h)
    result['node_stop_results']=[stop(n,5000) for n in reversed(nodes)]
    result['remaining_fixture_sockets']=len(list(ROOT.glob('*/*.sock')))
    result['ok']=result['ok'] and all(c==0 for c in result['node_stop_results']) and not result['remaining_fixture_sockets']
    (ROOT/'summary.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result),flush=True)
    raise SystemExit(0 if result['ok'] else 1)
