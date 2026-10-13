"""Same-host publication timing; legacy wall mappings remain approximate."""
import re


def publication_timing(log, start_monotonic_us, duration_seconds, clock_observations):
    offsets = [row['unix_us'] - row['monotonic_us'] for row in clock_observations]
    events = []
    invalid_monotonic = 0
    for match in re.finditer(
        r'node\.sovereign_identity\.replication[^\n]*?reason=([a-z_]+)\s+'
        r'wall_unix_ms=(\d+)(?:\s+monotonic_us=(\d+))?', log
    ):
        reason, wall_ms, mono_us = match.groups()
        mono_seconds = (int(mono_us) - start_monotonic_us) / 1e6 if mono_us else None
        # The Unix stand clock domains are tested in the SDK. Reject a clearly
        # foreign absolute origin (e.g. Darwin's sleep-inclusive clock) rather
        # than turning its value into a precise-looking event.
        if mono_seconds is not None and not -60 <= mono_seconds <= duration_seconds + 60:
            invalid_monotonic += 1
            mono_seconds = None
        if mono_seconds is not None:
            event = {'reason': reason, 'at_seconds': round(mono_seconds, 6),
                     'clock': 'same_host_monotonic', 'timestamp_resolution_us': 1}
        elif offsets:
            event = {'reason': reason, 'at_seconds': round(
                (int(wall_ms) * 1000 - offsets[0] - start_monotonic_us) / 1e6, 3),
                'clock': 'legacy_wall_mapping', 'timestamp_resolution_us': 1000}
        else:
            event = {'reason': reason, 'at_seconds': None,
                     'clock': 'unknown', 'timestamp_resolution_us': None}
        events.append(event)
    return {
        'available': bool(events),
        'timestamp_resolution_us': events[0]['timestamp_resolution_us'] if events and all(e['clock'] == events[0]['clock'] for e in events) else None,
        'clock_offset_change_us': offsets[-1] - offsets[0] if offsets else None,
        'monotonic_events': sum(e['clock'] == 'same_host_monotonic' for e in events),
        'wall_mapped_events': sum(e['clock'] == 'legacy_wall_mapping' for e in events),
        'invalid_monotonic_markers': invalid_monotonic,
        'events': events,
    }
