#!/usr/bin/env python3
"""Join an owned PCM peak to source-session budget and DATAGRAM admission."""
import argparse
import json
from pathlib import Path
import re

from analyze_group_sdk_packet import analyze as analyze_sdk, cell, clock, records, unique


def attribute(sdk, rows):
    identity = (sdk['epoch'], sdk['cell_sequence'])
    rows = [row for row in rows if cell(row) == identity]
    witnesses = {}
    for name in ('budget_admit', 'datagram_accepted'):
        witnesses[name] = unique((row for row in rows if row['stage'] == name), name)
    before, after = (witnesses[name] for name in ('budget_admit', 'datagram_accepted'))
    for field in ('local_slot', 'wire_bytes', 'family', 'msg_type',
                  'body_len', 'body_preview_sha256'):
        if before[field] != after[field]:
            raise ValueError('Different source-session frames: ' + field)
    if int(before['local_slot']) != 0:
        raise ValueError('Not a private local primary source')
    if not re.fullmatch('[0-9a-f]{64}', before['body_preview_sha256']):
        raise ValueError('Invalid encrypted frame witness')
    if int(after['connection_trace_id']) <= 0:
        raise ValueError('Missing QUIC connection witness')
    if int(before['wire_bytes']) <= sdk['sealed_bytes'] or int(before['body_len']) <= sdk['sealed_bytes']:
        raise ValueError('Invalid source-session frame length')
    times = sdk['observations_us']
    budget, accepted = clock(before), clock(after)
    if not times['handler_enter'] <= budget <= accepted:
        raise ValueError('Invalid source-session causal clocks')
    if budget > times['sdk_authenticated']:
        raise ValueError('Receiver precedes source transport selection')
    return {
        'epoch': identity[0], 'cell_sequence': identity[1],
        'connection_trace_id': int(after['connection_trace_id']),
        'observations_us': {'budget_admit': budget, 'datagram_accepted': accepted},
        'encrypted_frame': {field: before[field] for field in
                            ('wire_bytes', 'family', 'msg_type', 'body_len', 'body_preview_sha256')},
        'spans_ms': {
            'handler_enter_to_budget_admit': (budget-times['handler_enter'])/1000,
            'budget_admit_to_datagram_accepted': (accepted-budget)/1000,
            'budget_admit_to_authenticated_receiver': (times['sdk_authenticated']-budget)/1000,
        },
        # Enqueue-return and post-completion observations are not causal starts.
        'post_completion_offsets_ms': {
            'relay_queued_to_budget_admit': (budget-times['relay_queued'])/1000,
            'datagram_accepted_to_authenticated_receiver': (times['sdk_authenticated']-accepted)/1000,
        },
    }


def analyze(directory):
    result = analyze_sdk(directory)
    path = directory/'native.log'
    with path.open() as stream:
        if any('media.source_trace_limit' in line or
               'media.source_accepted_trace_limit' in line for line in stream):
            raise ValueError('Source-cell trace was truncated')
    result['source_session'] = attribute(result['sdk'], records(path, 'media.source_cell_trace '))
    result['limits'] += [
        'DATAGRAM acceptance is a source-transport queue observation, not a NIC send',
        'Opaque session-frame digests and connection IDs are local diagnostics only',
        'Async source enqueue and transport returns may follow downstream processing',
    ]
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    print(json.dumps(analyze(parser.parse_args().directory), indent=2))
