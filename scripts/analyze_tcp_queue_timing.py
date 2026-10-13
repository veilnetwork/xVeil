#!/usr/bin/env python3
"""Same-host TCP queue snapshots; no role, address or connection ID is emitted."""
import argparse
import collections
import json
import re
from pathlib import Path


def analyze(summary, lines, lower=20, upper=None):
    if summary.get('loopback_only') is not True:
        raise ValueError('Requires an owned same-process loopback stand')
    upper = summary['duration_seconds'] if upper is None else upper
    if not 0 <= lower < upper <= summary['duration_seconds']:
        raise ValueError('Invalid recorded-time window')
    start = summary['stand_start_monotonic_us']
    rows = collections.defaultdict(list)
    legacy = unknown = foreign = failed = 0
    for line in lines:
        if 'transport.tcp_trace.kernel_progress' not in line:
            continue
        fields = dict(re.findall(r'(\w+)=([^\s]+)', line))
        stamp = fields.get('monotonic_us')
        if stamp is None:
            legacy += 1
            continue
        if not stamp.isdigit():
            unknown += 1
            continue
        at = (int(stamp) - start) / 1e6
        if not -60 <= at <= summary['duration_seconds'] + 60:
            foreign += 1
            continue
        if not fields.get('connection', '').isdigit():
            raise ValueError('Missing process-local connection witness')
        if 'kernel_now=Ok(KernelSnapshot {' not in line:
            failed += 1
            continue
        values = {}
        # Read CURRENT snapshot fields, not the cumulative high-water fields
        # printed earlier on the same line. Unsupported kernel fields stay None.
        snapshot = line.split('kernel_now=Ok(KernelSnapshot {', 1)[1]
        for name in ['rtt_us', 'rto_us', 'cwnd_bytes', 'send_buffer_bytes',
                     'queued_bytes', 'notsent_bytes', 'retransmitted_bytes']:
            m = re.search(r'\b' + name + r': (None|Some\((\d+)\)|(\d+))', snapshot)
            values[name] = int(m[2] or m[3]) if m and m[1] != 'None' else None
        rows[int(fields['connection'])].append((at, values))

    selected = [(at, values) for samples in rows.values() for at, values in samples
                if lower <= at < upper]
    maxima = {}
    for name in ['rtt_us', 'rto_us', 'cwnd_bytes', 'send_buffer_bytes', 'queued_bytes', 'notsent_bytes']:
        known = [v[name] for _, v in selected if v[name] is not None]
        maxima[name] = {'known_samples': len(known), 'max': max(known) if known else None}
    deltas = []
    unknown_delta = resets = connections = 0
    for samples in rows.values():
        samples.sort(key=lambda row: row[0])
        within = [row for row in samples if lower <= row[0] < upper]
        if not within:
            continue
        connections += 1
        before = [row for row in samples if row[0] < lower]
        a = before[-1][1]['retransmitted_bytes'] if before else None
        b = within[-1][1]['retransmitted_bytes']
        if a is None or b is None:
            unknown_delta += 1
        elif b < a:
            resets += 1
        else:
            deltas.append(b - a)
    return {
        'same_process_fixture_only': True, 'snapshots_are_not_per_packet_attribution': True,
        'generic_connections_no_media_classification': True,
        'synthetic_video_source': summary.get('synthetic_video_source'),
        'window_seconds': [lower, upper], 'legacy_untimed_rows': legacy,
        'unknown_clock_rows': unknown, 'foreign_clock_rows': foreign,
        'failed_kernel_snapshots': failed, 'timed_snapshots': sum(map(len, rows.values())),
        'window_snapshots': len(selected), 'window_connections': connections,
        'current_snapshot_maxima': maxima,
        'retransmitted_bytes_observed_deltas': {
            'known_connections': len(deltas), 'unknown_connections': unknown_delta,
            'counter_resets': resets, 'sum': sum(deltas) if deltas else None,
            'max_connection': max(deltas) if deltas else None,
            'span_includes_gap_since_last_pre_window_sample': True,
        },
    }


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('fixture', type=Path)
    p.add_argument('--from-seconds', type=float, default=20)
    p.add_argument('--to-seconds', type=float)
    args = p.parse_args()
    summary = json.loads((args.fixture / 'summary.json').read_text())
    with (args.fixture / 'runtime.log').open() as log:
        print(json.dumps(analyze(summary, log, args.from_seconds, args.to_seconds), indent=2))


if __name__ == '__main__':
    main()
