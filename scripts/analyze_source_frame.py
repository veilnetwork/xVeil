#!/usr/bin/env python3
"""Establish an owned frame's exact source charge from complete endpoint traces.

Only one-RTP-per-cell frames with a uniform envelope are supported. A summed
packet size alone does not prove the scheduler's whole-work charge.
"""
import argparse
from collections import defaultdict
import json
from pathlib import Path

from analyze_direct_source import analyze, attribute, records
from analyze_video_loss import read_trace


def frame_charge(native, seals, decisions, frames, anchor):
    seals, decisions, frames = list(seals), list(decisions), list(frames)
    key = anchor['native_rtp_key']
    epoch, sequence = anchor['epoch'], anchor['cell_sequence']
    candidates = [f for f in frames if f['epoch'] == epoch and
                  int(f['first_seq']) <= sequence <= int(f['last_seq'])]
    if len(candidates) != 1:
        raise ValueError('Missing/ambiguous whole-frame boundary')
    frame = candidates[0]
    count = int(frame['cells'])
    first, last = int(frame['first_seq']), int(frame['last_seq'])
    if (not 1 <= count <= 512 or frame['contiguous'] != 'true' or
            int(frame['expired_cells']) != 0 or
            int(frame['planned_cells']) != count or
            int(frame['packets']) != count or last - first + 1 != count):
        raise ValueError('Require complete, contiguous one-RTP-per-cell work')
    groups = defaultdict(list)
    for r in native:
        if (r['stage'] == 's' and r['ssrc'] == key['ssrc'] and
                r['timestamp'] == key['timestamp']):
            groups[r['seq'], r['payload']].append(r)
    if len(groups) != count:
        raise ValueError('Native packets do not match the whole-frame boundary')
    packets = []
    for attempts in groups.values():
        result = attribute(attempts, seals, decisions)
        if result['epoch'] != epoch:
            raise ValueError('Frame includes a different seal epoch')
        if any(int(r['local_slot']) != int(frame['local_slot'])
               for r in result['source_stages']):
            raise ValueError('Frame source ownership changed')
        wire = {int(r['wire_bytes']) for r in result['source_stages']}
        if len(wire) != 1:
            raise ValueError('Source envelope size changed between decisions')
        original = min(attempts, key=lambda r: r['at_us'])
        if any((r['bytes'], r['marker']) != (original['bytes'], original['marker'])
               for r in attempts):
            raise ValueError('Native packet metadata changed on retransmission')
        packets.append(dict(result, raw_bytes=original['bytes'],
                            marker=original['marker'], wire_bytes=wire.pop()))
    packets.sort(key=lambda r: r['cell_sequence'])
    if [p['cell_sequence'] for p in packets] != list(range(first, last + 1)):
        raise ValueError('Native first attempts do not span the sealed work')
    seq = [p['native_rtp_key']['sequence'] for p in packets]
    if (any((b - a) % 65536 != 1 for a, b in zip(seq, seq[1:])) or
            [p['marker'] for p in packets] != [0] * (count - 1) + [1]):
        raise ValueError('RTP sequence/marker does not establish one complete frame')
    raw = sum(p['raw_bytes'] for p in packets)
    sealed = int(frame['sealed_bytes'])
    if raw != int(frame['raw_bytes']) or sealed < raw or (sealed - raw) % count:
        raise ValueError('Source/native frame byte counts disagree')
    seal_per_cell = (sealed - raw) // count
    envelopes = {p['wire_bytes'] - p['raw_bytes'] - seal_per_cell for p in packets}
    if len(envelopes) != 1 or min(envelopes) < 0:
        raise ValueError('Envelope cost is not uniform across the work')
    envelope_per_cell = envelopes.pop()
    charge = sealed + count * envelope_per_cell
    if charge != sum(p['wire_bytes'] for p in packets):
        raise ValueError('Source charge does not match all original cells')
    return dict(epoch=epoch, first_seq=first, last_seq=last, cells=count,
                raw_rtp_bytes=raw, sealed_bytes=sealed,
                seal_bytes_per_cell=seal_per_cell,
                envelope_bytes_per_cell=envelope_per_cell,
                whole_work_charge_bytes=charge, first_attempts=packets,
                scope='Exact local work charge; no cross-device latency or acoustic claim.')


def analyze_frame(directory):
    anchor = analyze(directory)
    path = directory / 'mac-runtime.log'
    return frame_charge(read_trace(directory / 'mac-native.log')['rtp'],
                        records(path, 'media.rtp.cell '),
                        records(path, 'media.source_cell_trace '),
                        records(path, 'media.source_frame_trace '), anchor)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    print(json.dumps(analyze_frame(args.directory), indent=2))
