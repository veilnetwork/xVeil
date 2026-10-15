import json
import unittest

from analyze_primary_hops import analyze
from opaque_frame_capture import sanitize


IDS = [bytes([i + 1]) * 32 for i in range(3)]
KNOWN = {value.hex(): i for i, value in enumerate(IDS)}
SUMMARY = dict(loopback_only=True, stand_start_monotonic_us=0, duration_seconds=90,
               opaque_frame_capture_start_seconds=1)


def captured(source, target, direction, at, origin=1, recipient=2, sequence=50):
    # veil-proto's Forward: next hop + 197-byte envelope + VME1 + suffix.
    body = bytearray(32 + 197 + 36 + 9)
    body[:32] = IDS[recipient]
    body[32:64] = IDS[recipient]
    body[81:113] = IDS[origin]
    body[225:229] = (36).to_bytes(4, 'big')
    body[229:233] = b'VME1'
    body[233:241] = (7).to_bytes(8, 'big')
    body[241:249] = sequence.to_bytes(8, 'big')
    event = dict(e2e_plaintext=False, src_id=IDS[source].hex(), dst_id=IDS[target].hex(),
                 direction=direction, ts_us=at, family=3, msg_type=3,
                 body_len=len(body), body_hex=body[:256].hex())
    observer = source if direction == 'tx' else target
    result, error = sanitize(event, observer, KNOWN)
    assert error is None
    return result, event


def path(origin=1, target=2):
    return [captured(*args, origin=origin, recipient=target)[0] for args in [
        (origin, 0, 'tx', 20_000_000), (origin, 0, 'rx', 20_040_000),
        (0, target, 'tx', 20_041_000), (0, target, 'rx', 20_066_000)]]


def evidence(rows):
    return dict(format='xveil-opaque-frame-capture-v1', expected_nodes=3,
                clock=dict(monotonic_us=0, wall_us=0, uncertainty_us=1), rows=rows,
                ack_nodes=[0, 1, 2], reader_errors=[], readers_exited=True,
                capture_limit_reached_nodes=[])


def witness(row, slot=0):
    return (f'media.source_cell_trace at_unix_us=20000000 stage=budget_admit local_slot={slot} '
            f'family=3 msg_type=3 body_len={row["body_len"]} '
            f'body_preview_sha256={row["preview_sha256"]}')


class PrimaryHopTest(unittest.TestCase):
    def test_only_endpoint_witness_establishes_primary_role(self):
        rows = path() + path(2, 1)  # Same epoch/sequence, different origin.
        for logs in [[], [witness(rows[0], 1)]]:
            self.assertEqual(analyze(SUMMARY, evidence(rows), logs)['matched_route_cells'], 0)
        result = analyze(SUMMARY, evidence(rows), [witness(rows[0])])
        self.assertEqual(result['matched_route_cells'], 1)
        peak = result['largest_cells'][0]
        self.assertEqual((peak['source'], peak['target']), (1, 2))
        self.assertEqual([peak[k] for k in ['source_to_relay_ms', 'relay_residence_ms',
                                          'relay_to_target_ms', 'total_ms']], [40, 1, 25, 66])
        self.assertFalse(result['full_body_equality_proof'])
        self.assertNotIn(rows[0]['preview_sha256'], json.dumps(result))
        self.assertNotIn('epoch', json.dumps(result))

    def test_missing_and_repeated_cells_do_not_become_guessed_routes(self):
        rows = path()
        incomplete = analyze(SUMMARY, evidence(rows[:-1]), [witness(rows[0])])
        self.assertEqual(incomplete['matched_route_cells'], 0)
        self.assertEqual(incomplete['incomplete_route_cells'], 1)
        self.assertTrue(incomplete['missing_observations_are_not_loss'])
        ambiguous = analyze(SUMMARY, evidence(rows + [rows[0]]), [witness(rows[0])])
        self.assertEqual(ambiguous['matched_route_cells'], 0)
        self.assertEqual(ambiguous['ambiguous_route_cells'], 1)
        rows[2] = dict(rows[2], at_us=20_039_000)
        with self.assertRaisesRegex(ValueError, 'inverted'):
            analyze(SUMMARY, evidence(rows), [witness(rows[0])])

    def test_nonce_extraction_requires_known_routing_and_complete_header(self):
        row, original = captured(1, 0, 'tx', 1)
        self.assertEqual(row['seal'], dict(source=1, target=2, epoch='0000000000000007', sequence=50))
        for change in [dict(family=4), dict(body_len=260),
                       dict(body_hex=bytes.fromhex(original['body_hex'])[:248].hex())]:
            value, reason = sanitize(dict(original, **change), 1, KNOWN)
            self.assertIsNone(reason)
            self.assertNotIn('seal', value)
        for begin, end, value in [(229, 233, b'nope'), (81, 113, b'\xff' * 32),
                                  (241, 249, b'\0' * 8)]:
            preview = bytearray.fromhex(original['body_hex'])
            preview[begin:end] = value
            parsed, reason = sanitize(dict(original, body_hex=preview.hex()), 1, KNOWN)
            self.assertIsNone(reason)
            self.assertNotIn('seal', parsed)

    def test_trace_and_capture_truncation_are_reported(self):
        rows = path()
        capture = evidence(rows)
        capture['capture_limit_reached_nodes'] = [0]
        result = analyze(SUMMARY, capture, [witness(rows[0]), 'media.source_trace_limit rows=65536'])
        self.assertTrue(result['source_trace_limit_reached'])
        self.assertEqual(result['capture_limit_reached_nodes'], [0])
        self.assertEqual(result['observed_ranges_seconds']['0'], [20.04, 20.041])

    def test_witness_coverage_distinguishes_capture_boundary_from_missing_rows(self):
        rows = path()
        missing = witness(dict(rows[0], preview_sha256='0' * 64))
        early = missing.replace('at_unix_us=20000000', 'at_unix_us=500000')
        result = analyze(SUMMARY, evidence(rows), [witness(rows[0]), early])
        self.assertEqual(result['uncaptured_source_witnesses'], 1)
        self.assertEqual(result['uncaptured_witness_range_seconds'], [0.5, 0.5])
        self.assertEqual(result['uncaptured_source_witnesses_in_window'], 0)
        result = analyze(SUMMARY, evidence(rows), [witness(rows[0]), missing])
        self.assertEqual(result['uncaptured_source_witnesses_in_window'], 1)
        self.assertEqual(result['source_witnesses_without_clock'], 0)
        result = analyze(SUMMARY, evidence(rows), [witness(rows[0]).replace('at_unix_us=20000000 ', '')])
        self.assertEqual(result['source_witnesses_without_clock'], 1)

    def test_observed_body_length_joins_receive_headers_with_session_tags(self):
        row, event = captured(1, 0, 'tx', 20_000_000)
        incoming = dict(event, direction='rx', ts_us=20_040_000,
                        body_len=event['body_len'] + 16, observed_body_len=event['body_len'])
        received, reason = sanitize(incoming, 0, KNOWN)
        self.assertIsNone(reason)
        self.assertEqual(received['body_len'], row['body_len'])
        self.assertEqual(received['wire_body_len'], row['body_len'] + 16)
        rows = path()
        rows[1] = received
        result = analyze(SUMMARY, evidence(rows), [witness(row)])
        self.assertEqual(result['matched_route_cells'], 1)
        # An old capture without the observed length remains unknown; never
        # guess that a 16-byte difference must be a session tag.
        del incoming['observed_body_len']
        old, reason = sanitize(incoming, 0, KNOWN)
        self.assertIsNone(reason)
        self.assertNotIn('seal', old)

    def test_cell_framing_uses_validated_length_without_guessing_rtp_count(self):
        rows = path()
        self.assertEqual(rows[0]['sealed_payload_bytes'], 36)
        result = analyze(SUMMARY, evidence(rows), [witness(rows[0])])
        cost = result['source_cell_framing']
        self.assertEqual(cost['measured_cells'], 1)
        self.assertEqual(cost['delivery_wrapper_counts'], {238: 1})
        self.assertEqual(cost['ovl_frame_bytes'], 36 + 238 + 24)
        self.assertTrue(cost['excludes_session_codec_carrier_padding_and_ip'])
        self.assertTrue(cost['cells_are_not_rtp_packets'])
        # Legacy records and ambiguous duplicate observations provide no size.
        del rows[0]['sealed_payload_bytes']
        legacy = analyze(SUMMARY, evidence(rows), [witness(rows[0])])['source_cell_framing']
        self.assertEqual(legacy['measured_cells'], 0)
        self.assertEqual(legacy['unknown_or_ambiguous_cells'], 1)
        rows = path()
        self.assertEqual(analyze(SUMMARY, evidence(rows + [rows[0]]), [witness(rows[0])])[
            'source_cell_framing']['measured_cells'], 0)
        rows[0]['sealed_payload_bytes'] = rows[0]['body_len']
        with self.assertRaisesRegex(ValueError, 'wrapper'):
            analyze(SUMMARY, evidence(rows), [witness(rows[0])])


if __name__ == '__main__':
    unittest.main()
