import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from analyze_tcp_connect_candidates import ClockBounds, EvidenceError, analyze


def calibration(offset=0, error=2, resolution=1):
    return {'kind': 'monotonic', 'drift_ppb': 0, 'resolution_ns': resolution,
            'samples': [dict(local_before_ns=t, local_after_ns=t,
                             reference_before_ns=t + offset - error,
                             reference_after_ns=t + offset + error)
                        for t in (100, 10_000)]}


def fixture():
    core = dict(calibration(offset=1000), kind='realtime', target=1)
    return {'schema': 'xveil-tcp-connect-evidence/1', 'single_process_capture': True,
            'clocks': {'phone': calibration(), 'cores': [core]},
            'slot_targets': [{'slot': 9, 'target': 1}],
            'contexts': [{'id': 200, 'slot': 9, 'start_ns': 2000,
                          'fixed_target_direct_only': True}],
            'connections': [{'id': 300, 'context': 200, 'start_ns': 3000}],
            'flows': [{'id': 400, 'target': 1, 'syn_ns': 1100,
                       'synack_ns': 1200, 'client_payload_bytes': 0}]}


class ClockTests(unittest.TestCase):
    def test_round_trip_bounds_not_midpoint_or_wall_clock_assumption(self):
        c = calibration(offset=1000, error=40)
        bounds = ClockBounds(c['samples'], 0)
        self.assertEqual(bounds.at(2000), (2960, 3040))

    def test_resolution_includes_the_entire_truncated_timestamp_tick(self):
        c = calibration()
        self.assertEqual(ClockBounds(c['samples'], 0, 1000).at(2000), (1998, 3001))
        with self.assertRaises(EvidenceError):
            ClockBounds(c['samples'], 0, 1000).at(9500)

    def test_clock_step_contradiction_and_backward_or_overlapping_samples(self):
        for mutate in ('step', 'backward', 'overlap', 'reversed'):
            c = calibration()
            if mutate == 'step':
                c['samples'][1]['reference_before_ns'] += 200
                c['samples'][1]['reference_after_ns'] += 200
            elif mutate == 'backward':
                c['samples'][1]['local_before_ns'] = 50
                c['samples'][1]['local_after_ns'] = 50
            elif mutate == 'overlap':
                c['samples'][1] = dict(c['samples'][0])
            else:
                c['samples'][0]['reference_after_ns'] = 0
            with self.subTest(mutate=mutate), self.assertRaises(EvidenceError):
                ClockBounds(c['samples'], 0)

    def test_unbracketed_event_and_missing_calibration_rejected(self):
        c = calibration()
        bounds = ClockBounds(c['samples'], 0)
        for t in (99, 10_001):
            with self.assertRaises(EvidenceError): bounds.at(t)
        with self.assertRaises(EvidenceError): ClockBounds(c['samples'][:1], 0)

    def test_explicit_drift_tolerates_bounded_slew_but_not_large_step(self):
        c = calibration(error=0)
        c['samples'][1]['reference_before_ns'] += 1
        c['samples'][1]['reference_after_ns'] += 1
        bounds = ClockBounds(c['samples'], 200_000)
        lo, hi = bounds.at(5000)
        self.assertLessEqual(lo, 5000)
        self.assertGreaterEqual(hi, 5001)
        with self.assertRaises(EvidenceError): ClockBounds(c['samples'], 0)

    def test_invalid_precision_drift_bool_and_noninteger_rejected(self):
        c = calibration()
        for drift, resolution in ((True, 1), (-1, 1), (1_000_001, 1), (0, 0), (0, 1.5)):
            with self.subTest(drift=drift, resolution=resolution), self.assertRaises(EvidenceError):
                ClockBounds(c['samples'], drift, resolution)


class CandidateTests(unittest.TestCase):
    def test_unique_expected_target_temporal_candidate_is_not_delivery_proof(self):
        result = analyze(fixture())
        self.assertEqual(result['mutually_unique_temporal_candidates'], 1)
        self.assertEqual(result['unique_candidates_without_server_payload'], 1)
        self.assertTrue(result['not_identity_delivery_or_loss_attribution'])
        self.assertNotIn('id', result)

    def test_no_invented_short_timeout_excludes_slow_candidate(self):
        f = fixture()
        # Units are ns; stretch every clock/event while preserving relationships.
        for clock in [f['clocks']['phone'], *f['clocks']['cores']]:
            for sample in clock['samples']:
                for key in sample: sample[key] *= 1_000_000_000
        for row in f['contexts']: row['start_ns'] *= 1_000_000_000
        for row in f['connections']: row['start_ns'] *= 1_000_000_000
        for row in f['flows']:
            row['syn_ns'] *= 1_000_000_000
            row['synack_ns'] *= 1_000_000_000
        self.assertEqual(analyze(f)['mutually_unique_temporal_candidates'], 1)

    def test_causal_impossibility_excluded_and_uncertainty_overlap_retained(self):
        f = fixture()
        f['flows'][0].update(syn_ns=900, synack_ns=1000)
        self.assertEqual(analyze(f)['without_temporal_candidate'], 1)
        f['flows'][0].update(syn_ns=998, synack_ns=1100)
        self.assertEqual(analyze(f)['mutually_unique_temporal_candidates'], 1)
        f['flows'][0].update(syn_ns=1900, synack_ns=2100)
        self.assertEqual(analyze(f)['without_temporal_candidate'], 1)

    def test_parallel_primary_backup_or_auxiliary_never_greedily_assigned(self):
        f = fixture()
        f['connections'].append(dict(f['connections'][0], id=301))
        result = analyze(f)
        self.assertEqual(result['mutually_unique_temporal_candidates'], 0)
        self.assertEqual(result['ambiguous_connections'], 2)
        f['flows'].append(dict(f['flows'][0], id=401))
        self.assertEqual(analyze(f)['mutually_unique_temporal_candidates'], 0)

    def test_singleton_sharing_with_a_multicandidate_remains_ambiguous(self):
        f = fixture()
        f['connections'].append(dict(f['connections'][0], id=301, start_ns=5000))
        f['flows'].append(dict(f['flows'][0], id=401, syn_ns=2900, synack_ns=3000))
        result = analyze(f)
        self.assertEqual(result['ambiguous_connections'], 2)
        self.assertEqual(result['mutually_unique_temporal_candidates'], 0)

    def test_target_disambiguates_without_using_nat_ports_or_guessed_identity(self):
        f = fixture()
        f['clocks']['cores'].append(dict(f['clocks']['cores'][0], target=2))
        f['flows'].append(dict(f['flows'][0], target=2, id=401))
        result = analyze(f)
        self.assertEqual(result['mutually_unique_temporal_candidates'], 1)
        self.assertEqual(result['flows_without_connection_candidate'], 1)

    def test_missing_context_changed_slot_and_fallback_are_excluded(self):
        for scenario in ('context', 'slot', 'changed', 'fallback'):
            f = fixture()
            if scenario == 'context': f['connections'][0]['context'] = None
            elif scenario == 'slot': f['slot_targets'] = []
            elif scenario == 'changed': f['slot_targets'].append({'slot': 9, 'target': 2})
            else: f['contexts'][0]['fixed_target_direct_only'] = False
            with self.subTest(scenario=scenario):
                r = analyze(f)
                self.assertEqual(r['eligible_connections'], 0)
                self.assertEqual(sum(r['excluded_connections'].values()), 1)

    def test_unscoped_competitor_blocks_a_false_unique_candidate(self):
        for scenario in ('context', 'slot', 'fallback'):
            f = fixture()
            second = dict(f['connections'][0], id=301, context=201)
            f['connections'].append(second)
            ctx = dict(f['contexts'][0], id=201)
            f['contexts'].append(ctx)
            if scenario == 'context': second['context'] = None
            elif scenario == 'slot': ctx['slot'] = 10
            else: ctx['fixed_target_direct_only'] = False
            with self.subTest(scenario=scenario):
                r = analyze(f)
                self.assertEqual(r['eligible_connections'], 1)
                self.assertEqual(r['mutually_unique_temporal_candidates'], 0)
                self.assertEqual(r['ambiguous_connections'], 1)
                self.assertEqual(r['unscoped_connections_with_possible_flows'], 1)

    def test_unscoped_competitor_causally_too_early_does_not_block(self):
        f = fixture()
        f['connections'].append({'id': 301, 'context': None, 'start_ns': 1000})
        r = analyze(f)
        self.assertEqual(r['mutually_unique_temporal_candidates'], 1)
        self.assertEqual(r['unscoped_connections_with_possible_flows'], 0)

    def test_unknown_scope_clock_kind_duplicates_and_bad_order_fail_closed(self):
        for scenario in ('process', 'clock', 'duplicate', 'order', 'coverage', 'no_core'):
            f = fixture()
            if scenario == 'process': f['single_process_capture'] = False
            elif scenario == 'clock': f['clocks']['phone']['kind'] = 'boottime'
            elif scenario == 'duplicate': f['connections'] *= 2
            elif scenario == 'order': f['connections'][0]['start_ns'] = 1000
            elif scenario == 'coverage': f['connections'][0]['start_ns'] = 10_001
            else: f['clocks']['cores'] = []
            with self.subTest(scenario=scenario), self.assertRaises(EvidenceError): analyze(f)

    def test_aggregate_output_cannot_export_raw_private_fields(self):
        f = fixture()
        # Unknown metadata may contain sensitive input; it is never copied out.
        for row in [f, *f['contexts'], *f['connections'], *f['flows']]:
            row['private_canary'] = 'RAW_PRIVATE_DIAGNOSTIC_CANARY'
        encoded = json.dumps(analyze(f))
        self.assertNotIn('RAW_PRIVATE_DIAGNOSTIC_CANARY', encoded)
        for key in ('context', 'slot', 'connection', 'syn_ns', 'address', 'port'):
            self.assertNotIn('"' + key + '"', encoded)

    def test_empty_observation_is_explicit_not_vacuous_success(self):
        f = fixture()
        f['connections'] = []
        f['flows'] = []
        r = analyze(f)
        self.assertFalse(r['has_observations_on_both_sides'])
        self.assertEqual(r['mutually_unique_temporal_candidates'], 0)

    def test_cli_success_emits_only_aggregate_json(self):
        script = Path(__file__).with_name('analyze_tcp_connect_candidates.py')
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'evidence.json'
            path.write_text(json.dumps(fixture()))
            p = subprocess.run([sys.executable, str(script), str(path)],
                               capture_output=True, text=True)
            self.assertEqual(p.returncode, 0)
            self.assertEqual(p.stderr, '')
            self.assertEqual(json.loads(p.stdout), analyze(fixture()))

    def test_cli_invalid_private_path_and_json_never_leak_error_detail(self):
        script = Path(__file__).with_name('analyze_tcp_connect_candidates.py')
        with tempfile.TemporaryDirectory() as folder:
            private = Path(folder) / 'RAW_PRIVATE_PATH_CANARY.json'
            for content in (None, '{"RAW_PRIVATE_JSON_CANARY": bad}', '{}', '[]',
                            json.dumps(dict(fixture(), clocks=[]))):
                if content is not None: private.write_text(content)
                p = subprocess.run([sys.executable, str(script), str(private)],
                                   capture_output=True, text=True)
                self.assertEqual(p.returncode, 2)
                self.assertEqual(p.stdout, '')
                self.assertEqual(p.stderr.strip(), 'Invalid or incomplete private TCP evidence')


if __name__ == '__main__': unittest.main()
