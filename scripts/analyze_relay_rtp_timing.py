#!/usr/bin/env python3
"""Summarize same-process, synthetic-fixture RTP timing without packet IDs.

Only for relay-codec-control.py evidence: source and receiver timestamps use
the same monotonic clock. Block order identifies a trace source, not a device.
Flight starts after SDK admission; it includes the remaining transport path.
It excludes encoding/pacing before admission and decoded playout afterward.
A complete sender and ingress trace also accounts for accepted RTP packets
without a matching native ingress observation.
"""
import argparse
import collections
import json
import math
from pathlib import Path
import re


def distribution(values):
    ordered = sorted(values)
    return {'count': len(ordered),
            'max_ms': round(ordered[-1], 3),
            'p95_ms': round(ordered[math.ceil(.95 * len(ordered)) - 1], 3)}


def analyze(summary, lines, lower=5, upper=None):
    if summary.get('loopback_only') is not True:
        raise ValueError('Timing requires a same-process loopback fixture')
    start = summary['stand_start_monotonic_us']
    end = summary['duration_seconds']
    upper = end if upper is None else upper
    if not all(math.isfinite(v) for v in (lower, upper, end)) or not 0 <= lower < upper <= end:
        raise ValueError('Invalid recorded-time window')
    blocks = {'send': [], 'ingress': []}
    limits = {'send': [], 'ingress': []}
    counts = {'send': [], 'ingress': []}
    streams = {'send': [], 'ingress': []}
    for line in lines:
        for kind in blocks:
            if f'audio.rtp.{kind}.begin ' in line:
                m = re.search(r'\blimit=(\d+)\b', line)
                limit = int(m[1]) if m else 4096
                if not 1 <= limit <= 32768:
                    raise ValueError('Invalid native trace capacity')
                blocks[kind].append([])
                limits[kind].append(limit)
                count = re.search(r'\bcount=(\d+)\b', line)
                counts[kind].append(int(count[1]) if count else None)
                ssrc = re.search(r'\bssrc=(\d+)\b', line)
                streams[kind].append(int(ssrc[1]) if ssrc else None)
            elif f'audio.rtp.{kind} seq=' in line:
                if not blocks[kind]:
                    raise ValueError('RTP row without a trace block')
                row = {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', line)}
                blocks[kind][-1].append(row)
    sends = {}
    delivery = collections.defaultdict(collections.Counter)
    ingress_keys = {(ssrc, row['seq'], row['timestamp'])
                    for ssrc, block in zip(streams['ingress'], blocks['ingress'])
                    for row in block}
    for source, block in enumerate(blocks['send']):
        for row in block:
            at = (row['attempted_us'] - start) / 1_000_000
            key = (row['seq'], row['timestamp'])
            if lower <= at < upper:
                phase = 'audio-only' if at < 20 else 'competing'
                tally = delivery[source, phase]
                if row['accepted']:
                    tally['accepted'] += 1
                    ingress_key = (streams['send'][source], *key)
                    tally['observed_at_ingress' if ingress_key in ingress_keys
                          else 'absent_from_ingress'] += 1
                else:
                    tally['refused'] += 1
            if not row['accepted']:
                continue
            if key in sends:
                raise ValueError('Ambiguous RTP identity across source traces')
            sends[key] = source, row
    groups = collections.defaultdict(lambda: collections.defaultdict(list))
    unmatched = 0
    for block in blocks['ingress']:
        for received in block:
            if not received['payload_bytes']:
                continue
            sent = sends.get((received['seq'], received['timestamp']))
            if sent is None:
                unmatched += 1
                continue
            source, row = sent
            at = (row['attempted_us'] - start) / 1_000_000
            if not lower <= at < upper:
                continue
            phase = 'audio-only' if at < 20 else 'competing'
            flight = (received['arrived_us'] - row['admitted_us']) / 1000
            drain = (received['drained_us'] - received['arrived_us']) / 1000
            if flight < 0 or drain < 0:
                raise ValueError('Invalid clock order in fixture timestamps')
            group = groups[source, phase]
            group['flight'].append(flight)
            group['drain'].append(drain)
            group['peak_times'].append((flight, at))
    trace_limit = any(len(block) >= limit for kind in blocks
                      for block, limit in zip(blocks[kind], limits[kind]))
    sender_streams = set(streams['send'])
    delivery_complete = (
        bool(sender_streams) and None not in sender_streams and 0 not in sender_streams
        and sender_streams == set(streams['ingress'])
        and len(sender_streams) == len(blocks['send']) == len(blocks['ingress'])
        and not trace_limit
        and all(len(block) == count for kind in blocks
                for block, count in zip(blocks[kind], counts[kind]))
    )
    if not groups and not (delivery_complete and delivery):
        raise ValueError('No matched payload timing samples')
    return {
        'same_process_fixture_only': True,
        'trace_blocks_are_not_device_labels': True,
        'first_five_seconds_excluded': lower >= 5,
        'window_seconds': [lower, upper],
        'window_selected_by': 'attempted_us',
        'unmatched_payload_rows': unmatched,
        'trace_limit_may_have_been_reached': trace_limit,
        'send_trace_limits': limits['send'],
        'receive_trace_limits': limits['ingress'],
        'send_trace_rows': [len(b) for b in blocks['send']],
        'receive_trace_rows': [len(b) for b in blocks['ingress']],
        'source_delivery': [
            dict(source_trace_block=source, phase=phase, accepted=tally['accepted'],
                 refused=tally['refused'], observed_at_ingress=tally['observed_at_ingress'],
                 absent_from_ingress=tally['absent_from_ingress'])
            for (source, phase), tally in sorted(delivery.items())
        ] if delivery_complete else None,
        'phases': [dict(source_trace_block=source, phase=phase,
                        admitted_to_ingress=distribution(group['flight']),
                        ingress_to_webrtc=distribution(group['drain']),
                        peak_flight_at_seconds=round(max(group['peak_times'])[1], 3))
                   for (source, phase), group in sorted(groups.items())],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture', type=Path)
    parser.add_argument('--from-seconds', type=float, default=5)
    parser.add_argument('--to-seconds', type=float)
    args = parser.parse_args()
    summary = json.loads((args.fixture / 'summary.json').read_text())
    with (args.fixture / 'native.log').open() as log:
        print(json.dumps(analyze(summary, log, args.from_seconds, args.to_seconds), indent=2))


if __name__ == '__main__':
    main()
