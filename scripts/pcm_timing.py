"""Input timing for the owned synthetic PCM fixture."""

import math


def capture_coverage(rows, duration):
    """A late-loaded source cannot stand in for the full timed workload."""
    directions = []
    for side in (0, 1):
        times = [row['source_at'] for row in rows if row['side'] == side]
        first, last = (min(times), max(times)) if times else (None, None)
        complete = (bool(times) and all(math.isfinite(at) for at in times)
                    and 0 <= first <= .1 and last >= duration - .1)
        directions.append(dict(side=side, first_seconds=first,
                               last_seconds=last, complete=complete))
    return dict(verified=all(d['complete'] for d in directions),
                directions=directions)


def input_edges(rows):
    """Keep capture submission time independent of local output processing."""
    edges = []
    last = None
    for row in rows:
        if row['source_freq'] != last:
            at = row['source_at']
            if not 0 <= at <= row['t']:
                raise ValueError('Capture must precede local playout observation')
            edges.append((at, row['source_freq'], row['source_tick']))
            last = row['source_freq']
    return edges
