#!/usr/bin/env python3
"""Export numeric diagnostics from one process per log; omit IDs and raw text."""
import argparse
import json
import math
import re


FIELDS = (
    'blocked_age', 'wb_total', 'inflight', 'cwnd', 'rwnd', 'pending', 'segs',
    'consec_rto', 'read_buf', 'oo', 'oo_bytes', 'srtt', 'rttvar', 'rto',
    'reo_wnd', 'rack_rtt', 'rto_skipped_sacked', 'sack_rto_refreshes',
)
HEADER = re.compile(r'onion-stream-driver\[(\d{1,10})\]:\s+now=(\d{1,18})\b')
MAX_STREAMS = 4096


def analyze_driver(lines):
    streams = {}
    maxima = {key: None for key in FIELDS}
    omitted = samples = zero_windows = small_flight_rtos = duplex_small_rtos = 0
    small_pending_rtos = 0
    for line in lines:
        match = HEADER.search(line)
        if not match or int(match[1]) > 0xffffffff:
            continue
        key, at = match[1], int(match[2])
        if key not in streams:
            if len(streams) >= MAX_STREAMS:
                omitted += 1
                continue
            streams[key] = {'first': at, 'last': at, 'ooo': False, 'rto': False}
        stream = streams[key]
        stream['first'] = min(stream['first'], at)
        stream['last'] = max(stream['last'], at)
        body = line[match.end():]
        values = {}
        for field in FIELDS:
            found = re.search(r'\b' + field + r'=(?:Some\((\d{1,18})\)|(\d{1,18})(?:ms)?\b)', body)
            if found is None:
                continue  # Unknown/missing is not a zero measurement.
            value = int(found[1] or found[2])
            values[field] = value
            maxima[field] = max(maxima[field] or 0, value)
            if field == 'oo' and value:
                stream['ooo'] = True
            if field == 'consec_rto' and value:
                stream['rto'] = True
        if re.search(r'\bphase=Established\b', body):
            zero_windows += values.get('rwnd') == 0
            small = (0 < values.get('inflight', 0) <= 64
                     and values.get('consec_rto', 0) > 0)
            small_flight_rtos += small
            duplex_small_rtos += small and (
                values.get('read_buf', 0) > 0 or values.get('oo_bytes', 0) > 0)
            # RTO rewind may put a short tail back in pending before the next
            # handoff. This is a snapshot, not proof it stayed idle throughout
            # the interval, or that the file was already complete.
            small_pending_rtos += (values.get('inflight') == 0
                                   and 0 < values.get('pending', 0) <= 64
                                   and values.get('consec_rto', 0) > 0)
        samples += 1
    return {
        'driver_samples': samples,
        'streams_observed': len(streams),
        'omitted_summaries_at_stream_cap': omitted,
        'longest_observed_stream_span_ms': max(
            (s['last'] - s['first'] for s in streams.values()), default=None),
        'streams_with_out_of_order_data': sum(s['ooo'] for s in streams.values()),
        'streams_with_rto_events': sum(s['rto'] for s in streams.values()),
        'established_zero_window_samples': zero_windows,
        'small_flight_rto_samples': small_flight_rtos,
        'small_flight_rto_with_buffered_incoming_data_samples': duplex_small_rtos,
        'small_pending_rto_samples': small_pending_rtos,
        'observed_maxima': maxima,
        'samples_are_not_packet_loss_attribution': True,
    }


def analyze_progress(rows):
    previous_time = previous_bytes = last_progress = 0
    first = None
    gaps = []
    regressions = samples = 0
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError('invalid progress record')
        at, written = row.get('seconds'), row.get('written')
        if (type(at) not in (int, float) or not math.isfinite(at)
                or at < previous_time or type(written) is not int or written < 0):
            raise ValueError('invalid progress measurement')
        if written < previous_bytes:
            # File promotion and retry observations can regress. Do not count a
            # return to the old high-water as new progress or silently lose it.
            regressions += 1
        if written > previous_bytes:
            if first is None:
                first = at
            else:
                gaps.append(at - last_progress)
            last_progress = at
            previous_bytes = written
        previous_time = at
        samples += 1
    return {
        'samples': samples,
        'first_observed_progress_seconds': first,
        'max_gap_after_first_progress_seconds': max(gaps, default=None),
        'trailing_no_progress_seconds': previous_time - last_progress,
        'observed_high_water_bytes': previous_bytes,
        'regressive_observations': regressions,
        'file_completion_and_hash_not_proven_by_progress': True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--endpoint-log', action='append', default=[])
    parser.add_argument('--progress', action='append', default=[])
    args = parser.parse_args()
    try:
        endpoints = []
        for name in args.endpoint_log:
            with open(name, encoding='utf-8', errors='replace') as stream:
                endpoints.append(analyze_driver(stream))
        progress = []
        for name in args.progress:
            with open(name, encoding='utf-8') as stream:
                progress.append(analyze_progress(json.load(stream)))
    except (OSError, ValueError, TypeError, OverflowError):
        parser.error('cannot analyze input; raw errors and paths are omitted')
    print(json.dumps({'schema_version': 1, 'endpoints': endpoints, 'progress': progress}, indent=2))


if __name__ == '__main__':
    main()
