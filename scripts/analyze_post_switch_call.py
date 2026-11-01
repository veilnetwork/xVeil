#!/usr/bin/env python3
"""Summarize call setup after a network switch without exporting identities.

These are sampled state boundaries, not packet-level delivery times or an
engine-start benchmark. In particular, dialing time is not audio startup time.
"""
import json
import math
from pathlib import Path
import sys

ROLES = ('phone', 'windows')
MAX_SAMPLE_GAP = 2.5


def _time(value):
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        raise ValueError('invalid observation time')
    return value


def _call(row):
    value = row.get('call')
    return value if isinstance(value, dict) else {}


def _fresh(call):
    stats = call.get('mediaStats') or {}
    age, packets = stats.get('audio_rx_native_age_ms'), stats.get('audio_rx_pkts')
    return (stats.get('running') is True and
            type(stats.get('worker_stalled')) is int and stats['worker_stalled'] == 0 and
            type(age) is int and 0 <= age <= 1000 and
            type(packets) is int and packets > 0)


def analyze(capture):
    events, samples = capture['events'], capture['samples']
    def event(kind):
        found = [e for e in events if e.get('kind') == kind]
        if len(found) != 1:
            raise ValueError('one setup event of each required kind is needed')
        return found[0]

    placed, cut, accepted = (event(k) for k in
                            ('placed', 'wifi-disabled', 'windows-accepted'))
    identity = placed.get('callId')
    if not isinstance(identity, str) or not identity:
        raise ValueError('expected call is missing')
    start, switched, answered = (_time(e['at']) for e in (placed, cut, accepted))
    if not switched <= start <= answered:
        raise ValueError('setup events are out of order')
    qualified = [e for e in events if e.get('kind') == 'qualified']
    if len(qualified) > 1:
        raise ValueError('multiple qualification events')
    end = _time(qualified[0]['at']) if qualified else None
    if end is not None and end < answered:
        raise ValueError('qualification precedes acceptance')
    result = {
        'schema': 'xveil-post-switch-setup-observation/1',
        'scope': 'sampled_call_states_not_audibility_or_network_reachability',
        'endpoints': {},
    }
    selected = {}
    for role in ROLES:
        all_rows = [s for s in samples if s.get('role') == role]
        times = [_time(s['at']) for s in all_rows]
        if times != sorted(times):
            raise ValueError('observations must be chronological')
        rows = [r for r in all_rows if r['at'] >= start]
        selected[role] = rows
        first = answered if role == 'windows' else start
        alive = [r for r in rows if r['at'] >= first]
        lost = sum(_call(r).get('callId') != identity or
                   _call(r).get('status') not in ('dialing', 'ringing', 'connecting', 'active')
                   for r in alive)
        foreign = sum(bool(_call(r).get('callId')) and
                      _call(r).get('callId') != identity for r in rows)
        fresh = [r for r in rows if _call(r).get('callId') == identity and
                 _call(r).get('status') == 'active' and _fresh(_call(r))]
        points = [start] + [r['at'] for r in rows]
        gaps = [b - a for a, b in zip(points, points[1:])]
        coverage = bool(end is not None and len(rows) >= 5 and
                        0 <= end - rows[-1]['at'] <= MAX_SAMPLE_GAP and
                        max(gaps, default=math.inf) <= MAX_SAMPLE_GAP)
        tail = rows[-5:]
        tail_fresh = bool(len(tail) == 5 and all(
            _call(r).get('callId') == identity and
            _call(r).get('status') == 'active' and _fresh(_call(r)) for r in tail))
        counter_progress = bool(tail_fresh and len({
            _call(r)['mediaStats']['audio_rx_pkts'] for r in tail}) > 1)
        result['endpoints'][role] = {
            'sampleCount': len(rows),
            'missingOrUnexpectedCallSamplesAfterRoleStart': lost,
            'foreignCallSamples': foreign,
            'coverageVerified': coverage,
            'firstSampledFreshRxAfterCutMs':
                round((fresh[0]['at'] - switched) * 1000) if fresh else None,
            'lastFiveSamplesFresh': tail_fresh,
            'freshTailPacketCounterProgressObserved': counter_progress,
        }
    caller = [r for r in selected['phone'] if _call(r).get('callId') == identity]
    dialing = [r for r in caller if _call(r).get('status') == 'dialing' and
               r['at'] >= answered]
    all_connecting = [r for r in caller if _call(r).get('status') in ('connecting', 'active')]
    connecting = [r for r in all_connecting if r['at'] >= answered]
    fresh = [r for r in caller if _call(r).get('status') == 'active' and _fresh(_call(r))]
    result['callerLastDialingSampleAfterCalleeAcceptMs'] = (
        round((dialing[-1]['at'] - answered) * 1000) if dialing else None)
    result['callerFirstConnectingOrActiveSampleAfterCalleeAcceptMs'] = (
        round((connecting[0]['at'] - answered) * 1000) if connecting else None)
    result['callerFirstFreshRxAfterFirstConnectingObservationMs'] = (
        round((fresh[0]['at'] - all_connecting[0]['at']) * 1000)
        if fresh and all_connecting else None)
    result['sampledSetupQualified'] = bool(qualified and all(
        e['coverageVerified'] and e['lastFiveSamplesFresh'] and
        e['freshTailPacketCounterProgressObserved'] and
        e['missingOrUnexpectedCallSamplesAfterRoleStart'] == 0 and
        e['foreignCallSamples'] == 0 for e in result['endpoints'].values()))
    return result


def main():
    try:
        if len(sys.argv) != 2 or Path(sys.argv[1]).stat().st_size > 16 * 1024 * 1024:
            raise ValueError('one bounded capture is required')
        value = analyze(json.loads(Path(sys.argv[1]).read_text()))
    except (ValueError, TypeError, KeyError, AttributeError, OSError):
        print('Invalid setup capture; no private input echoed.', file=sys.stderr)
        return 2
    print(json.dumps(value, ensure_ascii=False, indent=2))
    return 0 if value['sampledSetupQualified'] else 1


if __name__ == '__main__':
    sys.exit(main())
