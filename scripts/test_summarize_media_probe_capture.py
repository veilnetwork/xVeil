import json
import unittest

from summarize_media_probe_capture import summarize


def cell(stage, epoch='aabbccdd00112233', seq=1, size=60):
    return (f'media.cell.sample at_ms=123 stage={stage} peer=PRIVATE_PEER '
            f'epoch={epoch} seq={seq} bytes={size}\n')


class ProbeCaptureTest(unittest.TestCase):
    def test_exact_headers_match_across_hosts_without_clock_comparison(self):
        report = summarize(cell('relay_send'), cell('received').replace('=123', '=999'))
        phone = report['endpoints']['phone']
        self.assertEqual(phone['initialSamplesObservedAtOtherEndpoint'], 1)
        self.assertFalse(report['oneWayLatencyQualified'])

    def test_wrong_epoch_sequence_or_length_does_not_match(self):
        other = (cell('received', epoch='11223344aabbccdd') +
                 cell('received', seq=2) + cell('received', size=61))
        report = summarize(cell('relay_send'), other)
        self.assertEqual(report['endpoints']['phone']['initialSamplesObservedAtOtherEndpoint'], 0)
        self.assertFalse(report['absenceProvesNetworkLoss'])

    def test_local_relay_admission_does_not_count_as_remote_receipt(self):
        text = cell('relay_send') + cell('relay_queued').replace(
            'media.cell.sample', 'ipc.rt_trace.sealed_sample')
        phone = summarize(text, '')['endpoints']['phone']
        self.assertEqual(phone['initialSamplesWithLocalRelayQueueWitness'], 1)
        self.assertEqual(phone['initialSamplesObservedAtOtherEndpoint'], 0)

    def test_duplicates_do_not_multiply_cell_receipt_or_attempt_success(self):
        begin = 'media.path_probe begin id=1 route=Relay budget_us=600000\n'
        reply = ('media.path_probe reply id=1 route=Relay matches=true '
                 'status=Pending age_us=150000 budget_us=600000\n')
        report = summarize(begin + reply * 2 + cell('relay_send') * 2,
                           cell('received') * 2)
        phone = report['endpoints']['phone']
        self.assertEqual(phone['begunAttemptsWithFreshMatchingReply'], 1)
        self.assertEqual(phone['initialSamplesObservedAtOtherEndpoint'], 1)

    def test_late_and_unrelated_replies_are_not_fresh_qualification(self):
        text = ('media.path_probe begin id=1 route=Relay budget_us=600000\n'
                'media.path_probe reply id=1 route=Relay matches=false '
                'status=Expired age_us=900000 budget_us=600000\n'
                'media.path_probe reply id=1 route=Relay matches=true '
                'status=Expired age_us=900000 budget_us=600000\n')
        phone = summarize(text, '')['endpoints']['phone']
        self.assertEqual(phone['begunAttemptsWithFreshMatchingReply'], 0)
        self.assertEqual(phone['begunAttemptsWithLateMatchingReply'], 1)
        self.assertEqual(phone['unrelatedReplyObservations'], 1)

    def test_missing_begins_do_not_invent_success(self):
        text = ('media.path_probe reply id=1 route=Relay matches=true '
                'status=Pending age_us=50000 budget_us=600000\n')
        self.assertEqual(summarize(text, '')['endpoints']['phone']
                         ['begunAttemptsWithFreshMatchingReply'], 0)

    def test_cancelled_reply_is_neither_fresh_nor_a_late_network_sample(self):
        text = ('media.path_probe begin id=1 route=Relay budget_us=600000\n'
                'media.path_probe reply id=1 route=Relay matches=true '
                'status=Cancelled age_us=50000 budget_us=600000\n')
        phone = summarize(text, '')['endpoints']['phone']
        self.assertEqual(phone['begunAttemptsWithFreshMatchingReply'], 0)
        self.assertEqual(phone['begunAttemptsWithLateMatchingReply'], 0)
        self.assertEqual(phone['begunAttemptsWithCancelledMatchingReply'], 1)

    def test_empty_capture_has_no_completeness_or_delivery_claim(self):
        result = summarize('', '')
        self.assertFalse(result['consoleCaptureCompletenessVerified'])
        self.assertFalse(result['absenceProvesNetworkLoss'])
        self.assertEqual(result['endpoints']['phone']['probeBegins'], 0)

    def test_private_fields_and_unknown_stage_never_enter_output(self):
        text = (cell('relay_send').replace('\n', ' opaque_sha256=PRIVATE_DIGEST\n') +
                cell('PRIVATE_STAGE') + ' token=PRIVATE_TOKEN\n')
        output = json.dumps(summarize(text, cell('received')))
        for secret in ['aabbccdd00112233', 'PRIVATE_', 'token', 'at_ms', 'opaque_sha256']:
            self.assertNotIn(secret, output)


if __name__ == '__main__':
    unittest.main()
