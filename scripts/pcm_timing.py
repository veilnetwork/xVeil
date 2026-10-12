"""Input timing for the owned synthetic PCM fixture."""


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
