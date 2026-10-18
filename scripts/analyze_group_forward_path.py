#!/usr/bin/env python3
"""Join an owned group PCM peak to a role-blind, one-relay Forward path."""
import argparse
import json
from pathlib import Path
import re

from analyze_group_sdk_packet import cell, clock, records, unique
from analyze_group_source_session import analyze as analyze_session


def attribute(sdk, endpoint_rows, forward_rows):
    identity = sdk['epoch'], sdk['cell_sequence']
    endpoint_rows = [row for row in endpoint_rows if cell(row) == identity]
    sealed = unique((row for row in endpoint_rows if row['stage'] == 'sealed'),
                    'endpoint opaque seal')
    received = unique((row for row in endpoint_rows if row['stage'] == 'received'),
                      'authenticated endpoint opaque receipt')
    digest = sealed['sealed_sha256']
    if not re.fullmatch('[0-9a-f]{64}', digest) or digest != received['sealed_sha256']:
        raise ValueError('Missing or mismatched authenticated opaque digest')
    rows = [row for row in forward_rows if row['opaque_sha256'] == digest]
    if any(int(row['opaque_bytes']) != sdk['sealed_bytes'] for row in rows):
        raise ValueError('Different opaque payload lengths')
    source, destination = sdk['receiver_sdk_peer'], sdk['source_sdk_peer']
    if source == destination or any(not re.fullmatch('[0-9a-f]{8}', v)
                                    for v in (source, destination)):
        raise ValueError('Ambiguous endpoint node prefixes')
    tx = unique((row for row in rows if row['node'] == source and
                 row['stage'] == 'transport_selected'), 'source transport selection')
    relay = tx['peer']
    if relay in (source, destination) or not re.fullmatch('[0-9a-f]{8}', relay):
        raise ValueError('Requires a distinct one-relay path')

    def witness(stage, node, peer):
        return unique((row for row in rows if row['stage'] == stage and
                       row['node'] == node and row['peer'] == peer),
                      stage + ' at ' + node)

    relay_enter = witness('dispatch_enter', relay, source)
    relay_return = witness('dispatch_return', relay, source)
    relay_tx = witness('transport_selected', relay, destination)
    destination_enter = witness('dispatch_enter', destination, relay)
    destination_return = witness('dispatch_return', destination, relay)
    wanted = [tx, relay_enter, relay_return, relay_tx, destination_enter, destination_return]
    if len(rows) != len(wanted):
        raise ValueError('Unexpected extra opaque path observations')
    observations = {name: clock(row) for name, row in zip(
        ('source_transport_selected', 'relay_dispatch_enter', 'relay_dispatch_return',
         'relay_transport_selected', 'destination_dispatch_enter', 'destination_dispatch_return'), wanted)}
    observations['sdk_authenticated'] = sdk['observations_us']['sdk_authenticated']
    if clock(received) < observations['sdk_authenticated']:
        raise ValueError('Opaque endpoint witness precedes authentication')
    causal_names = ('source_transport_selected', 'relay_dispatch_enter',
                    'relay_transport_selected', 'destination_dispatch_enter', 'sdk_authenticated')
    causal = [observations[name] for name in causal_names]
    if causal != sorted(causal) or causal[0] < clock(sealed):
        raise ValueError('Invalid forwarding causal clocks')
    if clock(relay_return) < clock(relay_enter) or clock(destination_return) < clock(destination_enter):
        raise ValueError('Dispatch returned before entry')
    return {
        'opaque_sha256': digest, 'opaque_bytes': sdk['sealed_bytes'],
        'source_node': source, 'relay_node': relay, 'destination_node': destination,
        'observations_us': observations,
        'spans_ms': {a + '_to_' + b: (end-start)/1000
                     for a, b, start, end in zip(causal_names, causal_names[1:], causal, causal[1:])},
        # Dispatch can enqueue work handled by another task before returning.
        'dispatch_duration_ms': {
            'relay': (clock(relay_return)-clock(relay_enter))/1000,
            'destination': (clock(destination_return)-clock(destination_enter))/1000,
        },
    }


def analyze(directory):
    result = analyze_session(directory)
    path = directory/'native.log'
    with path.open() as stream:
        if any('delivery.opaque_trace_limit ' in line for line in stream):
            raise ValueError('Opaque Forward trace was truncated')
    sdk = result['sdk']
    identity = sdk['epoch'], sdk['cell_sequence']
    packet = result['native']['packet']
    key = packet['ssrc'], packet['rtp_sequence'], packet['rtp_timestamp'], packet['ingress']['payload_bytes']
    endpoint = [row for owner in (result['native']['source'], result['native']['receiver'])
                for row in records(directory/f'worker-{owner}/native.log', 'media.rtp.cell ')
                if cell(row) == identity and
                tuple(int(row[name]) for name in ('ssrc', 'rtp_seq', 'timestamp', 'payload_bytes')) == key and
                int(row['index']) == sdk['rtp_index_in_cell']]
    result['forward_path'] = attribute(sdk, endpoint, records(path, 'delivery.opaque_trace '))
    result['limits'] += [
        'One-relay path only; complete authenticated endpoint witnesses required',
        'Hop spans include transport queues, socket/shaper/scheduling and receive processing',
        'Transport selection precedes acceptance; it is not proof of NIC send',
        'Forward observations hash opaque payloads without RTP/role classification',
        'Dispatch returns are asynchronous post-completion observations and are not causal handoff points',
    ]
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    print(json.dumps(analyze(parser.parse_args().directory), indent=2))
