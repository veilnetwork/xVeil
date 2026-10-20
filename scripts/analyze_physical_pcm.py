#!/usr/bin/env python3
"""Decoded tone transitions across the two physical QA processes.

Times refer to synthetic capture submission and decoded PCM observation, not
physical microphone/speaker latency. Keep ordinal matching: never re-anchor a
lost cycle to a later occurrence of the same periodic tone.
"""
import argparse
import json
import math
from pathlib import Path
import statistics

from pcm_timing import input_edges


def decoded_edges(rows):
    decoded = []
    previous = pending = None
    pending_at = None
    run = 0
    for row in rows:
        frequency = row['freq'] if row['freq'] and row['rms'] >= 500 else None
        if frequency is None or frequency == previous:
            pending, run = None, 0
            continue
        if frequency != pending:
            pending, pending_at, run = frequency, row['t'], 1
        else:
            run += 1
        if run >= 2:
            decoded.append((pending_at, frequency))
            previous = frequency
            pending, run = None, 0
    return decoded


def analyze_path(captures, received, duration, source_shift=0, receiver_shift=0,
                 delay_correction_low=0, delay_correction_high=0):
    edges = [(at + source_shift, freq, tick)
             for at, freq, tick in input_edges(captures)]
    decoded = [(at + receiver_shift, freq) for at, freq in decoded_edges(received)]
    phases = []
    for lo, hi, name in [(5, 30, 'audio_only'), (30, 45, 'audio_video'),
                         (45, 150, 'p2p_video_files'), (150, 180, 'handover'),
                         (180, duration, 'relay_video_files')]:
        hi = min(hi, duration)
        if lo >= hi:
            continue
        delays, unmatched = [], []
        for ordinal, (at, frequency, _) in enumerate(edges):
            if not lo <= at < hi:
                continue
            if (ordinal >= len(decoded) or decoded[ordinal][1] != frequency
                    or decoded[ordinal][0] < at):
                unmatched.append(ordinal)
            else:
                delays.append((decoded[ordinal][0] - at) * 1000)
        ordered = sorted(delays)
        percentile = lambda p: (ordered[math.ceil(p * len(ordered)) - 1]
                                if ordered else None)
        phases.append(dict(phase=name, from_seconds=lo, until_seconds=hi,
                           matched=len(delays), unmatched=len(unmatched),
                           first_unmatched_ordinals=unmatched[:10],
                           median_ms=statistics.median(delays) if delays else None,
                           p95_ms=percentile(.95), max_ms=max(delays, default=None),
                           max_clock_interval_ms=(
                               [max(delays) + delay_correction_low * 1000,
                                max(delays) + delay_correction_high * 1000]
                               if delays else None)))
    return dict(phases=phases, source_edges=len(edges), decoded_edges=len(decoded),
                matching='ordinal_from_actual_capture_start',
                pcm_block_ms=10, rms_threshold=500)


def analyze(directory, duration):
    result = json.loads((directory / 'result.json').read_text())
    captures, received, offsets, origins, stats = {}, {}, {}, {}, {}
    for name, participant in [('mac', 0), ('phone', 1)]:
        stopped = result['pcm_stopped'][name]['probes']
        if len(stopped) != 1 or not stopped[0]['stopped']:
            raise ValueError('Expected one stopped engine: ' + name)
        probe = stopped[0]
        rows = [json.loads(line) for line in
                (directory / (name + '-pcm-0.jsonl')).read_text().splitlines()]
        stats[name] = probe['stats']
        if (len(rows) != probe['rows'] or len(rows) != stats[name]['ticks'] * 3
                or stats[name]['dropped_rows'] or any(stats[name]['failures'])):
            raise ValueError('Incomplete or failed PCM observations: ' + name)
        captures[name] = [r for r in rows if r['side'] == participant * 3 + participant]
        received[name] = [r for r in rows if r['side'] == participant * 3 + (1 - participant)]
        source = captures[name]
        if (source[0]['source_at'] > .1 or source[-1]['source_at'] < duration
                or [r['source_tick'] for r in source] != list(range(len(source)))):
            raise ValueError('Incomplete source interval: ' + name)
        cs = [c for c in result['clock_calibrations'] if c['name'] == name]
        if not cs or any(c['low'] > c['high'] for c in cs):
            raise ValueError('Invalid clock calibration: ' + name)
        offsets[name] = dict(initial_mid=cs[0]['mid'], low=min(c['low'] for c in cs),
                             high=max(c['high'] for c in cs), count=len(cs))
        origins[name] = probe['origin'] + offsets[name]['initial_mid']
    common = origins['mac']
    if abs(origins['phone'] - common) > .0001:
        raise ValueError('PCM sources did not share the planned host epoch')
    paths = {}
    for sender, receiver in [('mac', 'phone'), ('phone', 'mac')]:
        a, b = offsets[sender], offsets[receiver]
        paths[sender + '_to_' + receiver] = analyze_path(
            captures[sender], received[receiver], duration,
            source_shift=origins[sender] - common,
            receiver_shift=origins[receiver] - common,
            delay_correction_low=b['low'] - b['initial_mid'] - a['high'] + a['initial_mid'],
            delay_correction_high=b['high'] - b['initial_mid'] - a['low'] + a['initial_mid'])
    return dict(scope='synthetic ADM, real codec/network, decoded PCM; not hardware acoustics',
                duration_seconds=duration, paths=paths, driver_stats=stats,
                observed_clock_offset_envelopes=offsets,
                clock_limit='Envelope across measured brackets; unsampled clock drift is not proven bounded',
                overall_quality_verdict=None)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--duration', type=float, default=300)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.write_text(json.dumps(analyze(args.directory, args.duration), indent=2) + '\n')
