#!/usr/bin/env python3
"""Three real group participants in separate SDK processes, no physical ADM.

Each native clock records its actual capture submissions and two bands of
mixed decoded PCM. Only metadata is retained. The parent joins sender and
receiver observations after the immutable deadline. No voice is recorded.
The optional full load adds VP8 and three authenticated encrypted 512-KiB files.
"""
import argparse
import ctypes as C
import hashlib
import json
import multiprocessing as mp
import os
from pathlib import Path
import re
import selectors
import subprocess
import time
import traceback

from group_codec_sdk import (GroupSdk, P, E, SourcePacketSamples,
                             receive_participant_values)
from group_pcm_timing import analyze_voice_path
from native_pcm_driver import NativePcmDriver, build as build_clock
from group_process_files import ProcessFileLoad
from decoded_video_progress import (required_tail_content_changes,
                                    decoded_counter_rate, frame_witness)


def qualifies_full_contention(result):
    """Require a completed capture, including post-measurement proofs."""
    return bool(result.get('ok') is True and
                not result.get('failure_saved_privately') and
                result.get('duration_seconds', 0) >= 360 and
                result.get('load_kind') == 'both' and
                result.get('video_file_load') is True and
                result.get('end_topology', {}).get('verified') is True and
                len(result.get('files', [])) == 3 and
                len(result.get('video_paths', [])) == 6 and
                all(path.get('frame_witness') == 'full-rgba-native-sequence-v1' and
                    path.get('tail_changes', -1) >= required_tail_content_changes(
                        result['duration_seconds'])
                    for path in result['video_paths']))


def worker(pipe, sdk_path, media_path, root, clock, participant,
           full_load=False, load_kind='both', playout_trace=False,
           source_framing_trace=False):
    os.umask(0o077)
    directory = Path(root) / ('worker-' + str(participant))
    directory.mkdir(mode=0o700)
    if playout_trace:
        os.environ['VEIL_MEDIA_PLAYOUT_TRACE'] = '1'
        os.environ['VEIL_MEDIA_DIAG_PATH'] = str(directory / 'playout-trace.log')
    log = (directory / 'native.log').open('w')
    os.dup2(log.fileno(), 2)
    fixture = media = engine = driver = policy = files = None
    policy_log = None
    rows, snapshots, images = [], [], []
    video_started = False
    source_feedback_queued = 0
    source_sizes = SourcePacketSamples()
    source_cost_sequence = 0
    source_cost_pending = None
    source_cost_latest = None
    source_cost_responses = 0
    use_video, use_files = full_load and load_kind != 'files', full_load and load_kind != 'video'
    result = {'ok': False, 'pid': os.getpid(), 'participant': participant,
              'primary_receivers_in_process': 1,
              'test_ptime_requested': os.environ.get('VEIL_MEDIA_TEST_GROUP_PTIME')}
    try:
        fixture = GroupSdk(sdk_path, root, attach=True)
        if playout_trace:
            fixture.enable_client_trace()
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
        if use_files:
            files = ProcessFileLoad(fixture, participant, directory)
        pipe.send({'ready': True, 'identity': identity.raw[:32],
                   'app': app_id.raw[:32],
                   'file_app': files.app_id.raw[:32] if files else None})
        setup = pipe.recv()
        budget_smoke = setup.get('budget_smoke', False)
        adaptive = setup.get('adaptive', False)
        peers = [C.create_string_buffer(x['identity']) for x in setup['participants']]
        apps = [C.create_string_buffer(x['app']) for x in setup['participants']]
        keys = setup['keys']
        if files:
            file_keys = setup['file_keys']
            files.configure(setup['participants'], setup['file_payload'],
                            file_keys[participant], file_keys[(participant - 1) % 3],
                            setup['file_hashes'][(participant - 1) % 3])
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
        if full_load:
            os.environ['VEIL_MEDIA_TEST_VIDEO'] = '1'
            os.environ.pop('VEIL_MEDIA_VIDEO_KBPS', None)
            start_video = mf('veil_media_group_engine_start_video', [P], C.c_int)
            pause_video = mf('veil_media_group_engine_set_video_send_paused', [P, C.c_int], C.c_int)
            video_budget = mf('veil_media_group_engine_set_video_budget', [P, C.c_int, C.c_double], C.c_int)
            frame = mf('veil_media_group_engine_get_peer_video_frame', [P, P, P, C.c_int, P, P], C.c_int)
            source_report = fixture.fn('veil_app_report_local_source_pressure',
                                       [P, C.c_uint8, C.c_uint64, E], C.c_int)
            frame_buffers = {peer: C.create_string_buffer(320 * 240 * 4)
                             for peer in range(3) if peer != participant}
        set_audio = (mf('veil_media_group_engine_set_audio_budget', [P, C.c_int, C.c_int], C.c_int)
                     if budget_smoke or adaptive else None)
        try:
            send_stats = mf('veil_media_test_group_audio_send_stats', [P], P)
        except AttributeError:
            send_stats = None
        if result['test_ptime_requested'] is not None and send_stats is None:
            raise RuntimeError('Packet-duration experiment requires its instrumented test engine')
        engine = create(identity)
        if not engine:
            raise RuntimeError('Synthetic group engine creation failed')
        if adaptive:
            if result['test_ptime_requested'] is not None or budget_smoke:
                raise RuntimeError('Adaptive policy cannot use a fixed experiment override')
            policy_log = (directory / 'policy.log').open('w')
            policy = subprocess.Popen([setup['policy']], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=policy_log,
                                      text=True, bufsize=1)
            result['policy_pid'] = policy.pid
            result['budget_events'] = []

            def policy_read():
                with selectors.DefaultSelector() as selector:
                    selector.register(policy.stdout, selectors.EVENT_READ)
                    if not selector.select(2):
                        raise RuntimeError('Production policy response timed out')
                line = policy.stdout.readline()
                if not line:
                    raise RuntimeError('Production policy exited early')
                return json.loads(line)

            if policy_read() != {'ready': True}:
                raise RuntimeError('Production policy startup failed')

            def adapt(op, elapsed, snapshot=None):
                request = {'op': op, 'now': int(elapsed * 1000), 'expectedPeers': 2}
                request['sourceFeedbackQueued'] = source_feedback_queued > 0
                if snapshot is not None:
                    request['stats'] = snapshot
                if full_load:
                    request.update(load=True, peers=[p['identity'].hex() for i, p in
                        enumerate(setup['participants']) if i != participant],
                        video=video_started, prepare=use_video and not video_started and elapsed >= 20)
                policy.stdin.write(json.dumps(request) + '\n')
                policy.stdin.flush()
                answer = policy_read()
                if answer['pending']:
                    rc = set_audio(engine, answer['packet_ms'], answer['payload_bps'])
                    result['budget_events'].append({'t': elapsed,
                        **{k: answer[k] for k in ['level', 'packet_ms', 'payload_bps']}, 'rc': rc})
                    policy.stdin.write(json.dumps({'op': 'ack', 'now': request['now'], 'ok': rc == 0}) + '\n')
                    policy.stdin.flush()
                    policy_read()
                    if op == 'prepare' and rc != 0:
                        raise RuntimeError('Initial adaptive audio configuration refused')
                return answer

            adapt('prepare', 0)
        if budget_smoke:
            result['budget_events'] = []
            if result['test_ptime_requested'] is not None:
                raise RuntimeError('A codec switch cannot override the live API regression')
            for packet_ms, bps in [(0, 32000), (30, 32000), (40, 15999), (40, 32001)]:
                if set_audio(engine, packet_ms, bps) == 0:
                    raise RuntimeError('Invalid audio budget was accepted')
            if set_audio(engine, 40, 32000) != 0:
                raise RuntimeError('Initial group audio budget refused')
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
            fixture.channel_pairs[participant, peer] = channel
            if (fixture.checked(set_secondary, channel, secondary) or
                    fixture.checked(set_feedback, channel, feedback) or
                    batching(channel, 2) or add(engine, channel, peers[peer])):
                raise RuntimeError('Group channel setup failed')
        if audio(engine):
            raise RuntimeError('Synthetic group audio refused')
        if budget_smoke:
            callback_type = C.CFUNCTYPE(C.c_int, P)
            held_audio = mf('veil_media_test_group_with_held_audio', [P, callback_type, P], C.c_int)
            held_video = mf('veil_media_test_group_with_held_video', [P, callback_type, P], C.c_int)
            answers = []

            @callback_type
            def retune(_):
                began = time.monotonic()
                answers.append((set_audio(engine, 20, 32000), time.monotonic() - began))
                return 0

            if held_audio(engine, retune, None) != 0 or answers[-1][0] == 0:
                raise RuntimeError('Busy audio worker falsely acknowledged a retune')
            # Queued abandoned work must not mutate the original budget later.
            raw = stats(engine)
            try:
                before = json.loads(C.string_at(raw))
            finally:
                free_string(raw)
            if before['audio_requested_packet_ms'] != 40:
                raise RuntimeError('Abandoned retune changed the codec later')
            os.environ['VEIL_MEDIA_TEST_VIDEO'] = '1'
            start_video = mf('veil_media_group_engine_start_video', [P], C.c_int)
            stop_video = mf('veil_media_group_engine_stop_video', [P], C.c_int)
            if start_video(engine) != 0 or held_video(engine, retune, None) != 0:
                raise RuntimeError('Held-video codec regression could not run')
            if answers[-1][0] != 0:
                raise RuntimeError('Video queues blocked the audio retune')
            if stop_video(engine) != 0 or set_audio(engine, 40, 32000) != 0:
                raise RuntimeError('Group control smoke teardown failed')
            result['held_audio_rejected_seconds'] = answers[0][1]
            result['held_video_retune_seconds'] = answers[1][1]
        # Resolve the clock library before the coordinated deadline. Waiting
        # and capture start happen on its native device thread, not Python.
        clock_library = C.CDLL(str(clock))
        pipe.send({'configured': True})
        run = pipe.recv()
        origin, duration = run['origin'], run['duration']
        result['origin_monotonic'] = origin
        result['origin_unix_ms'] = run['origin_unix_ms']
        if files:
            files.arm(origin, origin + duration)
        driver = NativePcmDriver(clock, capture, playout, [engine], origin, 1010,
                                 priority='deadline', local_group=participant)
        next_stats = origin
        schedule = iter([(10, 20, 32000), (20, 40, 24000),
                         (30, 40, 16000), (40, 40, 32000), (50, 20, 32000)])
        change = next(schedule, None) if budget_smoke else None
        while time.monotonic() < origin + duration:
            rows.extend(driver.drain())
            if time.monotonic() >= next_stats:
                sampled_at_unix_ms = int(time.time() * 1000)
                value = stats(engine)
                if not value:
                    raise RuntimeError('Missing group statistics')
                try:
                    snapshot = {'t': time.monotonic() - origin,
                                'sampled_at_unix_ms': sampled_at_unix_ms,
                                'stats': json.loads(C.string_at(value))}
                finally:
                    free_string(value)
                if send_stats:
                    value = send_stats(engine)
                    if not value:
                        raise RuntimeError('Synthetic sender statistics unavailable')
                    try:
                        snapshot['sender'] = json.loads(C.string_at(value))
                    finally:
                        free_string(value)
                snapshots.append(snapshot)
                if source_framing_trace:
                    if pipe.poll():
                        response = pipe.recv()
                        if (not isinstance(response, dict) or
                                response.get('sequence') != source_cost_pending or
                                'source_cost_response' not in response):
                            raise RuntimeError('Unexpected source cost response')
                        source_cost_pending = None
                        source_cost_latest = response
                        source_cost_responses += 1
                    snapshot['source_cost_snapshot'] = source_cost_latest
                    snapshot['source_cost_sample_age_ms'] = (
                        max(0, (time.monotonic() - source_cost_latest['sampled_monotonic']) * 1000)
                        if source_cost_latest else None)
                    sizes = source_sizes.observe(snapshot['stats'])
                    snapshot['source_cost_observed_packet_bytes'] = dict(
                        source_sizes.observed_packet_bytes)
                    snapshot['source_cost_packet_sample_basis'] = dict(source_sizes.basis)
                    if source_cost_pending is None:
                        pipe.send({'source_cost_request': {
                            'sequence': source_cost_sequence, 'packet_bytes': sizes}})
                        source_cost_pending = source_cost_sequence
                        source_cost_sequence += 1
                if adaptive:
                    decision = adapt('poll', snapshot['t'], snapshot['stats'])
                    snapshot['audio_policy'] = decision
                    if full_load:
                        video_policy = decision['video_policy']
                        if video_policy['sourcePressured'] is not None:
                            snapshot['source_report_rc'] = fixture.checked(source_report, app,
                                int(video_policy['sourcePressured']), sampled_at_unix_ms)
                            if snapshot['source_report_rc'] != 0:
                                raise RuntimeError('Local source-pressure report refused')
                            source_feedback_queued += 1
                        snapshot['source_feedback_queued'] = source_feedback_queued
                        preparing = use_video and not video_started and snapshot['t'] >= 20
                        if files and files.thread is None and snapshot['t'] >= 20:
                            files.start()
                        if preparing:
                            cold_budget_ok = False
                            if video_policy['budget'] is not None:
                                target = video_policy['budget']
                                cold_budget_ok = video_budget(engine, target['kbps'], target['fps']) == 0
                            snapshot['video_cold_budget_ok'] = cold_budget_ok
                            # Match the controller: mount the native conservative
                            # sender while paused, using a prepared budget where supported.
                            if pause_video(engine, 1) != 0 or start_video(engine) != 0:
                                raise RuntimeError('Conservative synthetic VP8 start refused')
                            video_started = True
                            result['video_started_seconds'] = time.monotonic() - origin
                        if video_started:
                            budget_ok = pause_ok = True
                            if video_policy['budget'] is not None:
                                target = video_policy['budget']
                                budget_ok = video_budget(engine, target['kbps'], target['fps']) == 0
                            if not budget_ok:
                                pause_video(engine, 1)
                                pause_ok = False
                            elif video_policy['pause'] is not None:
                                pause_ok = pause_video(engine, int(video_policy['pause'])) == 0
                            policy.stdin.write(json.dumps({'op': 'videoAck', 'now': int(snapshot['t'] * 1000),
                                'budgetOk': budget_ok, 'pauseOk': pause_ok}) + '\n')
                            policy.stdin.flush()
                            policy_read()
                            snapshot.update(video_budget_ok=budget_ok, video_pause_ok=pause_ok)
                            for peer, output in frame_buffers.items():
                                width, height = C.c_int(), C.c_int()
                                sequence = frame(engine, peers[peer], output, len(output),
                                             C.byref(width), C.byref(height))
                                if sequence < 0:
                                    raise RuntimeError('Oversized decoded frame')
                                if sequence > 0:
                                    images.append({'t': time.monotonic() - origin,
                                        'receiver': participant, 'source': peer,
                                        **frame_witness(sequence, width.value,
                                                        height.value, output.raw)})
                if change and snapshot['t'] >= change[0]:
                    rc = set_audio(engine, change[1], change[2])
                    result['budget_events'].append({'t': snapshot['t'], 'packet_ms': change[1],
                                                     'payload_bps': change[2], 'rc': rc})
                    if rc != 0:
                        raise RuntimeError('Live audio budget was not applied')
                    change = next(schedule, None)
                next_stats += 1
            time.sleep(min(.02, max(0, origin + duration - time.monotonic())))
        if files:
            result['file_snapshot'] = files.freeze()
            result['file_snapshot_seconds'] = time.monotonic() - origin
        rows.extend(driver.stop())
        clock_stats = {k: getattr(driver.stats, k) for k, _ in driver.stats._fields_}
        clock_stats['failures'] = list(driver.stats.failures)
        result.update(clock=clock_stats, rows=len(rows),
                      first_capture=rows[0]['source_at'] if rows else None)
        result['ok'] = (len(rows) == driver.stats.ticks * 3 and
                        driver.stats.dropped_rows == 0 and not any(driver.stats.failures) and
                        driver.stats.timer_error == 0 and driver.stats.deadline_active == 1 and
                        driver.stats.deadline_misses == 0 and driver.stats.max_interval_ms < 40)
        if files:
            frozen = result['file_snapshot']
            result['ok'] &= (frozen['queued'] == files.size and frozen['hash_matches'] and
                             not frozen['authentication_errors'] and not frozen['duplicates'] and
                             not frozen['async_failures'] and not frozen['write_error'])
        if use_video:
            result['video_paths'] = []
            for peer in frame_buffers:
                observed = [x for x in images if x['source'] == peer]
                tail = [x for x in observed if x['t'] >= duration - 15]
                changes = sum(a['sha256'] != b['sha256'] for a, b in zip(tail, tail[1:]))
                path = {'receiver': participant, 'source': peer,
                        'frame_witness': 'full-rgba-native-sequence-v1',
                        'decoded_pulls': len(observed), 'tail_changes': changes,
                        'decoded_counter': decoded_counter_rate(observed),
                        'last_minute_decoded_counter': decoded_counter_rate(
                            [x for x in observed if x['t'] >= duration - 60]),
                        'last_dimensions': [observed[-1]['width'], observed[-1]['height']]
                            if observed else None,
                        'screen_presentation_proof': False,
                        'required_tail_content_changes': required_tail_content_changes(duration)}
                result['video_paths'].append(path)
                result['ok'] &= changes >= path['required_tail_content_changes']
        if budget_smoke:
            active = [x['sender'] for x in snapshots if x['t'] > 2 and x.get('sender', {}).get('packets', 0) > 0]
            result['rtp_origin_preserved'] = bool(active) and len({x['rtp_origin'] for x in active}) == 1
            result['rtp_sequence_continuous'] = bool(active) and all(
                0 < (b['rtp_sequence'] - a['rtp_sequence']) % 65536 < 1000
                for a, b in zip(active, active[1:]))
            result['rtp_timestamps_continuous'] = bool(active) and all(
                0 < (b['rtp_timestamp'] - a['rtp_timestamp']) % (2**32) < 96000
                for a, b in zip(active, active[1:]))
            result['observed_durations'] = sorted({x['stats']['audio_tx_packet_duration_ms'] for x in snapshots if x['t'] > 2})
            result['observed_targets'] = sorted({x['stats']['audio_tx_target_bps'] for x in snapshots if x['t'] > 2})
            result['ok'] &= (result['rtp_origin_preserved'] and result['rtp_sequence_continuous'] and
                             result['rtp_timestamps_continuous'] and result['observed_durations'] == [20, 40]
                             and result['observed_targets'] == [16000, 24000, 32000] and
                             len(result['budget_events']) == 5)
    except Exception:
        (directory / 'failure.txt').write_text(traceback.format_exc())
        result['failure_saved_privately'] = True
    finally:
        if driver and driver.handle:
            rows.extend(driver.stop())
        if files:
            result['file_thread_exited'] = files.stop()
            result['ok'] &= result['file_thread_exited']
        if engine:
            destroy(engine)
        if fixture:
            try:
                result['channel_stats_after_capture'] = fixture.channel_snapshots_after_capture()
            except Exception:
                result['channel_stats_unavailable'] = True
                result['ok'] = False
            fixture.close()
            result['console_log_after_stop'] = fixture.console_log_status()
            if result['console_log_after_stop']['supported']:
                result['ok'] &= result['console_log_after_stop']['ok']
            if playout_trace:
                # Read only after the console barrier. Never feed diagnostic
                # timing, PCM edges or missing logs into the production policy.
                lines = (directory / 'native.log').read_text().splitlines()
                sends = sum('media.cell.sample ' in line and 'stage=relay_send ' in line
                            for line in lines)
                receives = sum('media.cell.sample ' in line and 'stage=received ' in line
                               for line in lines)
                result['source_trace_logging'] = {
                    'relay_send_samples': sends, 'receive_samples': receives,
                    'ok': sends > 0 and receives > 0}
                result['ok'] &= result['source_trace_logging']['ok']
        if policy:
            policy.stdin.close()
            try:
                policy.wait(3)
            except subprocess.TimeoutExpired:
                policy.terminate()
                policy.wait(3)
            result['policy_exit_code'] = policy.returncode
            result['ok'] &= policy.returncode == 0
        if policy_log:
            policy_log.close()
        (directory / 'pcm-samples.json').write_text(json.dumps(rows))
        if source_framing_trace:
            result['source_cost_trace'] = {'requests': source_cost_sequence,
                                           'responses_sampled': source_cost_responses,
                                           'fed_into_policy': False}
            result['ok'] &= source_cost_responses > 0
        (directory / 'codec-samples.json').write_text(json.dumps(snapshots))
        if full_load:
            (directory / 'decoded-video-samples.json').write_text(json.dumps(images))
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
    parser.add_argument('--wire-trace-capacity', type=int, default=100000,
                        help='bounded FIFO timing metadata rows; never changes pacing or limits')
    parser.add_argument('--budget-smoke', action='store_true')
    parser.add_argument('--adaptive', action='store_true')
    parser.add_argument('--full-load', action='store_true')
    parser.add_argument('--playout-trace', action='store_true',
                        help='bounded native timing metadata in each owned worker directory')
    parser.add_argument('--opaque-forward-trace', action='store_true',
                        help='hash owned opaque Forward payloads for authenticated hop joins; requires --playout-trace')
    parser.add_argument('--source-framing-trace', action='store_true',
                        help='sample prepared source costs on owned parent nodes; metadata only, not policy input')
    parser.add_argument('--load-kind', choices=['both', 'files', 'video'], default='both',
                        help='isolate a competitor; only both can qualify full contention')
    args = parser.parse_args()
    if args.duration < 30 or args.rate_kbps < 0:
        parser.error('Duration must be at least 30 seconds and rate nonnegative')
    if not 1 <= args.wire_trace_capacity <= 1000000:
        parser.error('Wire trace capacity must be in 1..1000000')
    if args.budget_smoke and args.duration < 60:
        parser.error('The live audio-budget regression requires at least 60 seconds')
    if args.adaptive and (args.budget_smoke or os.environ.get('VEIL_MEDIA_TEST_GROUP_PTIME')):
        parser.error('Adaptive mode cannot use a fixed packet-duration override')
    if args.full_load and (not args.adaptive or args.duration < 60):
        parser.error('Full load requires the production adaptive policy and at least 60 seconds')
    if not args.full_load and args.load_kind != 'both':
        parser.error('Load isolation requires --full-load')
    if args.opaque_forward_trace and not args.playout_trace:
        parser.error('Opaque forwarding attribution requires --playout-trace')
    if args.opaque_forward_trace:
        # Set before loading any SDK: its opt-in gate is cached per process,
        # and spawned clients must inherit it before their first sealed cell.
        os.environ['VEIL_DIAG_OPAQUE_FORWARD'] = '1'
    os.umask(0o077)
    fixture = GroupSdk(args.sdk, args.directory, args.rate_kbps, trace=True,
                       trace_capacity=args.wire_trace_capacity)
    root = fixture.root
    log = (root / 'native.log').open('w')
    os.dup2(log.fileno(), 2)
    children, pipes = [], []
    result = {'ok': False, 'participants': 3, 'separate_sdk_processes': True,
              'video_file_load': args.full_load and args.load_kind == 'both',
              'speech_listening_proof': False,
              'load_kind': args.load_kind if args.full_load else None,
              'duration_seconds': args.duration, 'rate_kbps': args.rate_kbps,
              'budget_smoke': args.budget_smoke,
              'adaptive': args.adaptive,
              'playout_trace': args.playout_trace,
              'opaque_forward_trace': os.environ.get('VEIL_DIAG_OPAQUE_FORWARD') == '1',
              'source_framing_trace': args.source_framing_trace,
              'test_ptime_requested': os.environ.get('VEIL_MEDIA_TEST_GROUP_PTIME'),
              'sdk_sha256': hashlib.sha256(args.sdk.read_bytes()).hexdigest(),
              'media_sha256': hashlib.sha256(args.media.read_bytes()).hexdigest()}
    sources = ['group-process-preflight.py', 'group_codec_sdk.py',
               'native_pcm_driver.py', 'native_pcm_driver.cc',
               'group_pcm_timing.py', 'udp_fifo_shaper.py', 'group_process_files.py',
               'decoded_video_progress.py']
    result['fixture_sources'] = {}
    for name in sources:
        data = Path(__file__).with_name(name).read_bytes()
        (root / ('source-' + name)).write_bytes(data)
        result['fixture_sources'][name] = hashlib.sha256(data).hexdigest()
    policy_executable = root / 'group-audio-policy'
    if args.adaptive:
        repository = Path(__file__).resolve().parent.parent
        policy_sources = ['scripts/group_audio_policy.dart',
                          'scripts/group_codec_policy.dart',
                          'lib/state/call_audio_source_pressure.dart',
                          'lib/state/group_call_audio_adapter.dart',
                          'lib/state/group_call_source_priority.dart',
                          'lib/state/call_audio_buffer_window.dart',
                          'lib/state/call_audio_transient_loss.dart',
                          'lib/state/call_audio_soft_loss.dart',
                          'lib/state/call_bitrate_adapter.dart',
                          'lib/state/call_audio_receive_activity.dart',
                          'lib/state/call_rtcp_loss.dart']
        for name in policy_sources:
            data = (repository / name).read_bytes()
            (root / ('source-' + name.replace('/', '-'))).write_bytes(data)
            result['fixture_sources'][name] = hashlib.sha256(data).hexdigest()
        with (root / 'policy-build.log').open('w') as build_log:
            subprocess.run(['dart', 'compile', 'exe', str(repository / 'scripts/group_audio_policy.dart'),
                            '-o', str(policy_executable)], cwd=repository, stdout=build_log,
                           stderr=subprocess.STDOUT, check=True)

    def receive_all(timeout):
        def source_cost(participant, request):
            return {str(peer): {lane: fixture.source_packet_cost(
                        participant, peer, int(lane), size)
                    for lane, size in request['packet_bytes'].items()}
                    for peer in range(3) if peer != participant}
        return receive_participant_values(
            pipes, timeout, source_cost if args.source_framing_trace else None)

    try:
        fixture.start(transport_only=True)
        clock = build_clock(root)
        context = mp.get_context('spawn')  # Never fork a running embedded node.
        for participant in range(3):
            parent, child = context.Pipe()
            process = context.Process(target=worker, args=(child, str(args.sdk),
                str(args.media), str(root), str(clock), participant,
                args.full_load, args.load_kind, args.playout_trace,
                args.source_framing_trace))
            process.start()
            child.close()
            pipes.append(parent)
            children.append(process)
        participants = receive_all(40)
        if not all(v.get('ready') for v in participants):
            raise RuntimeError('Participant startup failed')
        keys = {(a, z): os.urandom(32) for a in range(3) for z in range(3) if a != z}
        payloads = [os.urandom(ProcessFileLoad.size) for _ in range(3)] if args.full_load and args.load_kind != 'video' else []
        file_keys = [os.urandom(32) for _ in range(3)] if payloads else []
        file_hashes = [hashlib.sha256(x).hexdigest() for x in payloads]
        for i, pipe in enumerate(pipes):
            setup = {'participants': participants, 'keys': keys, 'budget_smoke': args.budget_smoke,
                     'adaptive': args.adaptive, 'policy': str(policy_executable)}
            if payloads:
                setup.update(file_payload=payloads[i], file_keys=file_keys, file_hashes=file_hashes)
            pipe.send(setup)
        if not all(v.get('configured') for v in receive_all(40)):
            raise RuntimeError('Participant configuration failed')
        origin = time.monotonic() + 2
        result['origin_monotonic'] = origin
        result['origin_unix_ms'] = int((time.time() + origin - time.monotonic()) * 1000)
        # Observers can align optional external diagnostics without polling
        # codec/IPC paths or moving the capture origin/deadline.
        (root / 'capture-origin.json').write_text(json.dumps({
            'monotonic': origin, 'unix_ms': result['origin_unix_ms'],
            'parent_pid': os.getpid(), 'worker_pids': [p.pid for p in children],
        }) + '\n')
        if fixture.shaper:
            fixture.shaper.rate_bps = args.rate_kbps * 1000
        for pipe in pipes:
            pipe.send({'origin': origin, 'origin_unix_ms': result['origin_unix_ms'],
                       'duration': args.duration})
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
                if not args.full_load:
                    for phase in timing['phases']:
                        phase['phase'] = ('audio-only-initial' if phase['phase'] == 'audio-only'
                                          else 'audio-only-steady')
                elif args.load_kind != 'both':
                    for phase in timing['phases']:
                        if phase['phase'] == 'audio-video-file':
                            phase['phase'] = 'audio-' + args.load_kind
                result['voice_paths'].append({'receiver': receiver, 'source': source, **timing,
                                              'first_capture': captures[0]['source_at'],
                                              'last_capture': captures[-1]['source_at']})
        result['ok'] = (all(w['ok'] for w in result['workers']) and
                         len({w['pid'] for w in result['workers']}) == 3 and
                         all(v['first_capture'] < .1 and v['last_capture'] >= args.duration - .1
                             and all(p['matched'] > 0 and p['missing'] == 0 and p['max_ms'] < 200
                                     for p in v['phases']) for v in result['voice_paths']))
        result['console_log_before_read'] = fixture.console_log_status()
        if result['console_log_before_read']['supported']:
            result['ok'] &= result['console_log_before_read']['ok']
        hops = re.findall(r'ipc.rt_trace.relay_admission[^\n]*hop=([a-f0-9]+)'
                          r'[^\n]*datagram_transport=(true|false)',
                          (root / 'native.log').read_text(errors='replace'))
        result['neutral_relay_route_verified'] = bool(hops) and all(
            hop == fixture.relay_id[:8] and ready == 'true' for hop, ready in hops)
        result['ok'] &= result['neutral_relay_route_verified']
        result['end_topology'] = fixture.verify_topology()
        result['ok'] &= result['end_topology']['verified']
        if args.full_load:
            result['files'] = [{'sender': (i - 1) % 3, 'receiver': i,
                **worker['file_snapshot'],
                'queued': result['workers'][(i - 1) % 3]['file_snapshot']['queued'],
                'async_failures': result['workers'][(i - 1) % 3]['file_snapshot']['async_failures'],
                'write_error': result['workers'][(i - 1) % 3]['file_snapshot']['write_error']}
                for i, worker in enumerate(result['workers']) if 'file_snapshot' in worker]
            result['video_paths'] = [path for worker in result['workers'] for path in worker.get('video_paths', [])]
    except Exception:
        result['ok'] = False
        (root / 'failure.txt').write_text(traceback.format_exc())
        result['failure_saved_privately'] = True
    finally:
        for process in children:
            process.join(5)
            if process.is_alive():
                process.terminate()
                process.join(5)
        result['worker_exit_codes'] = [p.exitcode for p in children]
        result['worker_pids'] = [p.pid for p in children]
        result['workers_exited'] = all(not p.is_alive() for p in children)
        for pipe in pipes:
            pipe.close()
        fixture.close()
        result['console_log_after_stop'] = fixture.console_log_status()
        if result['console_log_after_stop']['supported']:
            result['ok'] &= result['console_log_after_stop']['ok']
        if fixture.shaper:
            result['shaper'] = {'stats': fixture.shaper.stats,
                               'failure': fixture.shaper.failure,
                               'trace_events': fixture.shaper.trace_events,
                               'trace_rows': len(fixture.shaper.trace_rows),
                               'trace_capacity': fixture.shaper.trace_rows.maxlen,
                               'trace_truncated': fixture.shaper.trace_events > len(fixture.shaper.trace_rows)}
            (root / 'wire-samples.json').write_text(json.dumps(list(fixture.shaper.trace_rows)))
        result['node_stop_results'] = fixture.stop_results
        result['remaining_sockets'] = len(list(root.glob('*/*.sock')))
        result['ok'] = (result['ok'] and result['worker_exit_codes'] == [0, 0, 0] and
                         result['workers_exited'] and fixture.stop_results == [0, 0, 0, 0] and
                         result['remaining_sockets'] == 0)
        if fixture.shaper:
            result['ok'] &= fixture.shaper.failure is None
        if args.full_load:
            result['contention_qualification'] = qualifies_full_contention(result)
        (root / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({'ok': result['ok'], 'directory': str(root)}))
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
