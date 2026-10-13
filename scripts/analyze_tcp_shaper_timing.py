#!/usr/bin/env python3
"""Locate waits in an owned blind TCP fixture, without attributing media."""
import argparse
import json
import math
from pathlib import Path


SPANS = {
    'reader_arrival_to_read': ('oldest_byte_arrived_at', 'read_at'),
    'read_to_reservation': ('read_at', 'at'),
    'reservation_to_ready': ('at', 'ready'),
    'ready_to_write': ('ready', 'write_at'),
    'write_to_drain': ('write_at', 'sent_at'),
    'reader_arrival_to_write': ('oldest_byte_arrived_at', 'write_at'),
}


def distribution(values):
    values = sorted(values)
    return {'known_chunks': len(values),
            'max_ms': round(values[-1], 3) if values else None,
            'p95_ms': round(values[math.ceil(.95 * len(values)) - 1], 3) if values else None}


def analyze(summary, capture, lower=20, upper=None):
    if summary.get('loopback_only') is not True or summary.get('session_transport') != 'obfs4-tcp':
        raise ValueError('Requires an owned same-process TCP fixture')
    duration = summary['duration_seconds']
    upper = duration if upper is None else upper
    if not 0 <= lower < upper <= duration:
        raise ValueError('Invalid recorded-time window')
    start = capture['startat']
    if not math.isfinite(start) or abs(start * 1e6 - summary['stand_start_monotonic_us']) > 1000:
        raise ValueError('Fixture and shaper clocks do not share the recorded origin')
    rows = capture['rows']
    if type(capture['events']) is not int or capture['events'] < len(rows):
        raise ValueError('Invalid retained-event count')
    directions = []
    observed_reads = []
    for direction in (0, 1):
        selected = []
        for row in rows:
            # Select by read time, not reservation time: otherwise time waiting
            # for the reservation lock can move a delayed chunk out of a window.
            read = row.get('read_at')
            if read is None:
                raise ValueError('Missing chunk read clock')
            if not math.isfinite(read) or not -60 <= read - start <= duration + 60:
                raise ValueError('Foreign or invalid chunk clock')
            if row['direction'] not in (0, 1):
                raise ValueError('Invalid blind direction')
            if row['direction'] == direction and lower <= read - start < upper:
                selected.append(row)
                observed_reads.append(read - start)
        spans = {}
        for name, (begin, end) in SPANS.items():
            values = []
            for row in selected:
                a, b = row.get(begin), row.get(end)
                # The oldest known segment is not the oldest byte when any
                # arrival is unknown. Do not present that lower bound as exact.
                if begin == 'oldest_byte_arrived_at' and row.get('reader_arrival_unknown_bytes') != 0:
                    continue
                if a is None or b is None:
                    continue
                if not all(math.isfinite(v) for v in (a, b)) or b < a:
                    raise ValueError('Inverted or invalid shaper stage clock')
                values.append((b - a) * 1000)
            spans[name] = distribution(values)
            spans[name]['unknown_chunks'] = len(selected) - len(values)
        directions.append({'direction': direction, 'chunks': len(selected),
                           'bytes': sum(row['bytes'] for row in selected), 'spans': spans})
    scope = summary.get('shaper_scope', 'aggregate')
    if scope not in ('aggregate', 'per-target'):
        raise ValueError('Unknown recorded shaper scope')
    return {'same_process_fixture_only': True,
            'opaque_chunks_are_not_rtp_packets': True,
            'directions_are_not_media_roles': True,
            'scope': scope,
            'capacity_shared_across_connections': True,
            'window_selected_by': 'read_at', 'window_seconds': [lower, upper],
            'observed_read_seconds': [min(observed_reads), max(observed_reads)] if observed_reads else None,
            'retained_chunks': len(rows), 'events': capture['events'],
            'evicted_chunks': capture['events'] - len(rows), 'directions': directions}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('fixture', type=Path)
    p.add_argument('--from-seconds', type=float, default=20)
    p.add_argument('--to-seconds', type=float)
    args = p.parse_args()
    summary = json.loads((args.fixture / 'summary.json').read_text())
    capture = json.loads((args.fixture / 'shaper-queues.json').read_text())
    print(json.dumps(analyze(summary, capture, args.from_seconds, args.to_seconds), indent=2))


if __name__ == '__main__':
    main()
