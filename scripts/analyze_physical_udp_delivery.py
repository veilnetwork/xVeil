#!/usr/bin/env python3
"""Summarize endpoint-local QUIC/UDP traces without exporting identifiers.

Only matched opaque datagrams on connections accepting owned primary cells are
scored. Socket-send to peer-kernel includes OS transmit queues and the network;
it does not identify the carrier or NIC. Start/end wall-clock brackets bound
observed offset, assuming no unobserved intermediate clock step. No packet,
connection, cell identifier, address, clock offset or payload leaves this tool.
"""
import argparse
import collections
import json
import math
from pathlib import Path
import re
import statistics


PATH_MAXIMA = (
    'outbox_to_transport_max_us', 'datagram_queue_max_us',
    'datagram_cwnd_blocked_max_age_us', 'datagram_pacing_blocked_max_age_us',
    'event_queue_max_us', 'timer_late_max_us', 'udp_send_wait_max_us',
)


def distribution(values):
    ordered = sorted(values)
    if not ordered:
        return None
    return {'count': len(ordered), 'median_ms': round(statistics.median(ordered), 3),
            'p95_ms': round(ordered[math.ceil(.95 * len(ordered)) - 1], 3),
            'max_ms': round(ordered[-1], 3)}


def parse(lines):
    cells = collections.defaultdict(lambda: collections.defaultdict(list))
    udp = collections.defaultdict(list)
    paths = []
    connections = set()
    for line in lines:
        fields = dict(re.findall(r'(\w+)=([^\s]+)', line))
        if 'media.source_cell_trace ' in line:
            if fields.get('local_slot') != '0':
                continue
            if not re.fullmatch('[0-9a-f]{16}', fields.get('epoch', '')):
                raise ValueError('Invalid local cell header')
            key = fields['epoch'], int(fields['seq'])
            if key[1] <= 0 or int(fields['monotonic_us']) < 0:
                raise ValueError('Invalid local cell clock')
            cells[key][fields['stage']].append(int(fields['monotonic_us']))
            if fields['stage'] == 'datagram_accepted':
                connections.add(int(fields['connection_trace_id']))
        elif 'quic.udp_wire.sample ' in line:
            if fields.get('stage') not in ('send', 'receive'):
                continue
            if not re.fullmatch('[0-9a-f]{16}', fields.get('digest', '')):
                raise ValueError('Invalid UDP correlation header')
            row = {k: int(fields[k]) for k in
                   ('at_ms', 'bytes', 'kernel_recv_ns', 'connection_trace_id')}
            if min(row.values()) < 0 or row['bytes'] == 0:
                raise ValueError('Invalid UDP observation')
            if fields.get('kernel_grouped') not in ('true', 'false'):
                raise ValueError('Unknown UDP grouping')
            row['grouped'] = fields['kernel_grouped'] == 'true'
            udp[fields['stage'], fields['digest']].append(row)
        elif 'datagram_queue_max_us=' in line and 'connection_trace_id=' in line:
            paths.append(fields)
    waits, ambiguous = [], 0
    for stages in cells.values():
        before, after = stages.get('budget_admit', []), stages.get('datagram_accepted', [])
        if len(before) > 1 or len(after) > 1:
            ambiguous += 1
        elif before and after:
            if after[0] < before[0]:
                raise ValueError('Local queue clocks contradict')
            waits.append((after[0] - before[0]) / 1000)
    # These are connection lifetime maxima, not per-packet latency samples.
    maxima = {}
    for key in PATH_MAXIMA:
        values = [int(row[key]) / 1000 for row in paths if key in row and
                  int(row['connection_trace_id']) in connections and int(row[key]) >= 0]
        maxima[key.removesuffix('_us') + '_ms'] = max(values) if values else None
    return {'udp': udp, 'connections': connections,
            'public': {'owned_primary_connections': len(connections),
                       'ambiguous_local_cells_skipped': ambiguous,
                       'budget_to_quic_acceptance_ms': distribution(waits),
                       'connection_lifetime_maxima_ms': {
                           k: round(v, 3) if v is not None else None
                           for k, v in maxima.items()}}}


def analyze(first_lines, second_lines, clock_brackets):
    """Second endpoint wall clock is translated to the first host's clock."""
    if len(clock_brackets) < 2:
        raise ValueError('Capture requires start and end wall-clock brackets')
    for row in clock_brackets:
        if (type(row.get('low_ns')) is not int or type(row.get('high_ns')) is not int
                or row['low_ns'] > row['high_ns']):
            raise ValueError('Invalid clock bracket')
    low = min(row['low_ns'] for row in clock_brackets)
    high = max(row['high_ns'] for row in clock_brackets)
    capture_window = None
    if any('at_host_ns' in row for row in clock_brackets):
        if any(type(row.get('at_host_ns')) is not int for row in clock_brackets):
            raise ValueError('Incomplete capture clock interval')
        start, end = clock_brackets[0]['at_host_ns'], clock_brackets[-1]['at_host_ns']
        if start >= end:
            raise ValueError('Capture clock interval is reversed')
        capture_window = start, end
    endpoints = [parse(first_lines), parse(second_lines)]
    result = {'scope': 'Opaque direct UDP on owned primary-source connections; not audio-only.',
              'local_acceptance_is_not_socket_transmission': True,
              'unmatched_samples_are_not_packet_loss_proof': True,
              'wall_offset_envelope_width_ms': round((high - low) / 1e6, 3),
              'clock_assumption': 'No unobserved wall-clock step outside start/end brackets.',
              'endpoints': [e['public'] for e in endpoints], 'directions': []}
    for source, destination in ((0, 1), (1, 0)):
        sent, received = endpoints[source], endpoints[destination]
        lower, upper, polling = [], [], []
        matched = ambiguous = unavailable = grouped = unmatched = outside = 0
        for (stage, digest), candidates in sent['udp'].items():
            if stage != 'send':
                continue
            if not any(r['connection_trace_id'] in sent['connections'] for r in candidates):
                continue
            peers = received['udp'].get(('receive', digest), [])
            if len(candidates) > 1 or len(peers) > 1:
                ambiguous += 1
                continue
            if not peers:
                unmatched += 1
                continue
            a, b = candidates[0], peers[0]
            if a['bytes'] != b['bytes']:
                raise ValueError('Matched UDP lengths contradict')
            matched += 1
            if not b['kernel_recv_ns']:
                unavailable += 1
                continue
            if b['grouped']:
                grouped += 1
                continue
            # at_ms truncates SystemTime. Keep an interval, not invented
            # sub-millisecond precision or a zero-clamped negative delay.
            send_ns, kernel_ns = a['at_ms'] * 1_000_000, b['kernel_recv_ns']
            if capture_window is not None:
                # Retain only timestamps whose entire host-clock uncertainty
                # interval lies between the calibration observations. Startup
                # and teardown datagrams cannot borrow an unobserved offset.
                send_low = send_ns + (low if source == 1 else 0)
                send_high = send_ns + 999_999 + (high if source == 1 else 0)
                receive_low = kernel_ns + (low if destination == 1 else 0)
                receive_high = kernel_ns + (high if destination == 1 else 0)
                if (min(send_low, receive_low) < capture_window[0] or
                        max(send_high, receive_high) > capture_window[1]):
                    outside += 1
                    continue
            offset_low, offset_high = (low, high) if source == 0 else (-high, -low)
            lo = (kernel_ns - send_ns - 1_000_000 + offset_low) / 1e6
            hi = (kernel_ns - send_ns + offset_high) / 1e6
            poll_upper = (b['at_ms'] * 1_000_000 + 999_999 - kernel_ns) / 1e6
            if hi < 0 or poll_upper < 0:
                raise ValueError('UDP clock order contradicts calibration')
            lower.append(lo)
            upper.append(hi)
            polling.append(poll_upper)
        result['directions'].append({
            'source_endpoint': source, 'matched_datagrams': matched,
            'unmatched_send_samples': unmatched, 'ambiguous_samples_skipped': ambiguous,
            'kernel_timestamp_unavailable': unavailable, 'grouped_samples_skipped': grouped,
            'outside_calibrated_interval_skipped': outside,
            'socket_to_peer_kernel_lower_bounds_ms': distribution(lower),
            'socket_to_peer_kernel_upper_bounds_ms': distribution(upper),
            'peer_kernel_to_poll_upper_bounds_ms': distribution(polling)})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    args = parser.parse_args()
    try:
        meta = json.loads((args.capture / 'result.json').read_text())
        brackets = [meta['phone_wall_calibration_start'], meta['phone_wall_calibration_end']]
        with (args.capture / 'mac-runtime.log').open() as first, \
                (args.capture / 'phone-logcat.log').open() as second:
            print(json.dumps(analyze(first, second, brackets), indent=2))
    except (ValueError, KeyError, OSError):
        raise SystemExit('Capture is missing or cannot substantiate UDP timing; no report emitted.')


if __name__ == '__main__':
    main()
