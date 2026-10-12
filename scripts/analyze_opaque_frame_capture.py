#!/usr/bin/env python3
"""Match bounded opaque preview captures across one hop of a loopback fixture.

This measures capture-before-write to capture-at-dispatch, not relay scheduling
alone. Repeated preview matches are ambiguous; absent/rate-limited captures are
not evidence of message loss. No hashes, payloads or identities are printed.
"""
import argparse
import collections
import json
from pathlib import Path


def distribution(values):
    values = sorted(values)
    if not values:
        return None
    return dict(count=len(values), p50_ms=round(values[len(values)//2], 3),
                p95_ms=round(values[min(len(values)-1, int(len(values)*.95))], 3),
                max_ms=round(values[-1], 3))


def analyze(summary, capture):
    if summary.get('loopback_only') is not True:
        raise ValueError('One-hop timing requires this same-host fixture')
    if capture.get('format') != 'xveil-opaque-frame-capture-v1':
        raise ValueError('Unknown capture format')
    clock = capture['clock']
    start_wall = clock['wall_us'] - (clock['monotonic_us'] - summary['stand_start_monotonic_us'])
    grouped = collections.defaultdict(lambda: {'tx': [], 'rx': []})
    for row in capture['rows']:
        key = tuple(row[field] for field in ('source', 'target', 'family', 'msg_type',
                                            'body_len', 'preview_len', 'preview_sha256'))
        grouped[key][row['direction']].append(row)
    flights = collections.defaultdict(list)
    ambiguous = incomplete = 0
    for key, pair in grouped.items():
        if len(pair['tx']) > 1 or len(pair['rx']) > 1:
            ambiguous += 1
            continue
        if not pair['tx'] or not pair['rx']:
            incomplete += 1
            continue
        tx, rx = pair['tx'][0], pair['rx'][0]
        delay_us = rx['at_us'] - tx['at_us']
        if delay_us < 0:
            raise ValueError('Capture clock or event-order contradiction')
        flights[key[:2]].append(dict(send_seconds=(tx['at_us']-start_wall)/1e6,
                                    delay_ms=delay_us/1000, body_len=tx['body_len'],
                                    family=tx['family'], msg_type=tx['msg_type']))
    hops = []
    for (source, target), rows in sorted(flights.items()):
        phases = []
        for name, low, high in [('audio-only', 5, 20),
                                ('competing-local-sources', 20, summary['duration_seconds'])]:
            phase = [r['delay_ms'] for r in rows if low <= r['send_seconds'] < high]
            phases.append(dict(name=name, capture_to_dispatch=distribution(phase)))
        hops.append(dict(source=source, target=target, phases=phases,
                         largest_flights=sorted(rows, key=lambda r: r['delay_ms'], reverse=True)[:5]))
    return dict(same_host_clock=True, full_body_equality_proof=False,
                missing_captures_are_not_message_loss=True,
                capture_clock_uncertainty_us=clock['uncertainty_us'],
                ambiguous_preview_groups=ambiguous, incomplete_preview_groups=incomplete,
                acknowledgements=capture['ack_nodes'], reader_errors=capture['reader_errors'],
                readers_exited=capture['readers_exited'], hops=hops)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    result = analyze(json.loads((args.directory/'summary.json').read_text()),
                     json.loads((args.directory/'opaque-frame-capture.json').read_text()))
    print(json.dumps(result, indent=2))
