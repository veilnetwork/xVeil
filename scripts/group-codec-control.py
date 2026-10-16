#!/usr/bin/env python3
"""Real three-party Opus/VP8 and three encrypted files over an owned SDK relay.

The synthetic native device clock records each of the SIX remote voice paths
from actual mixed PCM. No microphone, speaker or user profile is opened. The
optional aggregate UDP FIFO is blind to payloads and traffic classes.
"""
import argparse
import collections
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time
import traceback

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from group_codec_sdk import GroupSdk, P, E
from native_pcm_driver import NativePcmDriver, build as build_clock
from group_pcm_timing import analyze_voice_path

os.umask(0o077)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sdk', required=True, type=Path)
parser.add_argument('--media', required=True, type=Path)
parser.add_argument('--directory', required=True, type=Path)
parser.add_argument('--duration', type=int, default=360)
parser.add_argument('--rate-kbps', type=int, default=1024)
args = parser.parse_args()
if args.duration < 30 or args.rate_kbps < 0:
    parser.error('Duration must be at least 30 seconds and rate nonnegative')
fixture = GroupSdk(args.sdk, args.directory, args.rate_kbps)
root = fixture.root
log = (root / 'runtime.log').open('w')
os.dup2(log.fileno(), 2)
os.environ['VEIL_MEDIA_TEST_VIDEO'] = '1'
os.environ.pop('VEIL_MEDIA_VIDEO_KBPS', None)
os.environ.pop('VEIL_MEDIA_TEST_DISABLE_AUDIO_DRAIN', None)
result = {'ok': False, 'participants': 3, 'remote_voice_paths': 6,
          'loopback_only': True, 'speech_listening_proof': False,
          'duration_seconds': args.duration, 'rate_kbps': args.rate_kbps,
          'file_bytes_per_sender': 524288,
          'sdk_sha256': hashlib.sha256(args.sdk.read_bytes()).hexdigest(),
          'media_sha256': hashlib.sha256(args.media.read_bytes()).hexdigest()}
engines, threads = [], []
driver = policy = media = None
samples, pcm, images = [], [], []
file_stop = threading.Event()
lock = threading.Lock()
payloads = [os.urandom(524288) for _ in range(3)]
keys = [AESGCM(os.urandom(32)) for _ in range(3)]
chunks = [{}, {}, {}]
file_state = [{}, {}, {}]
bad = [0, 0, 0]
duplicates = [0, 0, 0]
async_failures = [collections.Counter() for _ in range(3)]
file_started = [None, None, None]
origin = None


def command(value):
    policy.stdin.write(json.dumps(value) + '\n')
    policy.stdin.flush()
    line = policy.stdout.readline()
    if not line:
        raise RuntimeError('Group policy bridge exited')
    return json.loads(line)


def freeze_files():
    with lock:
        values = []
        for receiver in range(3):
            sender = (receiver - 1) % 3
            data = b''.join(chunks[receiver][i] for i in sorted(chunks[receiver]))
            values.append({**file_state[sender], 'sender': sender,
                           'receiver': receiver, 'received': len(data),
                           'missing_chunks': 256 - len(chunks[receiver]),
                           'hash_matches': len(chunks[receiver]) == 256 and
                           hashlib.sha256(data).digest() == hashlib.sha256(payloads[sender]).digest()})
        return {'files': values, 'authentication_errors': bad[:],
                'duplicates': duplicates[:],
                'async_failures': [dict(x) for x in async_failures]}


try:
    fixture.start()
    clock_library = build_clock(root)
    preload = C.CDLL(str(clock_library))
    media = C.CDLL(str(args.media.resolve()), mode=C.RTLD_GLOBAL)

    def mf(name, types, returns):
        function = getattr(media, name)
        function.argtypes, function.restype = types, returns
        return function

    create = mf('veil_media_test_group_codec_create', [P], P)
    destroy = mf('veil_media_group_engine_destroy', [P], None)
    add = mf('veil_media_group_engine_add_peer', [P, C.c_uint64, P], C.c_int)
    audio = mf('veil_media_group_engine_start_audio', [P], C.c_int)
    video = mf('veil_media_group_engine_start_video', [P], C.c_int)
    pause = mf('veil_media_group_engine_set_video_send_paused', [P, C.c_int], C.c_int)
    budget = mf('veil_media_group_engine_set_video_budget', [P, C.c_int, C.c_double], C.c_int)
    capture = mf('veil_media_test_group_capture_tone', [P, C.c_int], C.c_int)
    playout = mf('veil_media_test_group_playout_pcm', [P, P, C.c_size_t], C.c_int)
    stats = mf('veil_media_group_engine_get_stats', [P], P)
    free_string = mf('veil_media_free_string', [P], None)
    frame = mf('veil_media_group_engine_get_peer_video_frame',
               [P, P, P, C.c_int, P, P], C.c_int)
    source_report = fixture.fn('veil_app_report_local_source_pressure',
                               [P, C.c_uint8, C.c_uint64, E], C.c_int)
    for identity in fixture.ids:
        engine = create(identity)
        if not engine:
            raise RuntimeError('Group engine creation failed')
        engines.append(engine)
    for a in range(3):
        for z in range(3):
            if a != z and add(engines[a], fixture.channel_pairs[a, z], fixture.ids[z]) != 0:
                raise RuntimeError('Group peer setup refused')
    for engine in engines:
        if audio(engine) != 0:
            raise RuntimeError('Synthetic group audio did not start')

    handler_type = C.CFUNCTYPE(None, P, P, P, C.c_uint8, C.c_uint64, P, C.c_size_t)
    event_type = C.CFUNCTYPE(None, P, C.c_uint8, P, C.c_size_t)
    handler = fixture.fn('veil_app_set_recv_handler', [P, handler_type, P, E], C.c_int)
    events = fixture.fn('veil_set_event_handler', [P, event_type, P, E], C.c_int)
    free_buf = fixture.fn('veil_free_buf', [P, C.c_size_t], None)
    send_file = fixture.fn('veil_send_on_local_lane',
                           [P, P, P, C.c_uint32, P, C.c_size_t,
                            C.c_uint8, C.c_uint8, E], C.c_int)
    file_apps, file_ids = [], []
    for participant in range(3):
        handle, app, identity = fixture.bind_app(participant, 'file', 3)
        file_apps.append(app)
        file_ids.append(identity)

        def failure(user, kind, data, size, participant=participant):
            try:
                if kind == 4:
                    raw = C.string_at(data, size) if size else b''
                    code = str(int.from_bytes(raw, 'big')) if size == 2 else 'unknown'
                    with lock:
                        async_failures[participant][code] += 1
            finally:
                if size:
                    free_buf(data, size)
        callback = event_type(failure)
        fixture.callbacks.append(callback)
        if fixture.checked(events, handle, callback, None) != 0:
            raise RuntimeError('File event handler refused')
    for receiver in range(3):
        def receive(user, node, app, provenance, reply, data, size, receiver=receiver):
            try:
                sender = (receiver - 1) % 3
                if (C.string_at(node, 32) != fixture.ids[sender].raw[:32] or
                        C.string_at(app, 32) != file_ids[sender].raw[:32]):
                    raise ValueError('Foreign fixture sender')
                raw = C.string_at(data, size)
                index = int.from_bytes(raw[:12], 'big')
                if not 0 <= index < 256:
                    raise ValueError('Invalid file fragment')
                block = keys[sender].decrypt(raw[:12], raw[12:], b'group-codec-file-v1')
                if len(block) != 2048:
                    raise ValueError('Invalid fragment length')
                with lock:
                    if index in chunks[receiver]:
                        duplicates[receiver] += 1
                    chunks[receiver][index] = block
                    if len(chunks[receiver]) == 256:
                        file_state[sender]['completion_seconds'] = time.monotonic() - origin
            except Exception:
                with lock:
                    bad[receiver] += 1
            finally:
                free_buf(node, 64 + size)
        callback = handler_type(receive)
        fixture.callbacks.append(callback)
        if fixture.checked(handler, file_apps[receiver], callback, None) != 0:
            raise RuntimeError('File receive handler refused')

    def write_file(sender):
        target = (sender + 1) % 3
        began = time.monotonic()
        try:
            sent = 0
            for index in range(256):
                if file_stop.is_set():
                    break
                nonce = index.to_bytes(12, 'big')
                block = payloads[sender][index * 2048:(index + 1) * 2048]
                encoded = nonce + keys[sender].encrypt(nonce, block, b'group-codec-file-v1')
                if fixture.checked(send_file, file_apps[sender], fixture.ids[target],
                                   file_ids[target], 3, encoded, len(encoded), 4, 0) != 0:
                    raise RuntimeError('Reliable DATA enqueue refused')
                sent += 2048
            with lock:
                file_state[sender].update(queued=sent,
                    enqueue_ms=(time.monotonic() - began) * 1000)
        except Exception:
            with lock:
                file_state[sender]['write_error'] = True
            (root / f'file-{sender}-failure.txt').write_text(traceback.format_exc())

    scripts = Path(__file__).resolve().parent
    policy_error = (root / 'policy.err').open('w')
    policy = subprocess.Popen(['dart', '--packages=' + str(scripts.parent / '.dart_tool/package_config.json'),
                               str(scripts / 'group_codec_policy.dart')],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=policy_error, text=True, bufsize=1)
    peers = [[fixture.ids[z].raw[:32].hex() for z in range(3) if a != z]
             for a in range(3)]
    # Warm the Dart bridge before the timed native source starts.
    command({'index': 0, 'stats': {}, 'peers': peers[0],
             'now': int(time.time() * 1000)})
    buffers = {(a, z): C.create_string_buffer(320 * 240 * 4)
               for a in range(3) for z in range(3) if a != z}
    if fixture.shaper:
        fixture.shaper.rate_bps = args.rate_kbps * 1000
    origin = time.monotonic()
    driver = NativePcmDriver(clock_library, capture, playout, engines,
                             origin, 1010, priority='deadline', group=True)
    next_sample, started_video = origin, False
    while time.monotonic() < origin + args.duration:
        now = time.monotonic()
        pcm.extend(driver.drain())
        if now >= next_sample and now < origin + args.duration - .25:
            preparing = not started_video and now >= origin + 20
            latest = []
            for participant, engine in enumerate(engines):
                raw = stats(engine)
                if not raw:
                    raise RuntimeError('Group stats unavailable')
                try:
                    snapshot = json.loads(C.string_at(raw))
                finally:
                    free_string(raw)
                sampled_at = int(time.time() * 1000)
                decision = command({'index': participant, 'stats': snapshot,
                                    'peers': peers[participant], 'now': sampled_at,
                                    'video': started_video, 'prepare': preparing})
                if decision['sourcePressured'] is not None:
                    rc = fixture.checked(source_report, fixture.media_apps[participant],
                                         int(decision['sourcePressured']), sampled_at)
                    if rc != 0:
                        raise RuntimeError('Fresh source feedback was not queued')
                pause_ok = budget_ok = True
                if preparing and video(engine) != 0:
                    raise RuntimeError('Synthetic VP8 did not start')
                if preparing or started_video:
                    if decision['pause'] is not None:
                        pause_ok = pause(engine, int(decision['pause'])) == 0
                    if decision['budget'] is not None:
                        target = decision['budget']
                        budget_ok = budget(engine, target['kbps'], target['fps']) == 0
                    command({'index': participant, 'op': 'ack',
                             'pauseOk': pause_ok, 'budgetOk': budget_ok})
                latest.append({'t': time.monotonic() - origin, 'side': participant,
                               'stats': snapshot, 'policy': decision,
                               'pause_ok': pause_ok, 'budget_ok': budget_ok})
                if preparing or started_video:
                    for source in range(3):
                        if source == participant:
                            continue
                        width, height = C.c_int(), C.c_int()
                        output = buffers[participant, source]
                        size = frame(engine, fixture.ids[source], output, len(output),
                                     C.byref(width), C.byref(height))
                        if size > 0:
                            if size > len(output):
                                raise RuntimeError('Oversized decoded frame')
                            images.append({'t': time.monotonic() - origin,
                                           'receiver': participant, 'source': source,
                                           'width': width.value, 'height': height.value,
                                           'sha256': hashlib.sha256(output.raw[:size]).hexdigest()})
            samples.extend(latest)
            if preparing:
                started_video = True
                result['video_started_seconds'] = time.monotonic() - origin
                for sender in range(3):
                    thread = threading.Thread(target=write_file, args=(sender,), name='group-file')
                    threads.append(thread)
                    thread.start()
            next_sample += 1
        time.sleep(min(.02, max(0, origin + args.duration - time.monotonic())))
    result.update(freeze_files())  # Freeze BEFORE teardown/analysis can complete late files.
    result['file_snapshot_seconds'] = time.monotonic() - origin
    pcm.extend(driver.stop())
    result['clock'] = {key: getattr(driver.stats, key) for key, _ in driver.stats._fields_}
    result['clock']['failures'] = list(driver.stats.failures)
    result['pcm_rows'] = len(pcm)
    result['voice_paths'] = []
    pairs = [(a, z) for a in range(3) for z in range(3) if a != z]
    for receiver, source in pairs:
        observed = [r for r in pcm if r['side'] == receiver * 3 + source]
        timing = analyze_voice_path(observed, args.duration)
        result['voice_paths'].append({'receiver': receiver, 'source': source, **timing,
                                     'first_capture': observed[0]['source_at'] if observed else None,
                                     'last_capture': observed[-1]['source_at'] if observed else None})
    result['video_paths'] = []
    for receiver, source in pairs:
        rows = [x for x in images if x['receiver'] == receiver and x['source'] == source]
        tail = [x for x in rows if x['t'] >= args.duration - 15]
        changes = sum(a['sha256'] != z['sha256'] for a, z in zip(tail, tail[1:]))
        result['video_paths'].append({'receiver': receiver, 'source': source,
                                     'decoded_pulls': len(rows), 'tail_changes': changes})
    native = (root / 'runtime.log').read_text(errors='replace')
    hops = re.findall(r'ipc.rt_trace.relay_admission[^\n]*hop=([a-f0-9]+)[^\n]*datagram_transport=(true|false)', native)
    result['neutral_relay_route_verified'] = bool(hops) and all(
        hop == fixture.relay_id[:8] and ready == 'true' for hop, ready in hops)
    result['ok'] = (
        result['neutral_relay_route_verified'] and
        all(v['first_capture'] is not None and v['first_capture'] < .1 and
            v['last_capture'] >= args.duration - .1 for v in result['voice_paths']) and
        all(p['matched'] > 0 and p['missing'] == 0 and p['max_ms'] < 200
            for v in result['voice_paths'] for p in v['phases']) and
        all(v['tail_changes'] > 0 for v in result['video_paths']) and
        len(pcm) == driver.stats.ticks * 6 and driver.stats.dropped_rows == 0 and
        driver.stats.timer_error == 0 and driver.stats.max_interval_ms < 40 and
        driver.stats.deadline_active == 1 and driver.stats.deadline_misses == 0 and
        not any(driver.stats.failures) and
        all(f.get('queued') == 524288 and f['hash_matches'] for f in result['files']) and
        not any(result['authentication_errors'] + result['duplicates']) and
        not any(result['async_failures']))
except Exception:
    (root / 'failure.txt').write_text(traceback.format_exc())
    result['failure_saved_privately'] = True
finally:
    if driver and driver.handle:
        pcm.extend(driver.stop())
    file_stop.set()
    for thread in threads:
        thread.join(5)
    result['file_threads_exited'] = all(not t.is_alive() for t in threads)
    if policy:
        policy.stdin.close()
        try:
            policy.wait(5)
        except subprocess.TimeoutExpired:
            policy.kill()
            policy.wait()
        result['policy_exited'] = policy.poll() is not None
    if media:
        for engine in reversed(engines):
            destroy(engine)
    fixture.close()
    result['node_stop_results'] = fixture.stop_results
    result['remaining_sockets'] = len(list(root.glob('*/*.sock')))
    result['ok'] = result['ok'] and result['file_threads_exited'] and fixture.stop_results == [0, 0, 0, 0] and result['remaining_sockets'] == 0
    (root / 'pcm-samples.json').write_text(json.dumps(pcm))
    (root / 'codec-samples.json').write_text(json.dumps(samples))
    (root / 'decoded-video-samples.json').write_text(json.dumps(images))
    (root / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'ok': result['ok'], 'directory': str(root),
                      'failure_saved_privately': result.get('failure_saved_privately', False)}))
raise SystemExit(0 if result['ok'] else 1)
