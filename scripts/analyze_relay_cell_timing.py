#!/usr/bin/env python3
"""Attribute sparse sealed-cell delays in an owned same-process relay fixture.

Uses existing endpoint observations only. Emits no cell IDs, addresses, keys
or payloads. These samples cannot prove delivery completeness or call quality.
The enqueue-to-receive span includes transport, relay and endpoint processing;
it is not a measurement of network latency or of one particular relay queue.
"""
import argparse
import collections
import json
import math
from pathlib import Path
import re


PAIRS = (
    ('relay_send', 'socket_written'),
    ('socket_written', 'daemon_read'),
    ('daemon_read', 'handler_enter'),
    ('handler_enter', 'relay_queued'),
    ('relay_queued', 'received'),
)
STAGES = {stage for pair in PAIRS for stage in pair}


def distribution(values):
    ordered = sorted(values)
    if not ordered:
        return None
    return {'count': len(ordered), 'max_ms': round(ordered[-1], 3),
            'p95_ms': round(ordered[math.ceil(.95 * len(ordered)) - 1], 3)}


def analyze(summary, lines):
    if summary.get('loopback_only') is not True:
        raise ValueError('Requires an owned same-process loopback fixture')
    cells = collections.defaultdict(lambda: collections.defaultdict(list))
    for line in lines:
        if 'ipc.rt_trace.sealed_sample ' not in line and 'media.cell.sample ' not in line:
            continue
        row = dict(re.findall(r'(\w+)=([^\s]+)', line))
        if row.get('stage') not in STAGES:
            continue
        if not re.fullmatch(r'[0-9a-f]{16}', row.get('epoch', '')):
            raise ValueError('Invalid sealed-cell trace header')
        for name in ('seq', 'at_ms', 'bytes'):
            row[name] = int(row[name])
        if min(row['seq'], row['at_ms'], row['bytes']) <= 0:
            raise ValueError('Invalid sealed-cell trace bounds')
        cells[row['epoch'], row['seq']][row['stage']].append(row)

    spans = collections.defaultdict(list)
    ambiguous = size_conflicts = rounding = no_receiver = 0

    def observe(name, value):
        nonlocal rounding
        # Logging after a completed write can race the peer's read observation;
        # wall timestamps also have millisecond resolution. Do not turn an
        # inverted observation into a purported latency of zero.
        if value < 0:
            if value < -1:
                raise ValueError('Trace clocks or stage order contradict attribution')
            rounding += 1
            return
        spans[name].append(value)

    for stages in cells.values():
        if any(len(rows) != 1 for rows in stages.values()):
            ambiguous += 1
            continue
        stages = {stage: rows[0] for stage, rows in stages.items()}
        if len({row['bytes'] for row in stages.values()}) != 1:
            size_conflicts += 1
            continue
        no_receiver += 'received' not in stages
        for begin, end in PAIRS:
            if begin in stages and end in stages:
                observe(begin + '_to_' + end,
                        stages[end]['at_ms'] - stages[begin]['at_ms'])
        received = stages.get('received')
        if received is None:
            continue
        daemon_age = int(received.get('delivery_daemon_age_us', -1))
        sdk_age = int(received.get('delivery_sdk_age_us', -1))
        if daemon_age >= 0:
            observe('receiver_ipc_encode_to_authenticated_receive', daemon_age / 1000)
            if 'relay_queued' in stages:
                observe('origin_enqueue_to_receiver_ipc_encode',
                        received['at_ms'] - stages['relay_queued']['at_ms'] - daemon_age / 1000)
        if sdk_age >= 0:
            observe('receiver_sdk_read_to_authenticated_receive', sdk_age / 1000)
        if daemon_age >= 0 and sdk_age >= 0:
            if daemon_age < sdk_age:
                raise ValueError('Receiver monotonic stages contradict attribution')
            observe('receiver_ipc_encode_to_sdk_read', (daemon_age - sdk_age) / 1000)

    if not spans:
        raise ValueError('No attributable timing observations')
    return {
        'same_process_fixture_only': True,
        'sparse_samples_are_not_delivery_or_quality_proof': True,
        'queued_stage_is_origin_enqueue_not_relay_processing': True,
        'unique_sampled_cells': len(cells),
        'ambiguous_cells_skipped': ambiguous,
        'conflicting_cell_sizes_skipped': size_conflicts,
        'cells_without_sampled_receiver': no_receiver,
        'inverted_observations_skipped': rounding,
        'spans': {name: distribution(values) for name, values in sorted(spans.items())},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture', type=Path)
    args = parser.parse_args()
    summary = json.loads((args.fixture / 'summary.json').read_text())
    with (args.fixture / 'runtime.log').open() as stream:
        print(json.dumps(analyze(summary, stream), indent=2))


if __name__ == '__main__':
    main()
