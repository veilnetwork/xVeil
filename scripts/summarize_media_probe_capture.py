#!/usr/bin/env python3
"""Summarize private endpoint traces without exporting correlation identifiers.

Header correlation observes opaque sealed cells, not their plaintext/type or
network delivery. Missing samples cannot prove loss without complete capture.
Wall clocks are deliberately not subtracted; endpoint clocks may differ. Each
input must come from one process lifetime: probe IDs restart with the process.
"""
import json
from pathlib import Path
import re
import sys

STAGES = ('direct_send', 'relay_send', 'received', 'feedback_send',
          'onion_send_begin', 'onion_send_end')
MAX_BYTES = 64 * 1024 * 1024


def _parse(text):
    cells, queued, begins, fresh, late = [], set(), set(), set(), set()
    cancelled = set()
    unrelated = 0
    for line in text.splitlines():
        begin = re.search(r'media.path_probe begin id=(\d{1,20}) '
                          r'route=(Direct|Relay) budget_us=(\d{1,10})\b', line)
        if begin:
            begins.add((begin[1], begin[2], int(begin[3])))
        reply = re.search(r'media.path_probe reply id=(\d{1,20}) '
                          r'route=(Direct|Relay) matches=(true|false) '
                          r'status=(Pending|Qualified\([^)]*\)|Expired|Cancelled) '
                          r'age_us=(\d{1,20}) budget_us=(\d{1,10})\b', line)
        if reply:
            key = (reply[1], reply[2], int(reply[6]))
            if reply[3] == 'false':
                unrelated += 1
            elif reply[4] == 'Cancelled':
                cancelled.add(key)
            elif reply[4] == 'Expired' or int(reply[5]) > key[2]:
                late.add(key)
            else:
                fresh.add(key)
        marker = ('media.cell.sample ' if 'media.cell.sample ' in line else
                  'ipc.rt_trace.sealed_sample ')
        if marker in line:
            body = line.split(marker, 1)[1]
            fields = dict(re.findall(r'(\w+)=([^\s]+)', body))
            epoch, seq, size = (fields.get(k, '') for k in ('epoch', 'seq', 'bytes'))
            if (re.fullmatch(r'[0-9a-f]{16}', epoch) and
                    re.fullmatch(r'\d{1,20}', seq) and
                    re.fullmatch(r'\d{1,10}', size)):
                key = (epoch, int(seq), int(size))
                if marker == 'media.cell.sample ' and fields.get('stage') in STAGES:
                    cells.append((fields['stage'], key))
                elif marker == 'ipc.rt_trace.sealed_sample ' and fields.get('stage') == 'relay_queued':
                    queued.add(key)
    return cells, begins, fresh, late, unrelated, queued, cancelled


def summarize(phone_text, windows_text):
    parsed = {'phone': _parse(phone_text), 'windows': _parse(windows_text)}
    result = {'schema': 'xveil-media-probe-capture/1', 'endpoints': {},
              'absenceProvesNetworkLoss': False,
              'oneWayLatencyQualified': False,
              'consoleCaptureCompletenessVerified': False}
    for role, other, text in [('phone', 'windows', phone_text),
                              ('windows', 'phone', windows_text)]:
        cells, begins, fresh, late, unrelated, queued, cancelled = parsed[role]
        received = {key for stage, key in parsed[other][0] if stage == 'received'}
        initial = {key for stage, key in cells
                   if stage == 'relay_send' and key[1:] == (1, 60)}
        # Length alone does not identify a control: the body is encrypted.
        result['endpoints'][role] = {
            'sampleRecords': len(cells),
            'stages': {stage: sum(s == stage for s, _ in cells) for stage in STAGES},
            'probeBegins': len(begins),
            'begunAttemptsWithFreshMatchingReply': len(begins & fresh),
            'begunAttemptsWithLateMatchingReply': len(begins & late),
            'begunAttemptsWithCancelledMatchingReply': len(begins & cancelled),
            'unrelatedReplyObservations': unrelated,
            'initial60ByteRelaySamples': len(initial),
            'initialSamplesWithLocalRelayQueueWitness': len(initial & queued),
            'initialSamplesObservedAtOtherEndpoint': len(initial & received),
            'initialSamplesNotObservedAtOtherEndpoint': len(initial - received),
            'reportedConsoleDropNotices': text.count('observability.console_dropped'),
        }
    return result


def main():
    try:
        if len(sys.argv) != 3:
            raise ValueError('two bounded captures required')
        inputs = []
        for name in sys.argv[1:]:
            with Path(name).open('rb') as source:
                data = source.read(MAX_BYTES + 1)
            if len(data) > MAX_BYTES:
                raise ValueError('capture too large')
            inputs.append(data.decode('utf-8', errors='replace'))
        report = summarize(*inputs)
    except (ValueError, OSError):
        print('Invalid endpoint captures; private input not echoed.', file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
