import multiprocessing as mp
import threading
import time
import unittest

from group_codec_sdk import (GroupSdk, SourcePacketSamples,
                             receive_participant_values)


def request(sequence=0):
    return {'source_cost_request': {
        'sequence': sequence, 'packet_bytes': {'0': 172, '2': 520, '3': 520}}}


class GroupSourceCostTest(unittest.TestCase):
    def test_later_worker_cost_request_unblocks_first_worker_without_reordering_results(self):
        pairs = [mp.Pipe() for _ in range(2)]
        parents, clients = zip(*pairs)
        release = threading.Event()
        errors = []
        responses = []

        def first():
            if release.wait(2):
                clients[0].send({'finished': 0})

        def second():
            try:
                clients[1].send(request())
                responses.append(clients[1].recv())
                release.set()
                clients[1].send({'finished': 1})
            except BaseException as error:
                errors.append(error)

        workers = [threading.Thread(target=first), threading.Thread(target=second)]
        for worker in workers:
            worker.start()
        calls = []

        def cost(index, value):
            calls.append((index, value['packet_bytes']))
            return {'unknown_peer_model': None}

        try:
            values = receive_participant_values(parents, 1, cost)
            self.assertEqual(values, [{'finished': 0}, {'finished': 1}])
            self.assertEqual(calls, [(1, {'0': 172, '2': 520, '3': 520})])
            self.assertEqual(responses[0]['source_cost_response'], {'unknown_peer_model': None})
            self.assertEqual(responses[0]['sequence'], 0)
            self.assertGreater(responses[0]['sampled_monotonic'], 0)
        finally:
            release.set()
            for worker in workers:
                worker.join(2)
            for pipe in (*parents, *clients):
                pipe.close()
        self.assertFalse(errors)
        self.assertTrue(all(not worker.is_alive() for worker in workers))

    def test_metadata_requests_do_not_extend_the_final_response_deadline(self):
        parent, client = mp.Pipe()
        errors = []

        def flood():
            try:
                for sequence in range(100):
                    client.send(request(sequence))
                    client.recv()
            except (EOFError, BrokenPipeError, OSError):
                pass
            except BaseException as error:
                errors.append(error)

        worker = threading.Thread(target=flood)
        worker.start()

        def slow_metadata(*_):
            time.sleep(.02)
            return None

        began = time.monotonic()
        try:
            with self.assertRaisesRegex(RuntimeError, 'deadline exceeded'):
                receive_participant_values([parent], .15, slow_metadata)
            self.assertLess(time.monotonic() - began, .5)
        finally:
            parent.close()
            worker.join(2)
            client.close()
        self.assertFalse(worker.is_alive())
        self.assertFalse(errors)

    def test_unrequested_and_malformed_metadata_is_rejected_before_query(self):
        invalid = [request(), request()]
        invalid[0]['source_cost_request']['sequence'] = True
        invalid[1]['source_cost_request']['packet_bytes']['2'] = 1461
        invalid += [{'source_cost_request': {}}, {'source_cost_request': None}]
        for value in invalid:
            with self.subTest(value=value):
                parent, client = mp.Pipe()
                try:
                    client.send(value)
                    with self.assertRaisesRegex(RuntimeError, 'Invalid participant'):
                        receive_participant_values([parent], 1,
                                                   lambda *_: self.fail('invalid query reached SDK'))
                finally:
                    parent.close()
                    client.close()
        parent, client = mp.Pipe()
        try:
            client.send(request())
            with self.assertRaisesRegex(RuntimeError, 'Unexpected participant'):
                receive_participant_values([parent], 1)
        finally:
            parent.close()
            client.close()

    def test_sampled_packet_sizes_include_actual_headers_once_and_preserve_model_limits(self):
        sampler = SourcePacketSamples()

        def stats(packets, payload, headers, stalled=0):
            return {'worker_stalled': stalled, 'video_worker_stalled': stalled,
                    'video_tx_payload_rtp_bytes': payload + headers,
                    **{source + key: n for source in ['audio', 'video']
                       for key, n in [('_tx_payload_pkts', packets),
                                      ('_tx_payload_bytes', payload),
                                      ('_tx_header_padding_bytes', headers)]}}

        self.assertEqual(sampler.observe(stats(0, 0, 0)), {'0': 200, '2': 200, '3': 200})
        self.assertEqual(sampler.observe(stats(2, 320, 24)), {'0': 172, '2': 172, '3': 172})
        self.assertEqual(sampler.observe(stats(3, 2200, 44)), {'0': 1460, '2': 1460, '3': 1460})
        self.assertEqual(sampler.observed_packet_bytes, {'0': 1900, '2': 1900, '3': 1900})
        self.assertEqual(sampler.observe(stats(4, 2280, 56, 1))['0'], 1460)
        self.assertEqual(sampler.observe(stats(0, 0, 0))['0'], 1460)
        self.assertEqual(sampler.observe(stats(3, 360, 36)), {'0': 132, '2': 132, '3': 132})
        missing = stats(4, 500, 48)
        del missing['audio_tx_header_padding_bytes']
        self.assertEqual(sampler.observe(missing)['0'], 132)
        self.assertEqual(sampler.basis['2'], 'native_fanout_payload_rtp')

    def test_old_video_attempts_and_logical_frames_cannot_invent_packet_size(self):
        sampler = SourcePacketSamples()
        for frames, attempts in [(1, 4), (2, 8)]:
            sample = {'video_worker_stalled': 0, 'video_tx_frames': frames,
                      'video_tx_rtp_attempts': attempts, 'video_tx_payload_bytes': attempts * 600}
            self.assertEqual(sampler.observe(sample)['2'], 200)
        self.assertEqual(sampler.basis['2'], 'startup_default')

    def test_video_uses_full_fanout_rtp_bytes_without_adding_headers_again(self):
        sampler = SourcePacketSamples()
        def sample(packets, rtp_bytes):
            return {'video_worker_stalled': 0, 'video_tx_payload_pkts': packets,
                    'video_tx_payload_rtp_bytes': rtp_bytes,
                    'video_tx_payload_bytes': rtp_bytes - 20 * packets,
                    'video_tx_header_padding_bytes': 999999,
                    'video_tx_frames': packets // 2}
        sampler.observe(sample(2, 1040))
        result = sampler.observe(sample(6, 3120))
        self.assertEqual(result['2'], 520)
        self.assertEqual(result['3'], 520)

    def test_node_snapshot_rejects_unowned_or_unbounded_selection_before_ffi(self):
        fixture = GroupSdk.__new__(GroupSdk)
        fixture.fn = lambda *_: self.fail('invalid source selection reached FFI')
        for args in [(0, 0, 0, 200), (-1, 1, 0, 200), (0, 3, 0, 200),
                     (0, 1, 1, 200), (0, 1, 2, 1461), (True, 1, 0, 200)]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                fixture.source_packet_cost(*args)


if __name__ == '__main__':
    unittest.main()
