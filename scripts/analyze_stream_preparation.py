#!/usr/bin/env python3
"""Export numeric preparation/mux observations from one process per input log."""
import argparse
import json
import re
import statistics

MAX_SCOPES = 4096
MAX_SAMPLES = 4096
MUX_FIELDS = ('received', 'routed', 'inbox_full', 'inbox_full_data',
              'inbox_full_ack', 'inbox_full_control', 'inbox_closed',
              'unknown', 'invalid', 'accept_full', 'accepted')
STAGES = ('receiver_ads', 'relay_directory', 'directory_warm_lock',
          'directory_warm', 'circuit_open')
HEADER = re.compile(r'onion-stream-mux\[(\d{1,10})\]:')


def analyze(lines):
    muxes = {}
    stages = {}
    outbound = {k: [] for k in ('resolve_ms', 'circuit_open_ms', 'confirm_ms', 'publish_ms')}
    omitted = 0

    def record(table, key, elapsed):
        nonlocal omitted
        values = table.setdefault(key, [])
        if len(values) < MAX_SAMPLES:
            values.append(elapsed)
        else:
            omitted += 1

    for line in lines:
        if 'onion-stream-mux[' in line and (match := HEADER.search(line)):
            if int(match[1]) > 0xffffffff:
                continue
            if match[1] not in muxes and len(muxes) >= MAX_SCOPES:
                omitted += 1
                continue
            held = muxes.setdefault(match[1], {})
            for key in MUX_FIELDS:
                found = re.search(r'\b' + key + r'=(\d{1,20})\b', line[match.end():])
                if found and int(found[1]) <= 0xffffffffffffffff:
                    held[key] = max(held.get(key, 0), int(found[1]))
        if 'onion-stream.stage' in line:
            found = re.search(r'\bstage=([a-z_]+) elapsed_ms=(\d{1,20}) result=([012]) local=([01]) address_kind=([012]) count=\d{1,20}\b', line)
            if found and found[1] in STAGES and int(found[2]) <= 0xffffffffffffffff:
                # Group by fixed, nonidentifying categories. Raw identifiers,
                # timestamps, file names and unknown text never become keys.
                key = f'{found[1]}/result{found[3]}/local{found[4]}/address{found[5]}'
                record(stages, key, int(found[2]))
        if ('outbound stream rendezvous filter for ' in line
                or 'outbound circuit ready for ' in line):
            for key in outbound:
                found = re.search(r'\b' + key + r'=(\d{1,20})\b', line)
                if found and int(found[1]) <= 0xffffffffffffffff:
                    record(outbound, key, int(found[1]))

    def summary(values):
        return {'samples': len(values), 'median_ms': statistics.median(values) if values else None,
                'max_ms': max(values, default=None)}

    return {
        'mux_scopes_observed': len(muxes),
        'mux_totals': {key: sum(m[key] for m in muxes.values() if key in m)
                       if any(key in m for m in muxes.values()) else None for key in MUX_FIELDS},
        'preparation_stages': {key: summary(value) for key, value in sorted(stages.items())},
        'outbound_preparation': {key: summary(value) for key, value in outbound.items()},
        'omitted_at_observation_cap': omitted,
        'observed_snapshots_not_complete_packet_loss_accounting': True,
        'stage_durations_overlap_and_must_not_be_added': True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', action='append', required=True)
    args = parser.parse_args()
    results = []
    try:
        for name in args.log:
            with open(name, encoding='utf-8', errors='replace') as stream:
                results.append(analyze(stream))
    except (OSError, ValueError, TypeError, OverflowError):
        parser.error('cannot analyze input; raw errors and paths are omitted')
    print(json.dumps({'schema_version': 1, 'endpoints': results}, indent=2))


if __name__ == '__main__':
    main()
