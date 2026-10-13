#!/usr/bin/env python3
"""Correlate bounded endpoint frame/cell observations; admission is not delivery."""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import re

TERMINAL_DROPS = {'budget_drop', 'ingress_full', 'queue_expired', 'queue_overflow'}


def distribution(values):
    values = sorted(values)
    if not values:
        return None
    return {'count': len(values), 'max': values[-1], 'p50': values[len(values)//2],
            'p95': values[int((len(values)-1)*.95)]}


def analyze(log):
    events = defaultdict(lambda: defaultdict(int))
    costs = {}
    frames = []
    capped = 'media.source_trace_limit ' in log
    for line in log.splitlines():
        match = re.search(r'media.source_(cell|frame)_trace\s+(.+)', line)
        if not match:
            continue
        values = dict(re.findall(r'(\w+)=([\w-]+)', match[2]))
        key = (int(values['local_slot']), values['epoch'])
        if match[1] == 'cell':
            cell = (*key, int(values['seq']))
            stage = values['stage']
            if stage not in TERMINAL_DROPS | {'budget_admit'}:
                raise ValueError('unknown source cell stage')
            events[cell][stage] += 1
            cost = int(values['wire_bytes'])
            if cell in costs and costs[cell] != cost:
                raise ValueError('conflicting source cell cost')
            costs[cell] = cost
        else:
            for k in ['first_seq', 'last_seq', 'cells', 'planned_cells',
                      'expired_cells', 'packets', 'raw_bytes', 'sequence_limit']:
                values[k] = int(values[k])
            frames.append((key, values))
    result = {'trace_available': bool(frames), 'trace_capped': capped,
              'scope': 'relayed source work items wholly within the declared nonce range; includes RTX repairs',
              'covers_direct_packet_ingress': False,
              'byte_units': 'OVL1 frame plus session AEAD; excludes carrier overhead',
              'admission_is_not_delivery': True, 'frame_rows': len(frames),
              'bounded_frames': 0, 'boundary_or_noncontiguous_rows': 0,
              'noncontiguous_rows': 0,
              'frames_with_unobserved_cells': 0, 'unobserved_cells': 0,
              'partially_shed_source_frames': 0, 'fully_shed_source_frames': 0,
              'native_partial_expiry_frames': 0, 'drop_stages': defaultdict(int),
              'partial_examples': []}
    counts, raw_sizes, wire_sizes = [], [], []
    for key, row in frames:
        first, last, count = row['first_seq'], row['last_seq'], row['cells']
        if row.get('contiguous') != 'true':
            result['noncontiguous_rows'] += 1
        if (row.get('contiguous') != 'true' or first < 1 or
                last > row['sequence_limit'] or last-first+1 != count):
            result['boundary_or_noncontiguous_rows'] += 1
            continue
        if not 1 <= count <= 512 or count + row['expired_cells'] > row['planned_cells'] or row['expired_cells'] < 0:
            raise ValueError('inconsistent frame cell counts')
        result['bounded_frames'] += 1
        counts.append(count)
        raw_sizes.append(row['raw_bytes'])
        cells = [(*key, n) for n in range(first, last+1)]
        missing = sum(cell not in events for cell in cells)
        result['unobserved_cells'] += missing
        result['frames_with_unobserved_cells'] += bool(missing)
        if not missing:
            wire_sizes.append(sum(costs[cell] for cell in cells))
        dropped = [cell for cell in cells if TERMINAL_DROPS & events.get(cell, {}).keys()]
        admitted = [cell for cell in cells if events.get(cell, {}).get('budget_admit') and cell not in dropped]
        for cell in dropped:
            for stage in TERMINAL_DROPS & events[cell].keys():
                result['drop_stages'][stage] += 1
        if dropped and admitted:
            result['partially_shed_source_frames'] += 1
            if len(result['partial_examples']) < 8:
                result['partial_examples'].append({
                    'first_seq': first, 'last_seq': last, 'packets': row['packets'],
                    'raw_bytes': row['raw_bytes'], 'admitted_without_later_drop': len(admitted),
                    'dropped_cells': len(dropped), 'unobserved_cells': missing})
        elif len(dropped) == count:
            result['fully_shed_source_frames'] += 1
        if row['expired_cells'] and count:
            result['native_partial_expiry_frames'] += 1
    result['cell_counts'] = distribution(counts)
    result['raw_frame_bytes'] = distribution(raw_sizes)
    result['observed_frame_wire_bytes'] = distribution(wire_sizes)
    result['complete_within_declared_scope'] = bool(result['bounded_frames']) and not (
        capped or result['unobserved_cells'] or result['noncontiguous_rows'])
    result['drop_stages'] = dict(result['drop_stages'])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stand', type=Path, required=True)
    args = parser.parse_args()
    result = analyze((args.stand/'runtime.log').read_text())
    summary = json.loads((args.stand/'summary.json').read_text())
    result['driver_timing_valid'] = summary['max_driver_interval_ms'] < 20
    result['fixture_ok'] = summary['ok']
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
