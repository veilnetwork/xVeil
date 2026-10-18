#!/usr/bin/env python3
"""Attribute an owned, same-host group PCM peak to its actual encoded packet.

Encoder input indices restart when packet duration changes. Match the absolute
first-input clock to the capture clock instead of assuming a process-wide
index. No RTP offset is inferred from packet order or periodic tone phase.
"""
import argparse
import bisect
import hashlib
import json
from pathlib import Path

from analyze_relay_audio_pipeline import fields
from group_pcm_timing import analyze_voice_path


def trace_sections(lines, begin, record, selected_ssrc=None):
    sections = []
    for line in lines:
        if line.startswith(begin + ' '):
            sections.append((fields(line), []))
        elif line.startswith(record + ' '):
            if not sections:
                raise ValueError('Record without trace header')
            sections[-1][1].append(fields(line))
    rows = []
    for meta, records in sections:
        if selected_ssrc is not None and meta['ssrc'] != selected_ssrc:
            continue
        if not len(records) == meta['count'] < meta['limit'] <= 32768:
            raise ValueError('Incomplete or capacity-limited native trace')
        if meta.get('seen', meta['count']) != meta['count']:
            raise ValueError('Incomplete encoder trace')
        rows.extend((meta, record) for record in records)
    if not rows:
        raise ValueError('Missing native trace')
    return rows


def attribute(peak, origin, captures, codec_rows, source_lines, receiver_lines,
              source_channel=None):
    """All clocks must be from this fixture's shared host monotonic clock."""
    offsets = {row['sender']['rtp_origin'] for row in codec_rows}
    if len(offsets) != 1:
        raise ValueError('Missing or changing sender RTP origin')
    offset = offsets.pop()
    if not isinstance(offset, int) or not 0 <= offset < 2**32:
        raise ValueError('Invalid sender RTP origin')
    captures = sorted(captures, key=lambda row: row['source_at'])
    clocks = [row['source_at'] for row in captures]
    if not clocks or any(b <= a for a, b in zip(clocks, clocks[1:])):
        raise ValueError('Missing or ambiguous capture clocks')
    at, out = peak['source_at_seconds'], peak['decoded_at_seconds']
    if min(abs(t-at) for t in clocks) > 1e-6:
        raise ValueError('PCM peak has no source capture witness')
    candidates = []
    for meta, row in trace_sections(source_lines, 'audio.encode.begin', 'audio.encode'):
        if row['ssrc'] != meta['ssrc'] or not 1 <= row['blocks'] <= 12:
            raise ValueError('Invalid encoder record')
        if row['first_us'] < 0:
            continue
        first = row['first_us'] / 1e6 - origin
        pos = bisect.bisect_left(clocks, first)
        near = min(range(max(0, pos-1), min(len(clocks), pos+1)),
                   key=lambda i: abs(clocks[i]-first))
        # Capture and encoder callbacks observe the same 10-ms input block.
        # Half a block is the maximum unambiguous clock alignment distance.
        if abs(clocks[near]-first) >= .005:
            continue
        end = near + row['blocks']
        if end < len(clocks) and clocks[near] <= at < clocks[end]:
            candidates.append((meta, row))
    if len(candidates) != 1:
        raise ValueError('Missing or ambiguous packet covering source input')
    meta, enc = candidates[0]
    stamp = (enc['timestamp'] + offset) % 2**32
    received = [row for _, row in trace_sections(receiver_lines,
                'audio.rtp.ingress.begin', 'audio.rtp.ingress', meta['ssrc'])
                if row['timestamp'] == stamp and row['payload_bytes'] == enc['bytes']]
    if len(received) != 1:
        raise ValueError('Missing or ambiguous receiver packet')
    ingress = received[0]
    times = [at, enc['encoded_us']/1e6-origin,
             ingress['arrived_us']/1e6-origin,
             ingress['drained_us']/1e6-origin, out]
    if times != sorted(times):
        raise ValueError('Invalid pipeline clock order')
    names = ['capture_to_encoded', 'encoded_to_ingress',
             'ingress_to_webrtc', 'webrtc_to_pcm_edge']
    result = dict(ssrc=meta['ssrc'], rtp_origin=offset, rtp_timestamp=stamp,
                rtp_sequence=ingress['seq'], source_at_seconds=at,
                decoded_at_seconds=out, packet_ms=enc['blocks']*10,
                encoder_input_index=enc['first_index'],
                encoder_first_input_monotonic_us=enc['first_us'],
                encoded_monotonic_us=enc['encoded_us'], ingress=ingress,
                total_ms=(out-at)*1000,
                spans_ms={name: (b-a)*1000 for name, a, b in
                          zip(names, times, times[1:])})
    if any(line.startswith('audio.group.send.begin ') for line in source_lines):
        if not isinstance(source_channel, int) or not 0 < source_channel < 2**64:
            raise ValueError('Missing source-to-receiver channel witness')
        sends = [row for _, row in trace_sections(source_lines,
                 'audio.group.send.begin', 'audio.group.send', meta['ssrc'])
                 if row['channel'] == source_channel and
                 row['seq'] == ingress['seq'] and row['timestamp'] == stamp]
        if len(sends) != 1:
            raise ValueError('Missing or ambiguous native fanout send')
        send = sends[0]
        if send['accepted'] != 1 or send['packet_bytes'] < enc['bytes'] + 12:
            raise ValueError('Invalid native send admission')
        stages = [enc['encoded_us'], send['attempted_us'],
                  send['admitted_us'], ingress['arrived_us']]
        if stages != sorted(stages):
            raise ValueError('Invalid native send clock order')
        result['native_send'] = send
        result['native_send_spans_ms'] = dict(zip(
            ('encoded_to_native_send', 'native_send_admission',
             'native_admission_to_ingress'),
            ((b-a)/1000 for a, b in zip(stages, stages[1:]))))
    return result


def capture_phase_name(summary, name):
    """Apply the fixture's diagnostic load labels, without changing evidence."""
    kind = summary['load_kind']
    if kind is None:
        if summary['video_file_load']:
            raise ValueError('Inconsistent fixture load kind')
        return 'audio-only-initial' if name == 'audio-only' else 'audio-only-steady'
    if kind not in ('both', 'files', 'video'):
        raise ValueError('Unknown fixture load kind')
    if summary['video_file_load'] != (kind == 'both'):
        raise ValueError('Inconsistent fixture load kind')
    if name == 'audio-video-file' and kind != 'both':
        return 'audio-' + kind
    return name


def analyze(directory):
    inputs = {}

    def read(name):
        data = (directory / name).read_bytes()
        inputs[name] = hashlib.sha256(data).hexdigest()
        return data.decode()

    summary = json.loads(read('summary.json'))
    if summary.get('separate_sdk_processes') is not True:
        raise ValueError('Requires owned same-host group fixture')
    paths = summary['voice_paths']
    if any(phase['missing'] for path in paths for phase in path['phases']):
        raise ValueError('Missing ordinal transitions prevent peak attribution')
    path, phase = max(((p, ph) for p in paths for ph in p['phases']),
                      key=lambda pair: pair[1]['max_ms'])
    source, receiver = path['source'], path['receiver']
    workers = {}
    for owner in (source, receiver):
        worker = json.loads(read(f'worker-{owner}/summary.json'))
        workers[owner] = worker
        if worker['origin_monotonic'] != summary['origin_monotonic']:
            raise ValueError('Different fixture origins')
    captures = [r for r in json.loads(read(f'worker-{source}/pcm-samples.json'))
                if r['side'] == source*4]
    decoded = [r for r in json.loads(read(f'worker-{receiver}/pcm-samples.json'))
               if r['side'] == receiver*3+source]
    repeated = analyze_voice_path(decoded, summary['duration_seconds'], captures)
    for item in repeated['phases']:
        item['phase'] = capture_phase_name(summary, item['phase'])
    check = next(p for p in repeated['phases'] if p['phase'] == phase['phase'])
    if check != phase:
        raise ValueError('Recorded PCM peak does not reproduce')
    mappings = [row['channel_handle'] for row in
                workers[source].get('channel_stats_after_capture', [])
                if row.get('participant_pair') == [source, receiver]]
    if len(mappings) > 1:
        raise ValueError('Ambiguous participant channel mapping')
    result = attribute(phase['peak'], summary['origin_monotonic'], captures,
                       json.loads(read(f'worker-{source}/codec-samples.json')),
                       read(f'worker-{source}/playout-trace.log').splitlines(),
                       read(f'worker-{receiver}/playout-trace.log').splitlines(),
                       mappings[0] if mappings else None)
    return dict(source=source, receiver=receiver, phase=phase['phase'],
                packet=result, input_sha256=inputs,
                limits=['Owned same-host clocks only; no physical acoustic latency claim',
                        'Encoded-to-ingress includes all local and transport stages; no per-hop attribution',
                        'Ingress-to-PCM can include codec lookahead/FEC and following packets; not NetEq alone',
                        'This analysis does not change the capture verdict or its quality gates'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    print(json.dumps(analyze(args.directory), indent=2))
