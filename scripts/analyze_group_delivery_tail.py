#!/usr/bin/env python3
"""Partition an owned audio delivery peak using authenticated opaque hop joins.

Requires opt-in forwarding observations. Missing transport witnesses fail rather
than turning an unexplained span into network propagation or relay processing.
"""
import argparse
import hashlib
import json
from pathlib import Path

from analyze_group_sdk_packet import analyze as analyze_sdk, cell, records
from analyze_group_source_session import attribute as attribute_source
from analyze_group_audio_peak import trace_sections


def delivered_packets(encoded, sends, ingress, *, offset, channel, origin, duration,
                      start_seconds=5):
    """Match actual fanout channels, RTP stamps and lengths, never tone phase."""
    if not isinstance(offset, int) or not 0 <= offset < 2**32:
        raise ValueError('Invalid sender RTP origin')
    by_stamp, by_send = {}, {}
    for _, row in ingress:
        if not row['payload_bytes']:
            continue  # Padding is not another encoded speech packet.
        if row['timestamp'] in by_stamp:
            raise ValueError('Ambiguous received RTP timestamp')
        by_stamp[row['timestamp']] = row
    for _, row in sends:
        if row['channel'] != channel:
            continue
        key = row['seq'], row['timestamp']
        if key in by_send:
            raise ValueError('Ambiguous native fanout send')
        by_send[key] = row
    result, missing, stamps = [], 0, set()
    for meta, enc in encoded:
        if enc['ssrc'] != meta['ssrc'] or not 1 <= enc['blocks'] <= 12:
            raise ValueError('Invalid encoder record')
        if enc['first_us'] < 0 or not start_seconds <= enc['first_us']/1e6-origin < duration:
            continue
        stamp = (enc['timestamp'] + offset) % 2**32
        if stamp in stamps:
            raise ValueError('Ambiguous encoded RTP timestamp')
        stamps.add(stamp)
        received = by_stamp.get(stamp)
        if received is None:
            missing += 1
            continue
        send = by_send.get((received['seq'], stamp))
        if (send is None or send['accepted'] != 1 or
                send['packet_bytes'] < enc['bytes'] + 12 or
                received['payload_bytes'] != enc['bytes']):
            raise ValueError('Missing or contradictory native packet witness')
        if not (enc['first_us'] <= enc['encoded_us'] <= send['attempted_us'] <=
                send['admitted_us'] <= received['arrived_us'] <= received['drained_us']):
            raise ValueError('Invalid native packet clock order')
        result.append(dict(ssrc=meta['ssrc'], rtp_origin=offset,
                           rtp_timestamp=stamp, rtp_sequence=received['seq'],
                           encoder_first_input_seconds=enc['first_us']/1e6-origin,
                           packet_ms=enc['blocks']*10,
                           encoded_monotonic_us=enc['encoded_us'],
                           native_send=send, ingress=received,
                           encoded_to_ingress_ms=(received['arrived_us']-enc['encoded_us'])/1000))
    if not result:
        raise ValueError('Missing delivered packet witnesses')
    return result, missing


def select_delivery_peak(directory, *, start_seconds=5, end_seconds=None):
    inputs = {}

    def read(name):
        data = (directory/name).read_bytes()
        inputs[name] = hashlib.sha256(data).hexdigest()
        return data.decode()

    summary = json.loads(read('summary.json'))
    if summary.get('separate_sdk_processes') is not True:
        raise ValueError('Requires owned same-host worker processes')
    end_seconds = summary['duration_seconds'] if end_seconds is None else end_seconds
    if not 0 <= start_seconds < end_seconds <= summary['duration_seconds']:
        raise ValueError('Invalid packet analysis window')
    lines = {i: read(f'worker-{i}/playout-trace.log').splitlines() for i in range(3)}
    candidates, paths = [], []
    for source in range(3):
        worker = json.loads(read(f'worker-{source}/summary.json'))
        if worker['origin_monotonic'] != summary['origin_monotonic']:
            raise ValueError('Different fixture origins')
        codec = json.loads(read(f'worker-{source}/codec-samples.json'))
        offsets = {r['sender']['rtp_origin'] for r in codec}
        encoded = trace_sections(lines[source], 'audio.encode.begin', 'audio.encode')
        ssrcs = {meta['ssrc'] for meta, _ in encoded}
        if len(offsets) != 1 or len(ssrcs) != 1:
            raise ValueError('Missing or changing source RTP clock')
        offset, ssrc = offsets.pop(), ssrcs.pop()
        sends = trace_sections(lines[source], 'audio.group.send.begin', 'audio.group.send', ssrc)
        for receiver in range(3):
            if source == receiver:
                continue
            channels = [r['channel_handle'] for r in worker['channel_stats_after_capture']
                        if r['participant_pair'] == [source, receiver]]
            if len(channels) != 1:
                raise ValueError('Missing or ambiguous participant channel')
            ingress = trace_sections(lines[receiver], 'audio.rtp.ingress.begin',
                                     'audio.rtp.ingress', ssrc)
            packets, missing = delivered_packets(encoded, sends, ingress,
                offset=offset, channel=channels[0], origin=summary['origin_monotonic'],
                duration=end_seconds, start_seconds=start_seconds)
            ordered = sorted(packets, key=lambda p: p['encoded_to_ingress_ms'])
            peak = ordered[-1]
            candidates.append(dict(source=source, receiver=receiver, packet=peak))
            paths.append(dict(source=source, receiver=receiver, delivered=len(packets),
                missing=missing, max_ms=peak['encoded_to_ingress_ms'],
                p50_ms=ordered[(len(ordered)-1)//2]['encoded_to_ingress_ms'],
                p99_ms=ordered[int((len(ordered)-1)*.99)]['encoded_to_ingress_ms']))
    result = max(candidates, key=lambda p: p['packet']['encoded_to_ingress_ms'])
    result.update(selection_metric='largest_observed_encoded_to_ingress',
                  analysis_window_seconds=[start_seconds, end_seconds],
                  paths=paths, input_sha256=inputs)
    return result


def partition(packet, sdk, source):
    identity = (sdk['epoch'], sdk['cell_sequence'])
    if identity != (source['epoch'], source['cell_sequence']):
        raise ValueError('Different source-session cell')
    route = sdk.get('opaque_route')
    if not route or not route.get('hops'):
        raise ValueError('Missing authenticated opaque route')
    hops = route['hops']
    if (hops[0]['source'] != sdk['receiver_sdk_peer'] or
            hops[-1]['receiver'] != sdk['source_sdk_peer']):
        raise ValueError('Different route endpoints')
    observations = sdk['observations_us']
    accepted = source['observations_us']['datagram_accepted']
    budget = source['observations_us']['budget_admit']
    encoded = packet['encoded_monotonic_us']
    attempted = packet['native_send']['attempted_us']
    ingress = packet['ingress']['arrived_us']
    if not (encoded <= attempted <= observations['sdk_seal'] <=
            observations['sdk_send_pump'] <= observations['daemon_read'] <=
            observations['handler_enter'] <= budget <=
            hops[0]['selected_us'] <= accepted <= hops[0]['dispatched_us']):
        raise ValueError('Missing causal source transport clocks')
    if not hops[-1]['dispatched_us'] <= observations['sdk_authenticated'] <= ingress:
        raise ValueError('Invalid receiver clocks')
    stages = []

    def add(name, start, end, **metadata):
        if end < start:
            raise ValueError('Reversed stage clocks: ' + name)
        stages.append(dict(stage=name, start_us=start, end_us=end,
                           duration_ms=(end-start)/1000, **metadata))

    add('encoded_to_native_submission', encoded, attempted)
    add('sender_submission_to_transport_acceptance', attempted, accepted)
    previous = accepted
    visited = {hops[0]['source']}
    for index, hop in enumerate(hops):
        if index:
            prior = hops[index-1]
            if hop['source'] != prior['receiver'] or hop['source'] in visited:
                raise ValueError('Disconnected or cyclic route')
            visited.add(hop['source'])
            add('relay_dispatch_to_transport_selection', previous,
                hop['selected_us'], node=hop['source'])
            previous = hop['selected_us']
        if hop['receiver'] in visited:
            raise ValueError('Cyclic route')
        add('transport_to_next_dispatch', previous, hop['dispatched_us'],
            source=hop['source'], receiver=hop['receiver'],
            start_observation='datagram_accepted' if index == 0
                              else 'transport_selected')
        previous = hop['dispatched_us']
    add('receiver_dispatch_to_authenticated_sdk', previous,
        observations['sdk_authenticated'])
    add('authenticated_sdk_to_native_ingress', observations['sdk_authenticated'], ingress)
    duration_us = ingress - encoded
    if sum(row['end_us']-row['start_us'] for row in stages) != duration_us:
        raise ValueError('Incomplete delivery partition')
    return dict(epoch=identity[0], cell_sequence=identity[1], stages=stages,
                encoded_to_ingress_ms=duration_us/1000,
                transport_and_link_ms=sum(r['duration_ms'] for r in stages
                                         if r['stage'] == 'transport_to_next_dispatch'),
                relay_dispatch_to_selection_ms=sum(r['duration_ms'] for r in stages
                    if r['stage'] == 'relay_dispatch_to_transport_selection'))


def analyze(directory, *, selection='delivery', start_seconds=5, end_seconds=None):
    if selection == 'decoded' and (start_seconds != 5 or end_seconds is not None):
        raise ValueError('Packet analysis windows require delivery selection')
    native = select_delivery_peak(directory, start_seconds=start_seconds,
                                 end_seconds=end_seconds) if selection == 'delivery' else None
    result = analyze_sdk(directory, native=native)
    identity = (result['sdk']['epoch'], result['sdk']['cell_sequence'])
    path = directory / 'native.log'
    rows = (row for row in records(path, 'media.source_cell_trace ')
            if cell(row) == identity)
    source = attribute_source(result['sdk'], rows)
    decomposition = partition(result['native']['packet'], result['sdk'], source)
    result.update(source_session=source, delivery_partition=decomposition)
    result['summary_sha256'] = hashlib.sha256((directory/'summary.json').read_bytes()).hexdigest()
    result['limits'] += [
        'First transport span starts after local DATAGRAM acceptance, not at NIC send',
        'Transport-to-dispatch includes QUIC queues, service, network and receiver work',
        'Relay dispatch-to-selection includes local forwarding and outbound admission',
        'All stages are the same authenticated cell; no adjacent UDP packet is inferred',
        'The original capture verdict is preserved; diagnostics do not qualify a failed run',
    ]
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--selection', choices=['delivery', 'decoded'], default='delivery')
    parser.add_argument('--from-seconds', type=float, default=5)
    parser.add_argument('--until-seconds', type=float)
    args = parser.parse_args()
    print(json.dumps(analyze(args.directory, selection=args.selection,
                            start_seconds=args.from_seconds,
                            end_seconds=args.until_seconds), indent=2))
