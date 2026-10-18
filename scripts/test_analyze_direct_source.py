import unittest

from analyze_direct_source import attribute


class DirectSourceTest(unittest.TestCase):
    def setUp(self):
        self.native = [dict(ssrc=7, seq=8, timestamp=9, payload=10, result=0, at_us=1000),
                       dict(ssrc=7, seq=8, timestamp=9, payload=10, result=0, at_us=5000)]
        self.sealed = dict(stage='sealed', ssrc='7', rtp_seq='8', timestamp='9',
                           payload_bytes='10', monotonic_us='1100', epoch='1234567890abcdef', seq='20')
        self.decision = dict(epoch=self.sealed['epoch'], seq='20', local_slot='2',
                             monotonic_us='1200', connection_trace_id='0')

    def test_actual_child_and_budget_rejections_are_distinct(self):
        for reason in ['child_unavailable', 'budget_drop']:
            result = attribute(self.native, [self.sealed], [dict(self.decision, stage=reason)])
            self.assertEqual(result['source_verdict'], reason)
            self.assertEqual(result['native_to_seal_ms'], .1)

    def test_transport_admission_requires_both_positive_witnesses(self):
        rows = [dict(self.decision, stage='budget_admit'),
                dict(self.decision, stage='datagram_accepted', connection_trace_id='22')]
        self.assertEqual(attribute(self.native, [self.sealed], rows)['source_verdict'],
                         'accepted_by_local_transport')
        self.assertEqual(attribute(self.native, [self.sealed], rows[:1])['source_verdict'],
                         'no_complete_transport_admission_witness')

    def test_a_later_retransmission_cannot_explain_the_original_attempt(self):
        later = dict(self.sealed, monotonic_us='5100')
        with self.assertRaisesRegex(ValueError, 'seal'):
            attribute(self.native, [later], [dict(self.decision, stage='budget_drop')])

    def test_missing_mixed_foreign_or_ambiguous_witnesses_are_rejected(self):
        rows = [dict(self.decision, stage='budget_drop'),
                dict(self.decision, stage='datagram_accepted')]
        for seals, decisions in [([], rows[:1]), ([self.sealed, self.sealed], rows[:1]),
                                  ([self.sealed], []), ([self.sealed], rows),
                                  ([self.sealed], [dict(rows[0], local_slot='1')])]:
            with self.assertRaises(ValueError): attribute(self.native, seals, decisions)


if __name__ == '__main__': unittest.main()
