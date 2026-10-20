#!/usr/bin/env python3
"""Join encoded images, fanout RTP, SDK source decisions and decoder output.

Owned same-host captures only. Missing witnesses remain unknown, never a
claimed network drop. This measures synthetic frames, not perceived quality.
"""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re

from analyze_direct_source import attribute, records
from analyze_video_loss import read_trace


def metadata(path, prefix, item):
    sessions = {}
    with Path(path).open() as stream:
        for line in stream:
            if not line.startswith(prefix + '.'):
                continue
            name, _, body = line.rstrip().partition(' ')
            row = {k: int(v) for k, v in re.findall(r'(\w+)=([^\s]+)', body)}
            identity = row.pop('id')
            if name == prefix + '.begin':
                if identity in sessions:
                    raise ValueError('Duplicate metadata header')
                sessions[identity] = dict(header=row, rows=[], end=None)
                continue
            if identity not in sessions or sessions[identity]['end'] is not None:
                raise ValueError('Metadata outside recorder lifetime')
            if name == prefix + '.end':
                sessions[identity]['end'] = row
            elif name == prefix + '.' + item:
                sessions[identity]['rows'].append(row)
            else:
                raise ValueError('Unknown metadata record')
    if not sessions:
        raise ValueError('Missing metadata recorder')
    for s in sessions.values():
        h = s['header']
        if (s['end'] != {'write_ok': 1} or h['count'] != h['seen'] or
                h['count'] != len(s['rows'])):
            raise ValueError('Incomplete or truncated metadata')
    return [r for s in sessions.values() for r in s['rows']]


def originals(rows, channel):
    """Separate peers; padding and late repair attempts never extend a frame."""
    groups = defaultdict(dict)
    for r in sorted(rows, key=lambda r: r['at_us']):
        if (r['stage'] == 's' and r.get('channel') == channel and r['payload'] > 0):
            groups[r['timestamp']].setdefault(r['seq'], r)
    if not groups:
        raise ValueError('Missing group fanout send diagnostics')
    return {t: sorted(v.values(), key=lambda r: r['at_us']) for t, v in groups.items()}


def match_images(images, frames):
    """Establish the native RTP random timestamp offset, do not assume zero."""
    by_stamp = {r['timestamp']: r for r in images}
    if len(by_stamp) != len(images):
        raise ValueError('Ambiguous encoded timestamp')
    first_stamp, first = min(frames.items(), key=lambda pair: pair[1][0]['at_us'])
    offsets = {(first_stamp - r['timestamp']) & 0xffffffff for r in images
               if 0 <= first[0]['at_us'] - r['at_us'] < 2_000_000}
    choices = []
    for delta in offsets:
        matched = {t: by_stamp.get((t - delta) & 0xffffffff) for t in frames}
        if all(r is not None and 0 <= frames[t][0]['at_us'] - r['at_us'] < 2_000_000
               for t, r in matched.items()):
            choices.append((delta, matched))
    if len(choices) != 1:
        raise ValueError('Missing or ambiguous encoded/native timestamp offset')
    return choices[0]


def analyze(directory, same_host=False, native_only=False):
    if not same_host:
        raise ValueError('Explicit common monotonic host clock is required')
    directory = Path(directory)
    s = json.loads((directory / 'summary.json').read_text())
    for name in ('console_log_before_read', 'console_log_after_stop'):
        if not s[name]['ok'] or s[name]['dropped_records']:
            raise ValueError('Incomplete SDK log capture')
    start = s['origin_monotonic'] * 1_000_000
    tail = start + (s['duration_seconds'] - 3) * 1_000_000
    # Spawned media clients seal frames; the owning SDK nodes make source
    # admission decisions in the parent process. Match by exact seal identity.
    parent_path = directory / 'native.log'
    parent_decisions = []
    if not native_only:
        parent_decisions = list(records(parent_path, 'media.source_cell_trace '))
        with parent_path.open() as stream:
            if any(any(key in line for key in ('source_trace_limit', 'source_accepted_trace_limit',
                                              'source_work_trace_limit')) for line in stream):
                raise ValueError('Parent source diagnostic bound exhausted')
    trace, images, decodes, seals, decisions = {}, {}, {}, {}, {}
    for i in range(s['participants']):
        path = directory / f'worker-{i}'
        native = path / 'playout-trace.log'
        trace[i] = read_trace(native)
        images[i] = metadata(native, 'video.frame_budget', 'image')
        decodes[i] = metadata(native, 'video.decode', 'frame')
        seals[i] = [] if native_only else list(records(path / 'native.log', 'media.rtp.cell '))
        decisions[i] = defaultdict(list)
        local_decisions = [] if native_only else list(records(path / 'native.log', 'media.source_cell_trace '))
        for r in [*parent_decisions, *local_decisions]:
            decisions[i][r['epoch'], int(r['seq'])].append(r)
        if not native_only:
            with (path / 'native.log').open() as stream:
                for line in stream:
                    if any(key in line for key in ('source_trace_limit', 'source_accepted_trace_limit',
                                                  'source_work_trace_limit')):
                        raise ValueError('Source diagnostic bound exhausted')
    out = []
    for source in range(s['participants']):
        for route in s['workers'][source]['channel_stats_after_capture']:
            receiver = next(i for i in route['participant_pair'] if i != source)
            channel = route['channel_handle']
            frames = originals(trace[source]['rtp'], channel)
            delta, encoded = match_images(images[source], frames)
            ssrcs = {r['ssrc'] for rows in frames.values() for r in rows}
            if len(ssrcs) != 1:
                raise ValueError('Ambiguous source SSRC')
            ssrc = ssrcs.pop()
            epochs = {r['epoch'] for r in seals[receiver] if r['stage'] == 'received'
                      and int(r['ssrc']) == ssrc}
            peer_cells = defaultdict(list)
            for r in seals[receiver]:
                if r['stage'] == 'received':
                    peer_cells[r['epoch'], int(r['seq'])].append(int(r['monotonic_us']))
            seal_index = defaultdict(list)
            for r in seals[source]:
                if r['stage'] == 'sealed' and r['epoch'] in epochs:
                    seal_index[tuple(int(r[k]) for k in
                        ('ssrc', 'rtp_seq', 'timestamp', 'payload_bytes'))].append(r)
            attempt_index = defaultdict(list)
            for r in trace[source]['rtp']:
                if r['stage'] == 's' and r.get('channel') == channel:
                    attempt_index[r['ssrc'], r['seq'], r['timestamp'], r['payload']].append(r)
            received = defaultdict(list)
            for r in trace[receiver]['rtp']:
                if r['stage'] == 'r' and r['ssrc'] == ssrc:
                    received[r['seq'], r['timestamp'], r['payload']].append(r['at_us'])
            decoded = defaultdict(list)
            for r in decodes[receiver]:
                if r['ssrc'] == ssrc:
                    decoded[r['timestamp']].append(r)
            evidence = []
            for timestamp, rows in sorted(frames.items(), key=lambda pair: pair[1][0]['at_us']):
                image = encoded[timestamp]
                markers = [r for r in rows if r['marker']]
                marker_us = markers[0]['at_us'] if len(markers) == 1 else None
                seen, statuses, witnesses = [], [], []
                for r in rows:
                    key = r['ssrc'], r['seq'], r['timestamp'], r['payload']
                    ingress = received[r['seq'], r['timestamp'], r['payload']]
                    if ingress:
                        seen.append(min(ingress))
                    if r['result']:
                        statuses.append('native_rejected')
                        continue
                    if native_only:
                        statuses.append('SDK_admission_not_audited')
                        continue
                    candidates = seal_index[key]
                    try:
                        decision_rows = [d for seal in candidates for d in
                            decisions[source][seal['epoch'], int(seal['seq'])]]
                        result = attribute(attempt_index[key], candidates, decision_rows)
                        statuses.append(result['source_verdict'])
                        cell_times = peer_cells[result['epoch'], result['cell_sequence']]
                        witnesses.append(dict(sequence=r['seq'],
                            epoch=result['epoch'], cell_sequence=result['cell_sequence'],
                            verdict=result['source_verdict'],
                            native_to_seal_ms=result['native_to_seal_ms'],
                            original_cell_seen_at_peer=bool(cell_times),
                            seal_to_peer_ms=(min(cell_times)-result['seal_us'])/1000 if cell_times else None,
                            source_stage_times=[dict(stage=d['stage'], monotonic_us=int(d['monotonic_us']))
                                                for d in result['source_stages']]))
                    except ValueError as error:
                        statuses.append('unattributed: ' + str(error))
                outputs = decoded[timestamp]
                if any((d['width'], d['height']) != (image['width'], image['height']) for d in outputs):
                    raise ValueError('Encoded and decoded dimensions disagree')
                evidence.append(dict(timestamp=timestamp, image=image,
                    seconds=(image['at_us']-start)/1_000_000,
                    tail_censored=image['at_us'] >= tail,
                    original_packets=len(rows), native_rejected=sum(r['result'] != 0 for r in rows),
                    image_to_first_native_ms=(rows[0]['at_us']-image['at_us'])/1000,
                    native_first_to_marker_ms=(marker_us-rows[0]['at_us'])/1000 if marker_us else None,
                    source_verdicts=dict(Counter(statuses)),
                    payload_complete_at_ingress=len(seen) == len(rows),
                    full_payload_from_encode_ms=(max(seen)-image['at_us'])/1000 if len(seen)==len(rows) else None,
                    decoded=len(outputs) > 0,
                    encode_to_decode_ms=(min(r['at_us'] for r in outputs)-image['at_us'])/1000 if outputs else None))
                if image['cap_after'] > 0 and (image['cap_before'] == 0 or image['cap_after'] < image['cap_before']):
                    evidence[-1]['source_packet_witnesses'] = witnesses
            cuts = [r for r in evidence if r['image']['cap_after'] > 0 and
                    (r['image']['cap_before'] == 0 or r['image']['cap_after'] < r['image']['cap_before'])]
            out.append(dict(source=source, receiver=receiver, channel=channel, ssrc=ssrc,
                            encoded_to_native_timestamp_offset=delta,
                            frames=len(evidence), decoded=sum(r['decoded'] for r in evidence),
                            encoded_images=len(images[source]),
                            encoded_cuts_without_native_send=[r for r in images[source]
                                if r['cap_after'] > 0 and
                                (r['cap_before'] == 0 or r['cap_after'] < r['cap_before']) and
                                ((r['timestamp'] + delta) & 0xffffffff) not in frames],
                            pixel_cuts=cuts, frame_evidence=evidence))
    return dict(raw_capture_ok=s['ok'], duration_seconds=s['duration_seconds'], directions=out,
                sdk_admission_audited=not native_only,
                scope='Same-host endpoint metadata; no live speech or display quality claim. '
                      'Unknown SDK witnesses are not proof of drops. Final three seconds are censored.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--same-host-monotonic', action='store_true')
    parser.add_argument('--native-only', action='store_true',
                        help='audit only complete native/decoder recorders, with no SDK source attribution')
    args = parser.parse_args()
    print(json.dumps(analyze(args.directory, args.same_host_monotonic, args.native_only), indent=2))
