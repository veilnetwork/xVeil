#!/usr/bin/env python3
"""Conservative offline TCP candidates from private, normalized capture evidence.

No addresses/ports are joined across NAT. IDs are scoped to one declared process
and capture; input is private operator evidence, not an anonymous diagnostic file.
The result contains aggregate counts only. A unique temporal candidate does not
prove remote identity, delivery, or that missing packets caused an audio pause.
"""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import sys


class EvidenceError(ValueError):
    """Messages deliberately contain no input values, IDs, or file paths."""


def integer(value):
    if type(value) is not int or value < 0:
        raise EvidenceError('Expected a nonnegative integer')
    return value


def records_by_id(rows):
    result = {}
    for row in rows:
        key = integer(row['id'])
        if key in result:
            raise EvidenceError('Duplicate identifier within capture scope')
        result[key] = row
    return result


class ClockBounds:
    """Map local ns to collector CLOCK_MONOTONIC ns using round-trip bounds.

    Samples bracket a remote clock read with local_before/after_ns and collector
    reference_before/after_ns. No midpoint estimate or NTP assumption is used.
    The explicit drift allowance is in ppb of elapsed local time; events outside
    calibration coverage are rejected. Phone uses CLOCK_MONOTONIC, server PCAP
    uses CLOCK_REALTIME. Both must refer to this same collector clock/scope.
    """
    def __init__(self, samples, drift_ppb, resolution_ns=1):
        self.resolution = integer(resolution_ns)
        if not 1 <= self.resolution <= 1_000_000_000:
            raise EvidenceError('Invalid clock event resolution')
        self.drift = integer(drift_ppb)
        if self.drift > 1_000_000:
            raise EvidenceError('Clock drift allowance is too broad')
        self.samples = []
        for sample in samples:
            a, b, c, d = [integer(sample[k]) for k in (
                'local_before_ns', 'local_after_ns',
                'reference_before_ns', 'reference_after_ns')]
            if a > b or c > d:
                raise EvidenceError('Reversed clock sample interval')
            self.samples.append((a, b, c, d))
        if len(self.samples) < 2:
            raise EvidenceError('Clock needs before and after calibration')
        self.samples.sort(key=lambda s: s[2])
        for left, right in zip(self.samples, self.samples[1:]):
            if left[3] >= right[2] or left[1] >= right[0]:
                raise EvidenceError('Clock samples overlap or clock moved backwards')
        # Contradictory calibrations (e.g. a realtime clock step) are rejected
        # even when the event happens to be close to one endpoint sample.
        for sample in self.samples:
            self._map(sample[0])
            self._map(sample[1])

    def _map(self, stamp):
        intervals = []
        for a, b, c, d in self.samples:
            distance = max(abs(stamp - a), abs(stamp - b))
            padding = (distance * self.drift + 999_999_999) // 1_000_000_000
            intervals.append((stamp + c - b - padding,
                              stamp + d - a + padding))
        lo = max(i[0] for i in intervals)
        hi = min(i[1] for i in intervals)
        if lo > hi:
            raise EvidenceError('Clock calibrations are inconsistent')
        return lo, hi

    def at(self, stamp):
        stamp = integer(stamp)
        end = stamp + self.resolution - 1
        if not self.samples[0][1] <= stamp <= end <= self.samples[-1][0]:
            raise EvidenceError('Event is not bracketed by clock calibration')
        return self._map(stamp)[0], self._map(end)[1]


def analyze(evidence):
    if evidence.get('schema') != 'xveil-tcp-connect-evidence/1':
        raise EvidenceError('Unsupported evidence schema')
    if evidence.get('single_process_capture') is not True:
        raise EvidenceError('Requires one phone process and one capture scope')
    clocks = evidence['clocks']
    if clocks['phone'].get('kind') != 'monotonic':
        raise EvidenceError('Phone trace requires CLOCK_MONOTONIC calibration')
    phone = ClockBounds(clocks['phone']['samples'], clocks['phone']['drift_ppb'],
                        clocks['phone']['resolution_ns'])
    cores = {}
    for row in clocks['cores']:
        target = integer(row['target'])
        if target in cores or row.get('kind') != 'realtime':
            raise EvidenceError('Core clock target or clock kind invalid')
        cores[target] = ClockBounds(row['samples'], row['drift_ppb'], row['resolution_ns'])

    # Only explicit stable mappings of expected local slots are admitted.
    # Missing or changed slots remain unresolved; no target is guessed by time.
    targets = defaultdict(set)
    for row in evidence['slot_targets']:
        targets[integer(row['slot'])].add(integer(row['target']))
    contexts = records_by_id(evidence['contexts'])
    connections = records_by_id(evidence['connections'])
    flows = records_by_id(evidence['flows'])
    flow_times = {}
    for fid, row in flows.items():
        target = integer(row['target'])
        if target not in cores:
            raise EvidenceError('Flow lacks target clock calibration')
        syn = integer(row['syn_ns'])
        synack = integer(row['synack_ns'])
        if syn > synack:
            raise EvidenceError('Flow SYN/SYNACK order invalid')
        integer(row['client_payload_bytes'])
        flow_times[fid] = (cores[target].at(syn), cores[target].at(synack))

    candidates = {}
    unscoped = {}
    excluded = Counter()
    physical_clocks = 0

    def compatible(beginning, connected, target=None):
        edges = set()
        for fid, flow in flows.items():
            if target is not None and flow['target'] != target:
                continue
            syn, synack = flow_times[fid]
            # Existential causal bounds only, not overlapping midpoint buckets:
            # context <= server SYN <= server SYNACK <= handshake observer.
            # No invented RTT/handshake timeout is used as a matching window.
            if (beginning is None or beginning[0] <= syn[1]) and synack[0] <= connected[1]:
                edges.add(fid)
        return edges

    for cid, row in connections.items():
        start = integer(row['start_ns'])
        connected = phone.at(start)
        dial_start = row.get('dial_start_ns')
        physical_beginning = None
        if dial_start is not None:
            dial_start = integer(dial_start)
            if dial_start > start:
                raise EvidenceError('Physical connect begins after its observer')
            physical_beginning = phone.at(dial_start)
            physical_clocks += 1
        context_id = row.get('context')
        context = contexts.get(integer(context_id)) if context_id is not None else None
        if context is None:
            excluded['missing_context'] += 1
            unscoped[cid] = compatible(physical_beginning, connected)
            continue
        origin = integer(context['start_ns'])
        if origin > start:
            raise EvidenceError('Connection precedes its logical context')
        if dial_start is not None and dial_start < origin:
            raise EvidenceError('Physical connect precedes its logical context')
        beginning = physical_beginning if physical_beginning is not None else phone.at(origin)
        slot = integer(context['slot'])
        mapped = targets[slot]
        if len(mapped) != 1:
            excluded['missing_or_changed_slot'] += 1
            unscoped[cid] = compatible(beginning, connected)
            continue
        if context.get('fixed_target_direct_only') is not True:
            # A fallback/dynamic address can differ from the expected peer row.
            excluded['unverified_target_scope'] += 1
            unscoped[cid] = compatible(beginning, connected)
            continue
        target = next(iter(mapped))
        if target not in cores:
            raise EvidenceError('Context target lacks clock calibration')
        candidates[cid] = compatible(beginning, connected, target)

    # Unknown target/context is not permission to discard a competing socket.
    # Such a socket can block uniqueness but can never earn an attribution.
    reverse = Counter(fid for edges in [*candidates.values(), *unscoped.values()]
                      for fid in edges)
    unique = [(cid, next(iter(edges))) for cid, edges in candidates.items()
              if len(edges) == 1 and reverse[next(iter(edges))] == 1]
    # Deliberately do not greedily remove a selected flow and force later rows.
    # A second socket sharing the only candidate leaves both unresolved.
    return {
        'schema': 'xveil-tcp-connect-candidates/1',
        'temporal_candidates_only': True,
        'not_identity_delivery_or_loss_attribution': True,
        'has_observations_on_both_sides': bool(connections and flows),
        'phone_connections': len(connections),
        'server_flows': len(flows),
        'eligible_connections': len(candidates),
        'connections_with_physical_dial_clock': physical_clocks,
        'excluded_connections': dict(sorted(excluded.items())),
        'unscoped_connections_with_possible_flows': sum(bool(v) for v in unscoped.values()),
        'without_temporal_candidate': sum(not edges for edges in candidates.values()),
        'ambiguous_connections': sum(bool(edges) for edges in candidates.values()) - len(unique),
        'mutually_unique_temporal_candidates': len(unique),
        'unique_candidates_without_server_payload': sum(
            flows[fid]['client_payload_bytes'] == 0 for _, fid in unique),
        'flows_without_connection_candidate': sum(fid not in reverse for fid in flows),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('evidence', type=Path)
    args = parser.parse_args()
    try:
        result = analyze(json.loads(args.evidence.read_text()))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError, OverflowError):
        # Do not expose filenames, raw decoder errors, IDs, or addresses.
        print('Invalid or incomplete private TCP evidence', file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
