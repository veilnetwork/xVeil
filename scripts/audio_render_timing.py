"""Join an owned source marker to the receiver's recorded RTP output clock.

The clock bracket is diagnostic, not a replacement for decoded PCM evidence:
time scaling, codec lookahead and concealment can change the actual samples.
All wall clocks must belong to the same host and capture. No RTP offset is
inferred here, and incomplete traces cannot establish an output observation.
"""
import bisect
import re


def _fields(line):
    return {key: int(value) for key, value in re.findall(r'(\w+)=(-?\d+)', line)}


def playout_streams(lines):
    streams, sections, section = {}, [], None
    for line in lines:
        if line.startswith('audio.playout.begin '):
            section = dict(meta=_fields(line), samples=[], packets=[], packet_meta=None)
            sections.append(section)
        elif line.startswith('audio.playout '):
            if section is None or section['packet_meta'] is not None:
                raise ValueError('Playout record without its own header')
            section['samples'].append(_fields(line))
        elif line.startswith('audio.rtp.begin '):
            if section is None or section['packet_meta'] is not None:
                raise ValueError('Packet record without its own playout stream')
            section['packet_meta'] = _fields(line)
        elif line.startswith('audio.rtp received_us='):
            if section is None or section['packet_meta'] is None:
                raise ValueError('Packet record without its own header')
            section['packets'].append(_fields(line))
    for section in sections:
        for meta, records in ((section['meta'], section['samples']),
                              (section['packet_meta'], section['packets'])):
            if (meta is None or not {'count', 'observed', 'limit'} <= meta.keys()
                    or not len(records) == meta['count'] == meta['observed']
                    or not 0 < meta['count'] < meta['limit'] <= 65536):
                raise ValueError('Incomplete or capacity-limited playout trace')
        if any(not {'received_us', 'ssrc', 'sequence', 'rtp_timestamp'} <= row.keys()
               for row in section['packets']):
            raise ValueError('Malformed decoder packet insertion')
        ids = {packet['ssrc'] for packet in section['packets']}
        if len(ids) != 1 or next(iter(ids)) in streams:
            raise ValueError('Ambiguous playout stream SSRC')
        samples = section['samples']
        required = {'entered_us', 'exited_us', 'rtp_timestamp', 'speech_type',
                    'muted', 'skipped', 'fallback'}
        if any(not required <= row.keys() for row in samples):
            raise ValueError('Malformed playout record; no repair or interpolation allowed')
        times = [row['entered_us'] for row in samples]
        if (any(row['exited_us'] < row['entered_us'] for row in samples)
                or any(b <= a for a, b in zip(times, times[1:]))
                or any(a['exited_us'] > b['entered_us']
                       for a, b in zip(samples, samples[1:]))):
            raise ValueError('Invalid playout callback clocks')
        section['times'] = times
        streams[next(iter(ids))] = section
    return streams


def attribute_render(streams, *, ssrc, packet_timestamp, sequence,
                     marker_timestamp, rtp_hz, source_us, pcm_edge_us):
    if not streams:
        return None
    stream = streams.get(ssrc)
    if stream is None:
        return dict(available=False, reason='missing_receiver_stream')
    packets = [row for row in stream['packets'] if row['sequence'] == sequence
               and row['rtp_timestamp'] == packet_timestamp]
    if len(packets) != 1:
        raise ValueError('Missing or ambiguous decoder packet insertion')
    if rtp_hz <= 0 or rtp_hz % 100 or pcm_edge_us < source_us:
        raise ValueError('Invalid marker clock')
    packet = packets[0]
    samples = stream['samples']
    # Start at the source witness, retaining the adjacent earlier callback.
    # This avoids a false match to a previous wrap or an extrapolated startup.
    index = max(1, bisect.bisect_left(stream['times'], source_us))

    def delta(row):
        return (row['rtp_timestamp'] - marker_timestamp + 2**31) % 2**32 - 2**31

    for index in range(index, len(samples)):
        before, after = samples[index-1:index+1]
        low, high = delta(before), delta(after)
        if low <= 0 <= high:
            if low == 0:
                after = before
            elif high == 0:
                before = after
            normal = all(row['speech_type'] == 0 and not row['muted']
                         and not row['skipped'] and not row['fallback']
                         for row in (before, after))
            step = (after['rtp_timestamp'] - before['rtp_timestamp']) % 2**32
            # A causal, recent arrival baseline needs no sender wall clock.
            # Its age includes upstream excess delay, unlike NetEq storage.
            # It is NOT absolute one-way latency or a proposed policy limit.
            recent = [row for row in stream['packets']
                      if before['entered_us']-30000000 <= row['received_us'] <= before['entered_us']]
            relative_age = None
            if recent:
                def intercept(row):
                    ticks = (row['rtp_timestamp']-marker_timestamp+2**31) % 2**32-2**31
                    return row['received_us'] - ticks * 1e6 / rtp_hz
                witness = min(recent, key=intercept)
                floor = intercept(witness)
                relative_age = dict(
                    history_window_ms=30000, packet_count=len(recent),
                    floor_witness=witness,
                    clock_age_ms=[(row['exited_us']-delta(row)*1e6/rtp_hz-floor)/1000
                                  for row in (before, after)],
                    absolute_one_way_latency=False)
            return dict(
                available=True, marker_rtp_timestamp=marker_timestamp,
                packet_inserted_us=packet['received_us'],
                before=before, after=after,
                continuous_normal_speech=normal and step <= 2 * rtp_hz // 100,
                rtp_clock_step_ms=step * 1000 / rtp_hz,
                relative_arrival_clock=relative_age,
                source_to_clock_bracket_ms=[(row['exited_us']-source_us)/1000
                                            for row in (before, after)],
                insertion_to_clock_bracket_ms=[(row['exited_us']-packet['received_us'])/1000
                                               for row in (before, after)],
                clock_bracket_to_pcm_edge_ms=[(pcm_edge_us-row['exited_us'])/1000
                                              for row in (after, before)],
                signal_output_proof=False)
        if high > 0:
            break
    return dict(available=False, reason='marker_clock_not_bracketed')
