#!/usr/bin/env python3
"""Audit eventual video delivery in an owned same-host metadata capture.

Keep every retransmission: the last retry must not replace the original send
when deciding whether a packet belongs to shutdown. This is not a decoder
quality, timely-delivery or network-loss measurement.
"""
import argparse
from collections import defaultdict
import json
from pathlib import Path

from analyze_video_loss import read_trace


def audit(rows, start_us, duration_seconds, tail_seconds=3):
    if duration_seconds <= tail_seconds or tail_seconds < 0:
        raise ValueError('Invalid capture/tail duration')
    end_us = start_us + duration_seconds * 1_000_000
    tail_us = end_us - tail_seconds * 1_000_000
    attempts = defaultdict(list)
    received, delivered = set(), set()
    for row in rows:
        key = tuple(row[k] for k in ('ssrc', 'seq', 'timestamp', 'payload'))
        if row['stage'] == 's':
            attempts[key].append(row)
        elif row['stage'] == 'r':
            received.add(key)
        elif row['stage'] == 'd':
            delivered.add(key)
        else:
            raise ValueError('Unknown native RTP stage')
    missing = []
    successful = set()
    for key, copies in attempts.items():
        accepted = sorted((r for r in copies if r['result'] == 0),
                          key=lambda r: r['at_us'])
        if not accepted:
            continue
        successful.add(key)
        if key in received:
            continue
        first = accepted[0]['at_us']
        scope = ('before_capture' if first < start_us else
                 'after_capture_end' if first >= end_us else
                 'tail_censored' if first >= tail_us else 'in_call')
        missing.append(dict(ssrc=key[0], sequence=key[1], timestamp=key[2],
                            payload_bytes=key[3], scope=scope,
                            first_accepted_seconds=(first-start_us)/1_000_000,
                            last_accepted_seconds=(accepted[-1]['at_us']-start_us)/1_000_000,
                            accepted_attempts=len(accepted)))
    def count(scope, payload):
        return sum(r['scope'] == scope and (r['payload_bytes'] > 0) == payload
                   for r in missing)
    return dict(successful_unique_packets=len(successful),
                successful_not_observed_at_ingress=len(missing),
                received_not_delivered=len(received-delivered),
                in_call_missing_payload=count('in_call', True),
                in_call_missing_padding=count('in_call', False),
                tail_seconds=tail_seconds,
                missing=sorted(missing, key=lambda r: r['first_accepted_seconds']),
                limitations=[
                    'Requires explicitly asserted common monotonic host clock.',
                    'Ingress is eventual, not necessarily timely or decodable.',
                    'Tail and after-end packets are not evidence of in-call loss.',
                    'No missing native row by itself attributes a network or queue drop.',
                ])


def analyze(directory, same_host_monotonic=False):
    if not same_host_monotonic:
        raise ValueError('Must explicitly establish a shared monotonic clock')
    summary = json.loads((directory/'summary.json').read_text())
    native = read_trace(directory/'native.log')  # Refuses incomplete recorders.
    return audit(native['rtp'], summary['stand_clock_observations'][0]['monotonic_us'],
                 summary['duration_seconds'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--same-host-monotonic', action='store_true')
    args = parser.parse_args()
    print(json.dumps(analyze(args.directory, args.same_host_monotonic), indent=2))
