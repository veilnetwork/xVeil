#!/usr/bin/env python3
"""Three real group participants in separate SDK processes, no physical ADM.

Each native clock records its actual capture submissions and two bands of
mixed decoded PCM. Only metadata is retained. The parent joins sender and
receiver observations after the immutable deadline. No voice is recorded.
This baseline deliberately has no video/file load; use it before qualification.
"""
import argparse
import ctypes as C
import hashlib
import json
import multiprocessing as mp
import os
from pathlib import Path
import re
import time
import traceback

from group_codec_sdk import GroupSdk, P, E
from group_pcm_timing import analyze_voice_path
from native_pcm_driver import NativePcmDriver, build as build_clock


def worker(pipe, sdk_path, media_path, root, clock, participant):
    os.umask(0o077)
    directory = Path(root) / ('worker-' + str(participant))
    directory.mkdir(mode=0o700)
    log = (directory / 'native.log').open('w')
    os.dup2(log.fileno(), 2)
    fixture = media = engine = driver = None
    rows, snapshots = [], []
    result = {'ok': False, 'pid': os.getpid(), 'participant': participant,
              'primary_receivers_in_process': 1}
    try:
        fixture = GroupSdk(sdk_path, root, attach=True)
        handle, app, app_id = fixture.bind_app(participant, 'media', 0)
        identity = C.create_string_buffer(32)
        if fixture.checked(fixture.node_id, handle, identity) != 0:
            raise RuntimeError('Participant identity unavailable')
        secondary = fixture.bind_app(participant, 'media', 1)[1]
        feedback = fixture.bind_app(participant, 'media', 5)[1]
        receive = fixture.fn('veil_media_start_direct_receiver',
                             [P, P, C.c_size_t, P, C.c_size_t, E], C.c_int)
        service, module = b'xveil-group-codec', b'media'
        if fixture.checked(receive, app, service, len(service), module, len(module)):
            raise RuntimeError('Media receiver refused')
        pipe.send({'ready': True, 'identity': identity.raw[:32],
                   'app': app_id.raw[:32]})
        setup = pipe.recv()
        peers = [C.create_string_buffer(x['identity']) for x in setup['participants']]
        apps = [C.create_string_buffer(x['app']) for x in setup['participants']]
        keys = setup['keys']
        set_secondary = fixture.fn('veil_media_channel_set_secondary_sender',
                                    [C.c_uint64, P, E], C.c_int)
        set_feedback = fixture.fn('veil_media_channel_set_feedback_sender',
                                   [C.c_uint64, P, E], C.c_int)
        batching = fixture.fn('veil_media_channel_set_batching',
                              [C.c_uint64, C.c_int], C.c_int)
        os.environ.pop('VEIL_MEDIA_TEST_DISABLE_AUDIO_DRAIN', None)
        media = C.CDLL(str(Path(media_path).resolve()), mode=C.RTLD_GLOBAL)

        def mf(name, args, result_type):
            f = getattr(media, name)
            f.argtypes, f.restype = args, result_type
            return f

        create = mf('veil_media_test_group_codec_create', [P], P)
        destroy = mf('veil_media_group_engine_destroy', [P], None)
        add = mf('veil_media_group_engine_add_peer', [P, C.c_uint64, P], C.c_int)
        audio = mf('veil_media_group_engine_start_audio', [P], C.c_int)
        capture = mf('veil_media_test_group_capture_tone', [P, C.c_int], C.c_int)
        playout = mf('veil_media_test_group_playout_pcm', [P, P, C.c_size_t], C.c_int)
        stats = mf('veil_media_group_engine_get_stats', [P], P)
        free_string = mf('veil_media_free_string', [P], None)
        engine = create(identity)
        if not engine:
            raise RuntimeError('Synthetic group engine creation failed')
        for peer in range(3):
            if peer == participant:
                continue
            tx = C.create_string_buffer(keys[participant, peer])
            rx = C.create_string_buffer(keys[peer, participant])
            channel = fixture.checked(fixture.channel_open, app, peers[peer],
                                      apps[peer], 0, tx, rx)
            if not channel:
                raise RuntimeError('Empty group media channel')
            fixture.channels.append(channel)
            if (fixture.checked(set_secondary, channel, secondary) or
                    fixture.checked(set_feedback, channel, feedback) or
                    batching(channel, 2) or add(engine, channel, peers[peer])):
                raise RuntimeError('Group channel setup failed')
        if audio(engine):
            raise RuntimeError('Synthetic group audio refused')
        # Resolve the clock library before the coordinated deadline. Waiting
        # and capture start happen on its native device thread, not Python.
        clock_library = C.CDLL(str(clock))
        pipe.send({'configured': True})
        run = pipe.recv()
        origin, duration = run['origin'], run['duration']
        driver = NativePcmDriver(clock, capture, playout, [engine], origin, 1010,
                                 priority='deadline', local_group=participant)
        next_stats = origin
        while time.monotonic() < origin + duration:
            rows.extend(driver.drain())
            if time.monotonic() >= next_stats:
                value = stats(engine)
                if not value:
                    raise RuntimeError('Missing group statistics')
                try:
                    snapshots.append({'t': time.monotonic() - origin,
                                      'stats': json.loads(C.string_at(value))})
                finally:
                    free_string(value)
                next_stats += 1
            time.sleep(min(.02, max(0, origin + duration - time.monotonic())))
        rows.extend(driver.stop())
        clock_stats = {k: getattr(driver.stats, k) for k, _ in driver.stats._fields_}
        clock_stats['failures'] = list(driver.stats.failures)
        result.update(clock=clock_stats, rows=len(rows),
                      first_capture=rows[0]['source_at'] if rows else None)
        result['ok'] = (len(rows) == driver.stats.ticks * 3 and
                        driver.stats.dropped_rows == 0 and not any(driver.stats.failures) and
                        driver.stats.timer_error == 0 and driver.stats.deadline_active == 1 and
                        driver.stats.deadline_misses == 0 and driver.stats.max_interval_ms < 40)
    except Exception:
        (directory / 'failure.txt').write_text(traceback.format_exc())
        result['failure_saved_privately'] = True
    finally:
        if driver and driver.handle:
            rows.extend(driver.stop())
        if engine:
            destroy(engine)
        if fixture:
            fixture.close()
        (directory / 'pcm-samples.json').write_text(json.dumps(rows))
        (directory / 'codec-samples.json').write_text(json.dumps(snapshots))
        (directory / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
        pipe.send({'finished': result['ok']})
        pipe.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--media', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--duration', type=int, default=40)
    parser.add_argument('--rate-kbps', type=int, default=0)
    args = parser.parse_args()
    if args.duration < 30 or args.rate_kbps < 0:
        parser.error('Duration must be at least 30 seconds and rate nonnegative')
    os.umask(0o077)
    fixture = GroupSdk(args.sdk, args.directory, args.rate_kbps, trace=True)
    root = fixture.root
    log = (root / 'native.log').open('w')
    os.dup2(log.fileno(), 2)
    children, pipes = [], []
    result = {'ok': False, 'participants': 3, 'separate_sdk_processes': True,
              'video_file_load': False, 'speech_listening_proof': False,
              'duration_seconds': args.duration, 'rate_kbps': args.rate_kbps,
              'sdk_sha256': hashlib.sha256(args.sdk.read_bytes()).hexdigest(),
              'media_sha256': hashlib.sha256(args.media.read_bytes()).hexdigest()}
    sources = ['group-process-preflight.py', 'group_codec_sdk.py',
               'native_pcm_driver.py', 'native_pcm_driver.cc',
               'group_pcm_timing.py', 'udp_fifo_shaper.py']
    result['fixture_sources'] = {}
    for name in sources:
        data = Path(__file__).with_name(name).read_bytes()
        (root / ('source-' + name)).write_bytes(data)
        result['fixture_sources'][name] = hashlib.sha256(data).hexdigest()

    def receive_all(timeout):
        values = []
        until = time.monotonic() + timeout
        for pipe in pipes:
            if not pipe.poll(max(0, until - time.monotonic())):
                raise RuntimeError('Participant response deadline exceeded')
            value = pipe.recv()
            if value.get('finished') is False:
                raise RuntimeError('Participant failed; private evidence retained')
            values.append(value)
        return values

    try:
        fixture.start(transport_only=True)
        clock = build_clock(root)
        context = mp.get_context('spawn')  # Never fork a running embedded node.
        for participant in range(3):
            parent, child = context.Pipe()
            process = context.Process(target=worker, args=(child, str(args.sdk),
                str(args.media), str(root), str(clock), participant))
            process.start()
            child.close()
            pipes.append(parent)
            children.append(process)
        participants = receive_all(40)
        if not all(v.get('ready') for v in participants):
            raise RuntimeError('Participant startup failed')
        keys = {(a, z): os.urandom(32) for a in range(3) for z in range(3) if a != z}
        for pipe in pipes:
            pipe.send({'participants': participants, 'keys': keys})
        if not all(v.get('configured') for v in receive_all(40)):
            raise RuntimeError('Participant configuration failed')
        origin = time.monotonic() + 2
        if fixture.shaper:
            fixture.shaper.rate_bps = args.rate_kbps * 1000
        for pipe in pipes:
            pipe.send({'origin': origin, 'duration': args.duration})
        receive_all(args.duration + 20)
        result['voice_paths'] = []
        all_rows = [json.loads((root / f'worker-{i}/pcm-samples.json').read_text())
                    for i in range(3)]
        result['workers'] = [json.loads((root / f'worker-{i}/summary.json').read_text())
                             for i in range(3)]
        for receiver in range(3):
            for source in range(3):
                if source == receiver:
                    continue
                captures = [r for r in all_rows[source] if r['side'] == source * 4]
                decoded = [r for r in all_rows[receiver] if r['side'] == receiver * 3 + source]
                timing = analyze_voice_path(decoded, args.duration, captures)
                for phase in timing['phases']:
                    phase['phase'] = ('audio-only-initial' if phase['phase'] == 'audio-only'
                                      else 'audio-only-steady')
                result['voice_paths'].append({'receiver': receiver, 'source': source, **timing,
                                              'first_capture': captures[0]['source_at'],
                                              'last_capture': captures[-1]['source_at']})
        result['ok'] = (all(w['ok'] for w in result['workers']) and
                         len({w['pid'] for w in result['workers']}) == 3 and
                         all(v['first_capture'] < .1 and v['last_capture'] >= args.duration - .1
                             and all(p['matched'] > 0 and p['missing'] == 0 and p['max_ms'] < 200
                                     for p in v['phases']) for v in result['voice_paths']))
        hops = re.findall(r'ipc.rt_trace.relay_admission[^\n]*hop=([a-f0-9]+)'
                          r'[^\n]*datagram_transport=(true|false)',
                          (root / 'native.log').read_text(errors='replace'))
        result['neutral_relay_route_verified'] = bool(hops) and all(
            hop == fixture.relay_id[:8] and ready == 'true' for hop, ready in hops)
        result['ok'] &= result['neutral_relay_route_verified']
    except Exception:
        (root / 'failure.txt').write_text(traceback.format_exc())
        result['failure_saved_privately'] = True
    finally:
        for process in children:
            process.join(5)
            if process.is_alive():
                process.terminate()
                process.join(5)
        result['worker_exit_codes'] = [p.exitcode for p in children]
        result['workers_exited'] = all(not p.is_alive() for p in children)
        for pipe in pipes:
            pipe.close()
        fixture.close()
        if fixture.shaper:
            result['shaper'] = {'stats': fixture.shaper.stats,
                               'failure': fixture.shaper.failure,
                               'trace_events': fixture.shaper.trace_events,
                               'trace_rows': len(fixture.shaper.trace_rows)}
            (root / 'wire-samples.json').write_text(json.dumps(list(fixture.shaper.trace_rows)))
        result['node_stop_results'] = fixture.stop_results
        result['remaining_sockets'] = len(list(root.glob('*/*.sock')))
        result['ok'] = (result['ok'] and result['worker_exit_codes'] == [0, 0, 0] and
                         result['workers_exited'] and fixture.stop_results == [0, 0, 0, 0] and
                         result['remaining_sockets'] == 0)
        if fixture.shaper:
            result['ok'] &= fixture.shaper.failure is None
        (root / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({'ok': result['ok'], 'directory': str(root)}))
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
