#!/usr/bin/env python3
"""Attribute a native video RTP attempt to its SDK seal and local source decision."""
import argparse
import json
from pathlib import Path
import re

from analyze_video_loss import read_trace


def records(path, marker):
    with Path(path).open() as stream:
        for line in stream:
            if marker in line:
                yield dict(re.findall(r'(\w+)=([^\s]+)', line.split(marker, 1)[1]))


def attribute(attempts, seals, decisions):
    attempts = sorted(attempts, key=lambda r: r['at_us'])
    if not attempts or attempts[0]['result'] != 0:
        raise ValueError('First native attempt did not enter the SDK')
    first = attempts[0]
    key = first['ssrc'], first['seq'], first['timestamp'], first['payload']
    if any((r['ssrc'], r['seq'], r['timestamp'], r['payload']) != key for r in attempts):
        raise ValueError('Ambiguous native packet identity')
    next_at = attempts[1]['at_us'] if len(attempts) > 1 else None
    seals = [r for r in seals if r['stage'] == 'sealed' and
             tuple(int(r[k]) for k in ('ssrc', 'rtp_seq', 'timestamp', 'payload_bytes')) == key and
             int(r['monotonic_us']) >= first['at_us'] and
             (next_at is None or int(r['monotonic_us']) < next_at)]
    if len(seals) != 1:
        raise ValueError('Missing/ambiguous seal in the first attempt window')
    sealed = seals[0]
    epoch, sequence = sealed['epoch'], int(sealed['seq'])
    if not re.fullmatch('[a-f0-9]{16}', epoch) or sequence <= 0:
        raise ValueError('Invalid sealed-cell identity')
    stages = [r for r in decisions if r['epoch'] == epoch and int(r['seq']) == sequence]
    if not stages:
        raise ValueError('Missing source decision for exact sealed cell')
    # Private local source class establishes ownership. A remote traffic hint
    # must never turn neutral transit into an endpoint-owned observation.
    if any(int(r['local_slot']) not in (2, 3) for r in stages):
        raise ValueError('Decision is not a local secondary producer')
    if any(int(r['monotonic_us']) < int(sealed['monotonic_us']) for r in stages):
        raise ValueError('Source decision precedes sealing')
    names = [r['stage'] for r in stages]
    failures = [n for n in names if n in
                ('child_unavailable', 'budget_drop', 'queue_work_rejected')]
    accepted = [r for r in stages if r['stage'] == 'datagram_accepted']
    if failures and ('budget_admit' in names or accepted) or len(failures) > 1 or len(accepted) > 1:
        raise ValueError('Mixed/multiple source decisions; single-path attribution is unsafe')
    if failures:
        verdict = failures[0]
    elif accepted and 'budget_admit' in names:
        verdict = 'accepted_by_local_transport'
    else:
        verdict = 'no_complete_transport_admission_witness'
    return dict(native_rtp_key=dict(zip(('ssrc', 'sequence', 'timestamp', 'payload_bytes'), key)),
                native_attempt_us=first['at_us'], seal_us=int(sealed['monotonic_us']),
                epoch=epoch, cell_sequence=sequence, source_verdict=verdict,
                source_stages=stages,
                native_to_seal_ms=(int(sealed['monotonic_us']) - first['at_us']) / 1000,
                native_attempt_count=len(attempts))


def analyze(directory):
    native = read_trace(directory / 'mac-native.log')
    loss = json.loads((directory / 'loss-analysis.json').read_text())['mac_to_phone']
    missing = next((g for e in loss['loss_reports'] for g in e['gaps']), None)
    if missing is None:
        raise ValueError('Capture has no established video loss interval')
    attempts = [r for r in native['rtp'] if r['stage'] == 's' and
                r['ssrc'] == loss['ssrc'] and r['seq'] == missing['sequence'] % 65536]
    path = directory / 'mac-runtime.log'
    # Detailed source/seal sampling must be enabled by the launcher. Refuse
    # truncated bounded logs; never infer a drop from the absence of a row.
    with path.open() as stream:
        for line in stream:
            if any(s in line for s in ('source_trace_limit', 'source_accepted_trace_limit',
                                      'source_work_trace_limit')):
                raise ValueError('Source trace exhausted its explicit bound')
    return attribute(attempts, records(path, 'media.rtp.cell '),
                     records(path, 'media.source_cell_trace '))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    print(json.dumps(analyze(args.directory), indent=2))
