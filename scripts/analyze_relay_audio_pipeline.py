#!/usr/bin/env python3
"""Join owned synthetic PCM, encoder and RTP clocks without guessing offsets.

The packet covering a source input transition is identified by encoder input
index and the sender's actual timestamp offset. Its ingress-to-PCM span can
also include a following packet required by codec lookahead/FEC, alongside
jitter buffering and rendering; it is not NetEq alone. Missing/ambiguous
witnesses cannot qualify an unobserved stage.
"""
import argparse
import collections
import json
from pathlib import Path
import re

from analyze_relay_rtp_timing import distribution
from pcm_timing import input_edges


def fields(line):
    return {k: int(v) for k, v in re.findall(r'(\w+)=(-?\d+)', line)}


def analyze(summary, lines, pcm):
    if summary.get('loopback_only') is not True:
        raise ValueError('Requires an owned same-process fixture')
    start = summary['stand_start_monotonic_us']
    duration = summary['duration_seconds']
    anchors, encoders, encoded, sends, received = {}, {}, {}, {}, {}
    send_ssrc = receive_ssrc = None
    limits, counts = [], []
    for line in lines:
        if 'audio.rtp.anchor ' in line:
            row = fields(line)
            if row['source'] not in (0, 1) or not 0 <= row['offset'] < 2**32:
                raise ValueError('Invalid fixture anchor')
            if row['ssrc'] in anchors or any(a['source'] == row['source'] for a in anchors.values()):
                raise ValueError('Ambiguous fixture anchor')
            anchors[row['ssrc']] = row
        elif 'audio.encode.begin ' in line:
            row = fields(line)
            if row['ssrc'] in encoders or not 1 <= row['limit'] <= 32768:
                raise ValueError('Ambiguous encoder or invalid capacity')
            if row['rtp_hz'] <= 0 or row['rtp_hz'] % 100:
                raise ValueError('Invalid encoder RTP rate')
            encoders[row['ssrc']] = row
            encoded[row['ssrc']] = []
        elif 'audio.encode ssrc=' in line:
            row = fields(line)
            if row['ssrc'] not in encoded:
                raise ValueError('Encoder row without header')
            encoded[row['ssrc']].append(row)
        elif 'audio.rtp.send.begin ' in line:
            row = fields(line)
            send_ssrc = row['ssrc']
            limits.append(row['limit'])
            counts.append(row['count'])
        elif 'audio.rtp.send seq=' in line:
            row = fields(line)
            key = (send_ssrc, row['seq'], row['timestamp'])
            if send_ssrc is None or key in sends:
                raise ValueError('Ambiguous RTP send row')
            sends[key] = row
        elif 'audio.rtp.ingress.begin ' in line:
            row = fields(line)
            receive_ssrc = row['ssrc']
            limits.append(row['limit'])
            counts.append(row['count'])
        elif 'audio.rtp.ingress seq=' in line:
            row = fields(line)
            if not row['payload_bytes']:
                continue
            key = (receive_ssrc, row['seq'], row['timestamp'])
            if receive_ssrc is None or key in received:
                raise ValueError('Ambiguous RTP receive row')
            received[key] = row
    if not anchors or not encoders:
        raise ValueError('Missing exact encoder/RTP anchors')
    if any(not 1 <= limit <= 32768 for limit in limits):
        raise ValueError('Invalid native trace capacity')
    sources = {}
    captures = {side: {r['source_tick']: r for r in pcm if r['side'] == side}
                for side in (0, 1)}
    for ssrc, meta in encoders.items():
        if ssrc not in anchors or len(encoded[ssrc]) != meta['count']:
            raise ValueError('Missing anchor or incomplete encoder log')
        source = anchors[ssrc]['source']
        capture = captures[source]
        index_verified = (len(capture) == meta['inputs']
                          and sorted(capture) == list(range(meta['inputs'])))
        by_stamp = {}
        previous = None
        for row in encoded[ssrc]:
            if row['timestamp'] in by_stamp:
                raise ValueError('Ambiguous encoded timestamp')
            by_stamp[row['timestamp']] = row
            if row['first_index'] < 0:
                continue
            if not 1 <= row['blocks'] <= 12 or row['first_index'] + row['blocks'] > meta['inputs']:
                raise ValueError('Invalid encoder input interval')
            if row['first_us'] > row['encoded_us']:
                raise ValueError('Invalid encoder clock order')
            if previous is not None:
                delta = row['first_index'] - previous['first_index']
                expected = delta * (meta['rtp_hz'] // 100)
                if delta < previous['blocks'] or (row['timestamp'] - previous['timestamp']) % 2**32 != expected % 2**32:
                    raise ValueError('Encoder input index does not match RTP clock')
            previous = row
        sources[ssrc] = dict(source=source, meta=meta, captures=capture,
                             index_verified=index_verified, by_stamp=by_stamp,
                             delivered={})
    packet_groups = collections.defaultdict(lambda: collections.defaultdict(list))
    unmatched = 0
    for key, arrival in received.items():
        ssrc, _, timestamp = key
        sent = sends.get(key)
        owner = sources.get(ssrc)
        if sent is None or not sent['accepted'] or owner is None:
            unmatched += 1
            continue
        stamp = (timestamp - anchors[ssrc]['offset']) % 2**32
        enc = owner['by_stamp'].get(stamp)
        if enc is None:
            unmatched += 1
            continue
        if stamp in owner['delivered']:
            raise ValueError('Several delivered packets for one encoded timestamp')
        times = [enc['encoded_us'], sent['attempted_us'], sent['admitted_us'],
                 arrival['arrived_us'], arrival['drained_us']]
        if times != sorted(times):
            raise ValueError('Invalid pipeline clock order')
        joined = dict(encode=enc, send=sent, ingress=arrival)
        owner['delivered'][stamp] = joined
        at = (sent['attempted_us'] - start) / 1e6
        if not 5 <= at < duration:
            continue
        phase = 'audio-only' if at < 20 else 'competing'
        group = packet_groups[owner['source'], phase]
        for name, a, b in [('encoded_to_send', times[0], times[1]),
                           ('send_to_sdk', times[1], times[2]),
                           ('sdk_to_ingress', times[2], times[3]),
                           ('ingress_to_webrtc', times[3], times[4])]:
            group[name].append((b - a) / 1000)
        if enc['first_us'] >= 0:
            group['first_encode_input_to_encoded'].append((times[0] - enc['first_us']) / 1000)
    edges_out, missing = [], collections.Counter()
    for ssrc, owner in sources.items():
        source = owner['source']
        if not owner['index_verified']:
            missing['unverified_capture_index_sources'] += 1
            continue
        source_rows = sorted(owner['captures'].values(), key=lambda x: x['source_tick'])
        edges = input_edges(source_rows)
        decoded, last = [], None
        for row in pcm:
            if row['side'] != 1-source:
                continue
            f = 500 if abs(row['freq']-500) < 150 else 1000 if abs(row['freq']-1000) < 150 else None
            if f is not None and row['rms'] >= 500 and f != last:
                decoded.append((row['t'], f))
                last = f
        intervals = [row for row in encoded[ssrc] if row['first_index'] >= 0]
        for i, (at, frequency, tick) in enumerate(edges):
            if not 5 <= at < duration:
                continue
            end = edges[i+1][0] if i+1 < len(edges) else duration
            output = next((t for t, f in decoded if at <= t < end and f == frequency), None)
            packets = [r for r in intervals if r['first_index'] <= tick < r['first_index'] + r['blocks']]
            if output is None or len(packets) != 1:
                missing['unmatched_pcm_or_input_packet'] += 1
                continue
            packet = packets[0]
            joined = owner['delivered'].get(packet['timestamp'])
            if joined is None:
                missing['input_packet_not_observed_at_receiver'] += 1
                continue
            sent, arrival = joined['send'], joined['ingress']
            times = [at*1e6 + start, packet['encoded_us'], sent['attempted_us'],
                     sent['admitted_us'], arrival['arrived_us'], arrival['drained_us'],
                     output*1e6 + start]
            if times != sorted(times):
                missing['pcm_edge_precedes_input_packet'] += 1
                continue
            names = ['capture_to_encoded', 'encoded_to_send', 'send_to_sdk',
                     'sdk_to_ingress', 'ingress_to_webrtc', 'webrtc_to_pcm_edge']
            spans = {name: round((b-a)/1000, 3)
                     for name, a, b in zip(names, times, times[1:])}
            following = next((r for r in intervals if r['first_index'] > packet['first_index']), None)
            following_witness = owner['delivered'].get(following['timestamp']) if following else None
            following_arrival = (following_witness['ingress']['arrived_us']-start)/1e6 if following_witness else None
            edges_out.append(dict(source=source, input_seconds=round(at, 6),
                                  output_seconds=round(output, 6),
                                  total_ms=round((output-at)*1000, 3),
                                  packet_ms=packet['blocks']*10,
                                  input_position_ms=(tick-packet['first_index'])*10,
                                  following_packet_ingress_seconds=following_arrival,
                                  spans_ms=spans))
    return dict(same_process_fixture_only=True,
                exact_sender_offsets_required=True,
                edge_attribution_basis='packet_containing_source_input',
                residual_can_include_following_packet_and_playout=True,
                capture_index_verified={str(v['source']): v['index_verified'] for v in sources.values()},
                native_trace_limit_may_have_been_reached=(any(n >= limit for n, limit in zip(counts, limits))
                    or any(v['meta']['seen'] > v['meta']['count'] for v in sources.values())),
                unmatched_payload_rows=unmatched, unattributed_edges=dict(missing),
                packets=[dict(source=source, phase=phase,
                              spans_ms={name: distribution(values) for name, values in group.items()})
                         for (source, phase), group in sorted(packet_groups.items())],
                attributed_edges=len(edges_out),
                largest_pcm_edges=sorted(edges_out, key=lambda x: x['total_ms'], reverse=True)[:10],
                edges=edges_out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture', type=Path)
    args = parser.parse_args()
    summary = json.loads((args.fixture/'summary.json').read_text())
    pcm = json.loads((args.fixture/'pcm-samples.json').read_text())
    with (args.fixture/'native.log').open() as lines:
        print(json.dumps(analyze(summary, lines, pcm), indent=2))


if __name__ == '__main__':
    main()
