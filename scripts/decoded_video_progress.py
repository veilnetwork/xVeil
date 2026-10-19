"""Describe actual decoded-frame pulls from an owned synthetic video fixture.

RTP markers cannot supply these witnesses. Rows contain sequence numbers,
dimensions and hashes only; no image bytes are retained. Retrieval intervals
are sampled observations, not native decoder or screen-presentation timing.
"""
import math
import re


def required_tail_content_changes(duration):
    """Keep the recorded full-capture gate distinct from a short motion smoke."""
    if not math.isfinite(duration) or duration <= 20:
        raise ValueError('Invalid synthetic video duration')
    return 14 if duration >= 360 else 1


def summarize(rows, duration, video_start=20, tail_seconds=15):
    if not math.isfinite(duration) or duration <= video_start or tail_seconds <= 0:
        raise ValueError('Invalid synthetic video observation window')
    required_changes = required_tail_content_changes(duration)
    grouped = {0: [], 1: []}
    for row in rows:
        at, side, seq = row['t'], row['side'], row['seq']
        if (side not in grouped or not math.isfinite(at) or not 0 <= at <= duration + 60
                or type(seq) is not int or seq < 0):
            raise ValueError('Invalid decoded-frame witness')
        if seq:
            if (type(row['width']) is not int or type(row['height']) is not int
                    or not 0 < row['width'] <= 4096 or not 0 < row['height'] <= 4096
                    or not re.fullmatch(r'[0-9a-f]{64}', row['sha256'])):
                raise ValueError('Missing decoded-frame dimensions or hash')
        grouped[side].append(row)
    directions = []
    for side, observed in grouped.items():
        if any(a['t'] >= b['t'] for a, b in zip(observed, observed[1:])):
            raise ValueError('Nonmonotonic frame observation clock')
        decoded = [r for r in observed if r['seq']]
        if any(a['seq'] >= b['seq'] for a, b in zip(decoded, decoded[1:])):
            raise ValueError('Decoded-frame sequence did not advance')
        mixed = [r for r in decoded if video_start <= r['t'] <= duration]
        tail = [r for r in mixed if r['t'] >= max(video_start, duration-tail_seconds)]
        changes = sum(a['sha256'] != b['sha256'] for a, b in zip(mixed, mixed[1:]))
        tail_changes = sum(a['sha256'] != b['sha256'] for a, b in zip(tail, tail[1:]))
        clocks = [video_start] + [r['t'] for r in mixed] + [duration]
        directions.append(dict(side=side, decoded_frame_pulls=len(mixed),
                               content_changes=changes,
                               last_decoded_pull_seconds=mixed[-1]['t'] if mixed else None,
                               max_sampled_pull_gap_seconds=max(b-a for a, b in zip(clocks, clocks[1:])),
                               tail_decoded_pulls=len(tail), tail_content_changes=tail_changes,
                               tail_content_verified=tail_changes >= required_changes,
                               moving_at_end=len(tail) >= 2 and tail_changes > 0))
    return dict(synthetic_fixture_only=True, screen_presentation_proof=False,
                sampled_retrieval_not_native_decode_timing=True,
                tail_seconds=tail_seconds, directions=directions,
                required_tail_content_changes=required_changes,
                tail_content_verified=all(d['tail_content_verified'] for d in directions),
                moving_at_end=all(d['moving_at_end'] for d in directions))
