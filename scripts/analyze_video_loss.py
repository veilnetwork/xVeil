#!/usr/bin/env python3
"""Join endpoint video RTP gaps to receiver RTCP intervals, without clock sync."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re


def read_trace(path):
    sessions = {}
    with Path(path).open() as stream:
        for line in stream:
            if not line.startswith('video.loss.'):
                continue
            kind, _, body = line.rstrip().partition(' ')
            row = dict(re.findall(r'(\w+)=([^\s]+)', body))
            row = {k: v if k == 'stage' else int(v) for k, v in row.items()}
            identity = row.pop('id')
            if kind == 'video.loss.begin':
                if identity in sessions:
                    raise ValueError('Duplicate recorder header')
                sessions[identity] = dict(header=row, rtp=[], rr=[], end=None)
                continue
            if identity not in sessions:
                raise ValueError('Record without header')
            session = sessions[identity]
            if kind == 'video.loss.end':
                if session['end'] is not None:
                    raise ValueError('Duplicate recorder footer')
                session['end'] = row
            elif kind in ('video.loss.rtp', 'video.loss.rr'):
                if session['end'] is not None:
                    raise ValueError('Record after footer')
                session[kind.rsplit('.', 1)[1]].append(row)
            else:
                raise ValueError('Unknown trace record')
    if not sessions:
        raise ValueError('Missing video loss trace')
    for session in sessions.values():
        h = session['header']
        if (session['end'] != {'write_ok': 1} or h['malformed'] != 0 or
                h['packets'] != h['packet_seen'] or h['reports'] != h['report_seen'] or
                h['packets'] != len(session['rtp']) or h['reports'] != len(session['rr'])):
            raise ValueError('Incomplete, malformed or truncated metadata capture')
    return {kind: [r for s in sessions.values() for r in s[kind]]
            for kind in ('rtp', 'rr')}


def unwrap(rows, reference=None):
    """Nearest 16-bit sequence, retaining the high water for reordered copies."""
    high = reference
    out = []
    for row in sorted(rows, key=lambda r: r['at_us']):
        value = row['seq']
        if high is not None:
            value += ((high - value + 32768) // 65536) * 65536
        high = value if high is None else max(high, value)
        out.append(dict(row, extended=value))
    return out


def report_key(r):
    return tuple(r[k] for k in ('reporter', 'ssrc', 'fraction', 'lost',
                                'highest', 'jitter', 'lsr', 'dlsr'))


def direction(source, receiver):
    ids = {r['ssrc'] for r in source['rtp'] if r['stage'] == 's'}
    ids &= {r['ssrc'] for r in receiver['rtp'] if r['stage'] == 'r'}
    if len(ids) != 1:
        raise ValueError('Require exactly one shared video source per direction')
    ssrc = ids.pop()
    sends = unwrap([r for r in source['rtp'] if r['stage'] == 's' and r['ssrc'] == ssrc])
    receives = unwrap([r for r in receiver['rtp'] if r['stage'] == 'r' and r['ssrc'] == ssrc], sends[0]['extended'])
    delivered = unwrap([r for r in receiver['rtp'] if r['stage'] == 'd' and r['ssrc'] == ssrc], sends[0]['extended'])
    reports = sorted([r for r in receiver['rr'] if r['stage'] == 's' and
                      r['result'] == 0 and r['ssrc'] == ssrc], key=lambda r: r['at_us'])
    if not reports:
        raise ValueError('Missing receiver report ranges')
    # A receiver whose first packet arrived after sequence wrap starts its own
    # extended space there. Establish the offset from an actual delivered RTP
    # witness, rather than guessing that its wrap count equals the sender's.
    anchors = [r for r in delivered if r['at_us'] <= reports[0]['at_us'] and
               r['seq'] == reports[0]['highest'] % 65536]
    if not anchors:
        raise ValueError('Missing delivered RTP anchor for first receiver report')
    offset = reports[0]['highest'] - anchors[-1]['extended']
    for rows in (sends, receives, delivered):
        for row in rows:
            row['extended'] += offset
    for r in reports:
        if not any(d['extended'] == r['highest'] and d['at_us'] <= r['at_us'] for d in delivered):
            raise ValueError('Receiver report high sequence lacks a delivered RTP witness')
    by_sequence = defaultdict(list)
    attempts = defaultdict(list)
    for r in delivered:
        by_sequence[r['extended']].append(r['at_us'])
    for r in sends:
        attempts[r['extended']].append(r)
    source_reports = Counter(report_key(r) for r in source['rr'] if
                             r['stage'] == 'r' and r['ssrc'] == ssrc)
    events = []
    previous = None
    for r in reports:
        if previous is not None and r['highest'] < previous['highest']:
            raise ValueError('Receiver report sequence regressed; cannot assume an interval')
        if r['fraction']:
            if previous is None:
                raise ValueError('First report is lossy; initial range not established')
            count = r['highest'] - previous['highest']
            if count > 65536:
                raise ValueError('Report range exceeds unambiguous sequence window')
            gaps = []
            for sequence in range(previous['highest'] + 1, r['highest'] + 1):
                times = by_sequence.get(sequence, [])
                if times and times[0] <= r['at_us']:
                    continue
                sent = attempts.get(sequence, [])
                accepted = [s for s in sent if s['result'] == 0]
                gaps.append(dict(sequence=sequence,
                    source_attempts=len(sent), source_accepted=len(accepted),
                    source_rejected=sum(s['result'] != 0 for s in sent),
                    payload_bytes=sorted({s['payload'] for s in sent}),
                    later_delivered_after_report_ms=(times[0] - r['at_us']) / 1000 if times else None))
            loss_delta = r['lost'] - previous['lost']
            events.append(dict(report_at_us=r['at_us'], highest=r['highest'],
                previous_highest=previous['highest'], expected=count,
                cumulative_lost=r['lost'], lost_delta=loss_delta,
                fraction=r['fraction'], fraction_from_report_deltas=
                    255 * max(loss_delta, 0) // count if count else 0,
                unchanged_range_and_loss=count == 0 and loss_delta == 0,
                matching_source_report_copies=source_reports[report_key(r)], gaps=gaps))
        previous = r
    def key(r): return r['extended'], r['timestamp']
    accepted = {key(r) for r in sends if r['result'] == 0}
    received = {key(r) for r in receives}
    decoded = {key(r) for r in delivered}
    return dict(ssrc=ssrc, sends=len(sends), locally_rejected=sum(r['result'] != 0 for r in sends),
                received_copies=len(receives), delivered_copies=len(delivered),
                unique_accepted=len(accepted), unique_received=len(received),
                accepted_not_received=sorted(accepted - received),
                received_not_delivered=sorted(received - decoded),
                report_count=len(reports), loss_report_count=len(events), loss_reports=events,
                clock_scope='Only receiver-local delivery/report time differences; no cross-device one-way latency.')


def analyze(directory):
    traces = {n: read_trace(directory / (n + '-native.log')) for n in ('mac', 'phone')}
    return {'mac_to_phone': direction(traces['mac'], traces['phone']),
            'phone_to_mac': direction(traces['phone'], traces['mac'])}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    print(json.dumps(analyze(args.directory), indent=2))
