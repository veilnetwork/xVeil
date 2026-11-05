"""Qualify a Windows receive-only probe; emit aggregates, never raw rows."""
import argparse
import json
import math
from pathlib import Path
from statistics import median

SPEECH_WINDOWS = [(1.9, 2.8), (5.4, 6.3), (8.9, 9.8)]
QUIET_WINDOWS = [(0.3, 1.0), (3.7, 4.5), (7.2, 8.0), (10.7, 11.5)]


def qualify(rows, job, engine_sha, *, silence=False, packet_ms=20):
    def require(condition, code):
        if not condition:
            raise ValueError(code)

    require(packet_ms in (20, 40, 60), 'packet_duration_invalid')

    require(job.get('finished') is True and type(job.get('exitCode')) is int
            and job['exitCode'] == 0 and type(job.get('session')) is int
            and job['session'] > 0 and job.get('mediaSha') == engine_sha,
            'job_not_qualified')
    starts = [r for r in rows if r.get('kind') == 'start']
    ends = [r for r in rows if r.get('kind') == 'finish']
    samples = [r for r in rows if r.get('kind') == 'sample']
    require(len(starts) == 1 and len(ends) == 1 and len(samples) >= 60
            and not any(r.get('kind') == 'failure' for r in rows), 'incomplete_probe')
    output = starts[0].get('output', {})
    require(starts[0].get('result') == 0 and output.get('success') is True
            and output.get('sessionState') == 1
            and output.get('appMuted') is False and output.get('outputMuted') is False
            and output.get('appVolumePercent', 0) > 0
            and output.get('outputVolumePercent', 0) > 0, 'output_not_ready')
    require(ends[0].get('delivery_failures') == 0
            and ends[0].get('registered') == 0, 'incomplete_cleanup')
    previous = -1.0
    counts = []
    for row in samples:
        seconds, peak, stats = row['seconds'], row['session_peak'], row['stats']
        require(isinstance(seconds, (int, float)) and math.isfinite(seconds)
                and seconds > previous, 'sample_clock_invalid')
        previous = seconds
        require(isinstance(peak, (int, float)) and math.isfinite(peak)
                and 0 <= peak <= 1, 'session_meter_unavailable')
        require(stats.get('audio_capture_start_result') == -1
                and stats.get('audio_playout_start_result') == 1
                and stats.get('worker_stalled') == 0, 'native_playout_not_ready')
        counts.append(stats.get('audio_rx_pkts', -1))
    require(counts[-1] == 12000 // packet_ms and len(set(counts)) >= 40
            and all(a <= b for a, b in zip(counts, counts[1:])), 'rtp_not_observed')
    emitted = samples[-1]['stats'].get('audio_output_emitted_samples', 0)
    require(emitted >= 500000, 'pcm_not_emitted')

    def window_values(windows, key):
        values = []
        for start, end in windows:
            selected = [s for s in samples if start <= s['seconds'] <= end]
            require(len(selected) >= 3, 'insufficient_window_samples')
            values.append(median(s[key] if key in s else s['stats'].get(key, -1)
                                 for s in selected))
        return values

    burst = window_values(SPEECH_WINDOWS, 'session_peak')
    quiet = window_values(QUIET_WINDOWS, 'session_peak')
    native_bands = window_values(SPEECH_WINDOWS, 'audio_output_level_band')
    baseline = max(quiet)
    if silence:
        require(max(s['session_peak'] for s in samples) < 0.001,
                'silence_control_audible')
    else:
        require(baseline < 0.001 and all(value > max(0.005, baseline * 10)
                                       for value in burst), 'pattern_not_observed')
        require(all(value >= 2 for value in native_bands), 'native_pattern_missing')
    return {
        'schema': 'xveil-windows-receive-probe/1',
        'qualified': True,
        'mode': 'silence' if silence else 'pattern',
        'packet_ms': packet_ms,
        'samples': len(samples),
        'rtp_packets': counts[-1],
        'emitted_samples': emitted,
        'burst_session_peak_medians': [round(v, 6) for v in burst],
        'quiet_session_peak_medians': [round(v, 6) for v in quiet],
        'capture_requested': False,
        'human_audibility_verified': False,
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rows', type=Path)
    parser.add_argument('job', type=Path)
    parser.add_argument('--engine-sha', required=True)
    parser.add_argument('--silence', action='store_true')
    parser.add_argument('--packet-ms', type=int, choices=(20, 40, 60), default=20)
    args = parser.parse_args()
    try:
        rows = [json.loads(line) for line in args.rows.read_text().splitlines()
                if line.startswith('{')]
        result = qualify(rows, json.loads(args.job.read_text(encoding='utf-8-sig')),
                         args.engine_sha, silence=args.silence, packet_ms=args.packet_ms)
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        code = str(error) if type(error) is ValueError else 'invalid_input'
        allowed = {
            'job_not_qualified', 'incomplete_probe', 'output_not_ready',
            'incomplete_cleanup', 'sample_clock_invalid', 'session_meter_unavailable',
            'native_playout_not_ready', 'rtp_not_observed', 'pcm_not_emitted',
            'insufficient_window_samples', 'silence_control_audible',
            'pattern_not_observed', 'native_pattern_missing',
            'packet_duration_invalid',
        }
        print(json.dumps({'qualified': False, 'reason': code if code in allowed
                          else 'invalid_input'}))
        raise SystemExit(2)
    print(json.dumps(result, indent=2))
