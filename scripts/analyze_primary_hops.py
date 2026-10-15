#!/usr/bin/env python3
"""Attribute fixture primary cells using PRIVATE owned-endpoint witnesses.

Relays never receive a producer role. A source's encrypted-preview digest
establishes ownership; existing envelope nonce/routing metadata then joins
the two hops. Preview/nonce matching is not full-body equality, and missing
observations are not evidence of packet loss.
"""
import argparse
import collections
import json
from pathlib import Path
import re

from analyze_opaque_frame_capture import analyze as validate_hops, distribution


def analyze(summary, capture, runtime_lines):
    validate_hops(summary, capture)
    if capture.get('expected_nodes', 3) != 3:
        raise ValueError('Requires the owned three-node relay fixture')
    witnesses = set()
    witness_times = collections.defaultdict(list)
    limited = False
    for line in runtime_lines:
        limited |= 'media.source_trace_limit ' in line
        if 'media.source_cell_trace ' not in line:
            continue
        fields = dict(re.findall(r'(\w+)=(\S+)', line))
        if (fields.get('stage'), fields.get('local_slot'), fields.get('family'),
                fields.get('msg_type')) != ('budget_admit', '0', '3', '3'):
            continue
        digest = fields.get('body_preview_sha256', '')
        if not re.fullmatch('[0-9a-f]{64}', digest):
            continue
        fingerprint = (int(fields['body_len']), digest)
        witnesses.add(fingerprint)
        if fields.get('at_unix_us', '').isdigit():
            witness_times[fingerprint].append(int(fields['at_unix_us']))
    clock = capture['clock']
    origin = clock['wall_us'] - (clock['monotonic_us'] - summary['stand_start_monotonic_us'])
    grouped = collections.defaultdict(lambda: {'tx': [], 'rx': []})
    owned = set()
    captured_witnesses = set()
    observation_ranges = collections.defaultdict(list)
    for row in capture['rows']:
        observer = row['source'] if row['direction'] == 'tx' else row['target']
        observation_ranges[observer].append((row['at_us'] - origin) / 1e6)
        seal = row.get('seal')
        if seal is None:
            continue
        key = tuple(seal[k] for k in ('source', 'target', 'epoch', 'sequence'))
        if key[0] not in (1, 2) or key[1] != 3 - key[0]:
            continue
        pair = (row['source'], row['target'])
        fingerprint = (row['body_len'], row['preview_len'], row['preview_sha256'])
        grouped[key, pair, fingerprint][row['direction']].append(row)
        if (row['direction'] == 'tx' and row['source'] == key[0]
                and row['target'] == 0 and (row['body_len'], row['preview_sha256']) in witnesses):
            owned.add(key)
            captured_witnesses.add((row['body_len'], row['preview_sha256']))
    paths = collections.defaultdict(dict)
    ambiguous = set()
    for (key, pair, _), sides in grouped.items():
        if key not in owned:
            continue
        if len(sides['tx']) > 1 or len(sides['rx']) > 1:
            ambiguous.add(key)
            continue
        if len(sides['tx']) != 1 or len(sides['rx']) != 1:
            continue
        if pair in paths[key]:
            ambiguous.add(key)
        paths[key][pair] = (sides['tx'][0]['at_us'], sides['rx'][0]['at_us'])
    cells = []
    incomplete = 0
    for key in owned - ambiguous:
        source, target = key[:2]
        first, second = paths[key].get((source, 0)), paths[key].get((0, target))
        if first is None or second is None:
            incomplete += 1
            continue
        clocks = [*first, *second]
        if clocks != sorted(clocks):
            raise ValueError('Primary route has inverted capture/dispatch clocks')
        cells.append(dict(source=source, target=target,
                          send_seconds=(clocks[0] - origin) / 1e6,
                          source_to_relay_ms=(clocks[1] - clocks[0]) / 1000,
                          relay_residence_ms=(clocks[2] - clocks[1]) / 1000,
                          relay_to_target_ms=(clocks[3] - clocks[2]) / 1000,
                          total_ms=(clocks[3] - clocks[0]) / 1000))
    spans = ('source_to_relay_ms', 'relay_residence_ms', 'relay_to_target_ms', 'total_ms')
    missing_times = [(at - origin) / 1e6 for key in witnesses - captured_witnesses
                     for at in witness_times.get(key, ())]
    lower = summary.get('opaque_frame_capture_start_seconds')
    upper = summary['duration_seconds']
    missing_in_window = (sum(any(lower <= (at - origin) / 1e6 < upper
                                 for at in witness_times.get(key, ()))
                             for key in witnesses - captured_witnesses)
                         if lower is not None else None)
    return dict(same_host_fixture_only=True, roles_from_owned_endpoint_only=True,
                full_body_equality_proof=False, missing_observations_are_not_loss=True,
                source_trace_limit_reached=limited, source_preview_witnesses=len(witnesses),
                source_witnesses_without_clock=sum(not witness_times.get(key) for key in witnesses),
                uncaptured_source_witnesses=len(witnesses - captured_witnesses),
                uncaptured_witness_range_seconds=[min(missing_times), max(missing_times)] if missing_times else None,
                requested_capture_window_seconds=[lower, upper],
                uncaptured_source_witnesses_in_window=missing_in_window,
                captured_owned_primary_cells=len(owned), ambiguous_route_cells=len(ambiguous),
                incomplete_route_cells=incomplete, matched_route_cells=len(cells),
                capture_limit_reached_nodes=capture.get('capture_limit_reached_nodes'),
                observed_ranges_seconds={str(i): [min(v), max(v)]
                                         for i, v in observation_ranges.items()},
                directions=[dict(source=i, spans={k: distribution([c[k] for c in cells if c['source'] == i])
                                                 for k in spans}) for i in (1, 2)],
                largest_cells=sorted(cells, key=lambda c: c['total_ms'], reverse=True)[:10])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture', type=Path)
    args = parser.parse_args()
    root = args.fixture
    with (root / 'runtime.log').open() as lines:
        result = analyze(json.loads((root / 'summary.json').read_text()),
                         json.loads((root / 'opaque-frame-capture.json').read_text()), lines)
    print(json.dumps(result, indent=2))
