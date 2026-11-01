"""Summarize a private call capture without exporting IDs, paths or contents."""
import json
import sys
from pathlib import Path


def inspect(document):
    events = {item['kind']: item['at'] for item in document.get('events', [])}
    start = events.get('five-fresh-samples')
    mode = {'denied': 'relay', 'allowed': 'p2p'}.get(document.get('mode'))
    initial = next((item.get('call', {}).get('callId')
                    for item in document.get('samples', [])
                    if item.get('role') == 'phone' and item.get('call')), None)
    result = {'mode': mode, 'incomingSeconds': events.get('incoming'),
              'strictFreshRxQualified': False, 'endpoints': {}}
    if start is None or mode is None or not initial:
        return result
    valid = events.get('sustained-observation-complete', start) - start >= 20
    for role in ('mac', 'phone'):
        rows = [row.get('call', {}) for row in document.get('samples', [])
                if row.get('role') == role and row.get('at', -1) >= start]
        ages = [(row.get('mediaStats') or {}).get('audio_rx_native_age_ms', -1)
                for row in rows]
        stale = sum(not (0 <= age <= 1000) for age in ages)
        correct = bool(rows) and all(
            row.get('callId') == initial and row.get('status') == 'active'
            and row.get('transport') == mode
            and (row.get('mediaStats') or {}).get('audio_rx_pkts', 0) > 0
            for row in rows)
        result['endpoints'][role] = {
            'samples': len(rows), 'staleRxSamples': stale,
            'maxRxAgeMs': max(ages) if ages else None,
            'allSameActiveCallAndTransport': correct,
        }
        valid = valid and correct and len(rows) >= 5 and stale == 0
    # The old driver's qualified flag is deliberately not authoritative: it
    # waited 20 s after the first five fresh samples, even if later RX stalled.
    result['strictFreshRxQualified'] = bool(valid)
    return result


if __name__ == '__main__':
    print(json.dumps(inspect(json.loads(Path(sys.argv[1]).read_text())), indent=2))
