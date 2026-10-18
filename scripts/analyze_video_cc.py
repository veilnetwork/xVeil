#!/usr/bin/env python3
"""Read bounded endpoint video-controller observations; refuse partial traces."""
import argparse
import json
from pathlib import Path
import re


def read_cc(path):
    sessions = {}
    for line in Path(path).read_text().splitlines():
        if not line.startswith('video.cc.'):
            continue
        kind, _, body = line.partition(' ')
        row = {k: int(v) for k, v in re.findall(r'(\w+)=(-?\d+)', body)}
        identity = row.pop('id')
        if kind == 'video.cc.begin':
            if identity in sessions:
                raise ValueError('Duplicate controller header')
            sessions[identity] = dict(header=row, samples=[], end=None)
            continue
        if identity not in sessions or sessions[identity]['end'] is not None:
            raise ValueError('Controller record outside its capture')
        session = sessions[identity]
        if kind == 'video.cc.sample':
            if session['samples'] and row['at_us'] <= session['samples'][-1]['at_us']:
                raise ValueError('Controller clock regressed or repeated')
            session['samples'].append(row)
        elif kind == 'video.cc.end':
            session['end'] = row
        else:
            raise ValueError('Unknown controller record')
    if not sessions:
        raise ValueError('Missing controller capture')
    for session in sessions.values():
        h = session['header']
        if (session['end'] != {'write_ok': 1} or
                not 0 <= h['rows'] <= 8192 or h['rows'] != h['seen'] or
                h['rows'] != len(session['samples'])):
            raise ValueError('Incomplete or truncated controller capture')
    return sessions


def analyze(path):
    result = []
    for identity, session in read_cc(path).items():
        samples = session['samples']
        at_window = [r for r in samples if r['cwnd_bytes'] >= 0 and
                     r['inflight_bytes'] >= r['cwnd_bytes']]
        result.append(dict(controller=identity, samples=len(samples),
            finite_window_samples=sum(r['cwnd_bytes'] >= 0 for r in samples),
            inflight_at_or_above_reported_window=len(at_window),
            examples=at_window[:8],
            scope='Local controller snapshots; not a wire-send timestamp, acoustic delay, or proof of an unsampled pacer state.'))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    print(json.dumps(analyze(parser.parse_args().trace), indent=2))
