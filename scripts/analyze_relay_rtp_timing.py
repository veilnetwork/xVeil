#!/usr/bin/env python3
"""Summarize same-process, synthetic-fixture RTP timing without packet IDs.

Only for relay-codec-control.py evidence: source and receiver timestamps use
the same monotonic clock. Block order identifies a trace source, not a device.
Flight starts after SDK admission; it includes the remaining transport path.
It excludes encoding/pacing before admission and decoded playout afterward.
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


def analyze(summary, lines):
    if summary.get('loopback_only') is not True:
        raise ValueError('Timing requires a same-process loopback fixture')
    start = summary['stand_start_monotonic_us']
    end = summary['duration_seconds']
    blocks = {'send': [], 'ingress': []}
    for line in lines:
        for kind in blocks:
            if f'audio.rtp.{kind}.begin ' in line:
                blocks[kind].append([])
            elif f'audio.rtp.{kind} seq=' in line:
                if not blocks[kind]:
                    raise ValueError('RTP row without a trace block')
                row = {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', line)}
                blocks[kind][-1].append(row)
    sends = {}
    for source, block in enumerate(blocks['send']):
        for row in block:
            if not row['accepted']:
                continue
            key = (row['seq'], row['timestamp'])
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
            if not 5 <= at < end:
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
    if not groups:
        raise ValueError('No matched payload timing samples')
    return {
        'same_process_fixture_only': True,
        'trace_blocks_are_not_device_labels': True,
        'first_five_seconds_excluded': True,
        'unmatched_payload_rows': unmatched,
        'trace_limit_may_have_been_reached': any(
            len(b) >= 4096 for kind in blocks.values() for b in kind),
        'send_trace_rows': [len(b) for b in blocks['send']],
        'receive_trace_rows': [len(b) for b in blocks['ingress']],
        'phases': [dict(source_trace_block=source, phase=phase,
                        admitted_to_ingress=distribution(group['flight']),
                        ingress_to_webrtc=distribution(group['drain']),
                        peak_flight_at_seconds=round(max(group['peak_times'])[1], 3))
                   for (source, phase), group in sorted(groups.items())],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture', type=Path)
    args = parser.parse_args()
    summary = json.loads((args.fixture / 'summary.json').read_text())
    with (args.fixture / 'native.log').open() as log:
        print(json.dumps(analyze(summary, log), indent=2))


if __name__ == '__main__':
    main()
