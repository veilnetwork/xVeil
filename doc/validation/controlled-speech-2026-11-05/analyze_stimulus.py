#!/usr/bin/env python3
"""A conservative gate for the three-phase speech stimulus; emits aggregates only.

Exit 0: all phases show the timed pattern at both endpoints (not SPL/MOS).
Exit 2: source completed, but that pattern is not established.
Exit 1: invalid/incomplete source or observation. No raw record is printed.
"""
import argparse
import json
from pathlib import Path
from statistics import median


def analyze(case, pattern, sources):
    if not case.get('completed') or not case.get('samples'):
        raise ValueError('incomplete observation')
    phases = case['phases']
    if [p['control']['ns'] for p in phases] != [1, 0, 1]:
        raise ValueError('missing on/off/on control')
    if case.get('restoredNS', {}).get('ns') != 1:
        raise ValueError('noise suppression not restored')
    windows = pattern['windows']
    if sum(w['kind'] == 'speech' for w in windows) != 3:
        raise ValueError('three speech windows required')
    if len(sources) != len(phases):
        raise ValueError('source count mismatch')
    call_id = None
    epochs = {}
    result = []
    for phase, log in zip(phases, sources):
        if not phase.get('completed') or phase.get('sourceExitCode') != 0:
            raise ValueError('source process incomplete')
        starts = [x for x in log if x.get('event') == 'playback_started']
        ends = [x for x in log if x.get('event') == 'playback_finished']
        if len(starts) != 1 or len(ends) != 1:
            raise ValueError('source witnesses missing')
        start, end = starts[0], ends[0]
        duration = start['frames'] / start['rate']
        if (not start.get('streamOutputVerified') or
                not start.get('systemDefaultUnchanged') or
                not end.get('systemDefaultUnchanged') or
                not end.get('completionReceived') or
                end.get('renderedFrames', -1) < start['frames'] or
                duration != pattern['durationSeconds']):
            raise ValueError('source output not qualified')
        control = phase['control']
        if not (control['aec'] == control['agc'] == 1 and
                control['mediaEpochUnchanged']):
            raise ValueError('processing control changed the session')
        roles = {}
        for role, metric in [('phone', 'audio_input_level_band'),
                             ('windows', 'audio_output_level_band')]:
            by_window = []
            for window in windows:
                values, seen = [], set()
                for sample in case['samples']:
                    at = (sample['uptime_ns'] - start['uptime_ns']) / 1e9
                    # Native stats are cached: stay clear of both boundaries
                    # and never count repeated reads as independent evidence.
                    if not window['from'] + 1.2 <= at < window['to'] - 1.2:
                        continue
                    call = sample['states'][role].get('call') or {}
                    stats = call.get('mediaStats') or {}
                    if call.get('status') != 'active':
                        raise ValueError('nonactive call inside the source')
                    if not call.get('callId'):
                        raise ValueError('call witness missing')
                    if call_id is None:
                        call_id = call['callId']
                    if call['callId'] != call_id:
                        raise ValueError('call changed inside the observation')
                    epoch = stats.get('media_epoch')
                    if type(epoch) is not int:
                        raise ValueError('media witness missing')
                    if role not in epochs:
                        epochs[role] = epoch
                    if epochs[role] != epoch:
                        raise ValueError('media session changed')
                    expected_ns = control['ns'] if role == 'phone' else 1
                    if (stats.get('audio_ns_enabled') != expected_ns or
                            stats.get('audio_aec_enabled') != 1 or
                            stats.get('audio_agc_enabled') != 1 or
                            stats.get('audio_capture_start_result') != 1 or
                            stats.get('audio_playout_start_result') != 1):
                        raise ValueError('native audio state differs from control')
                    key = (stats.get('audio_output_duration_ms'),
                           stats.get('audio_tx_pkts'), stats.get('audio_rx_pkts'))
                    if None in key:
                        continue
                    if key in seen:
                        continue
                    seen.add(key)
                    value = stats.get(metric)
                    if type(value) is not int or not 0 <= value <= 5:
                        continue
                    values.append(value)
                by_window.append({'kind': window['kind'], 'samples': len(values),
                                  'medianBand': median(values) if values else None})
            quiet = [x['medianBand'] for x in by_window
                     if x['kind'] == 'quiet' and x['medianBand'] is not None]
            baseline = median(quiet) if quiet else None
            enough = all(x['samples'] >= 2 for x in by_window)
            matched = sum(x['kind'] == 'speech' and x['medianBand'] is not None
                          and baseline is not None and
                          x['medianBand'] >= baseline + 1 for x in by_window)
            roles[role] = {'quietMedianBand': baseline, 'windows': by_window,
                           'threePulsesEstablished': enough and matched == 3}
        result.append({'nsEnabled': control['ns'], 'roles': roles})
    established = all(r['threePulsesEstablished']
                      for p in result for r in p['roles'].values())
    return {'patternEstablished': established, 'humanAudibilityQualified': False,
            'phases': result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', type=Path, required=True)
    parser.add_argument('--pattern', type=Path, required=True)
    parser.add_argument('--source-dir', type=Path, required=True)
    args = parser.parse_args()
    try:
        case = json.loads(args.case.read_text())
        pattern = json.loads(args.pattern.read_text())
        sources = [[json.loads(l) for l in
                    (args.source_dir / f'ns-aba-source-{i}-private.jsonl').read_text().splitlines()
                    if l.startswith('{')] for i in range(3)]
        result = analyze(case, pattern, sources)
    except (ValueError, KeyError, TypeError, OSError):
        print(json.dumps({'status': 'invalid-observation'}))
        return 1
    print(json.dumps(result))
    return 0 if result['patternEstablished'] else 2


if __name__ == '__main__':
    raise SystemExit(main())
