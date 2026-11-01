#!/usr/bin/env python3
"""Aggregate a private phone/Windows handover capture without exporting IDs.

This checks sampled call/audio state. Radio switching and audible speech need
their own evidence. A vanished call is a failure, including after `ended` has
already been cleared to null. Epoch-local audio ages are never a gap upper bound.
"""
import json
import math
from pathlib import Path
import sys

ROLES = ('phone', 'windows')
REQUIRED_SECONDS = 40
MAX_SAMPLE_GAP_SECONDS = 2.5


def _number(value):
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        raise ValueError('invalid observation time')
    return value


def _call(sample):
    value = sample.get('call')
    return value if isinstance(value, dict) else {}


def _stats(call):
    value = call.get('mediaStats')
    return value if isinstance(value, dict) else {}


def _fresh_audio(call, age_limit):
    stats = _stats(call)
    age, packets = stats.get('audio_rx_native_age_ms'), stats.get('audio_rx_pkts')
    return (stats.get('running') is True and
            type(stats.get('worker_stalled')) is int and
            stats['worker_stalled'] == 0 and type(age) is int and
            0 <= age <= age_limit and type(packets) is int and packets > 0)


def analyze(capture):
    events, samples = capture['events'], capture['samples']
    places = [e for e in events if e.get('kind') == 'place-return']
    cuts = [e for e in events if e.get('kind') == 'wifi-disable-return']
    if len(places) != 1 or len(cuts) != 1:
        raise ValueError('one call and one handover are required')
    expected = places[0]['call']['callId']
    if not isinstance(expected, str) or not expected:
        raise ValueError('expected call is missing')
    cut = _number(cuts[0]['at'])
    result = {'schema': 'xveil-handover-observation/1',
              'requiredObservationSeconds': REQUIRED_SECONDS, 'endpoints': {}}
    for role in ROLES:
        rows = [s for s in samples if s.get('role') == role]
        times = [_number(s['at']) for s in rows]
        if times != sorted(times):
            raise ValueError('observations must be chronological')
        before = [s for s in rows if s['at'] < cut]
        after = [s for s in rows if s['at'] >= cut]
        pre = _call(before[-1]) if before else {}
        precondition = bool(before and cut - before[-1]['at'] <= 2.5 and
                            pre.get('callId') == expected and
                            pre.get('status') == 'active' and
                            pre.get('transport') == 'p2p' and
                            _fresh_audio(pre, 1000))
        lost = [s for s in after if _call(s).get('callId') != expected or
                _call(s).get('status') != 'active']
        duration = after[-1]['at'] - cut if after else 0
        points = [cut] + [s['at'] for s in after]
        max_gap = max((b - a for a, b in zip(points, points[1:])), default=0)
        coverage = bool(after and duration >= REQUIRED_SECONDS and
                        max_gap <= MAX_SAMPLE_GAP_SECONDS)
        ages = [_stats(_call(s)).get('audio_rx_native_age_ms') for s in after]
        valid_ages = [a for a in ages if type(a) is int and a >= 0]
        result['endpoints'][role] = {
            'preconditionVerified': precondition,
            'samplesAfterCut': len(after),
            'observationSeconds': round(duration, 3),
            'coverageVerified': coverage,
            'missingOrNonActiveSamples': len(lost),
            'firstCallLostAfterCutMs': (
                round(1000 * (lost[0]['at'] - cut)) if lost else None),
            'callSurvivalVerified': precondition and coverage and not lost,
            'freshAudioAtEnd': bool(after and not lost and
                                    _fresh_audio(_call(after[-1]), 3000)),
            'allSampledAudioFresh': bool(after and all(
                _fresh_audio(_call(s), 3000) for s in after)),
            'maxSampledAudioPayloadAgeWithinEpochMs': max(valid_ages, default=None),
            'continuousAudioGapUpperBoundMs': None,
        }
    result['callSurvivalVerified'] = all(
        r['callSurvivalVerified'] for r in result['endpoints'].values())
    result['qualityObservationQualified'] = result['callSurvivalVerified'] and all(
        r['allSampledAudioFresh'] for r in result['endpoints'].values())
    return result


def main():
    try:
        if len(sys.argv) != 2 or Path(sys.argv[1]).stat().st_size > 16 * 1024 * 1024:
            raise ValueError('one bounded capture is required')
        summary = analyze(json.loads(Path(sys.argv[1]).read_text()))
    except (ValueError, TypeError, KeyError, AttributeError, OSError):
        print('Invalid handover capture; no private input echoed.', file=sys.stderr)
        return 2
    print(json.dumps(summary, indent=2))
    return 0 if summary['qualityObservationQualified'] else 1


if __name__ == '__main__':
    sys.exit(main())
