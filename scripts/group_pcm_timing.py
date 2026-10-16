"""Match group tone transitions by sequence position, not periodic phase.

A two-second stale stream can otherwise appear fast when alternating tones
wrap to the same frequency. Full source/capture rows establish the first epoch;
every subsequent decoded transition must keep its original ordinal.
"""
from pcm_timing import input_edges


def analyze_voice_path(rows, duration):
    edges = input_edges(rows)
    decoded = []
    previous = pending = None
    pending_at = None
    run = 0
    for row in rows:
        frequency = row['freq'] if row['freq'] and row['rms'] >= 500 else None
        if frequency is None or frequency == previous:
            pending, run = None, 0
            continue
        if frequency != pending:
            pending, pending_at, run = frequency, row['t'], 1
        else:
            run += 1
        if run >= 2:
            decoded.append((pending_at, frequency))
            previous = frequency
            pending, run = None, 0
    phases = []
    for lo, hi, name in [(5, 20, 'audio-only'), (20, duration, 'audio-video-file')]:
        delays, missing = [], 0
        for ordinal, (at, frequency, _) in enumerate(edges):
            if not lo <= at < hi:
                continue
            if (ordinal >= len(decoded) or decoded[ordinal][1] != frequency or
                    decoded[ordinal][0] < at):
                missing += 1
            else:
                delays.append((decoded[ordinal][0] - at) * 1000)
        phases.append({'phase': name, 'matched': len(delays), 'missing': missing,
                       'max_ms': max(delays, default=None)})
    return {'phases': phases, 'source_edges': len(edges),
            'decoded_edges': len(decoded), 'matching': 'ordinal_from_capture_start'}
