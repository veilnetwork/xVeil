import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from analyze_group_sdk_packet import analyze, attribute


class GroupSdkPacketTest(unittest.TestCase):
    def fixture(self):
        packet = dict(ssrc=7, rtp_sequence=9, rtp_timestamp=10,
                      ingress=dict(payload_bytes=20, arrived_us=250),
                      native_send=dict(attempted_us=100, admitted_us=115))
        identity = dict(epoch='0011223344556677', seq='50')
        rtp = dict(identity, kind='rtp', ssrc='7', rtp_seq='9',
                   timestamp='10', payload_bytes='20', index='0')
        source = [dict(rtp, stage='sealed', monotonic_us='110'),
                  dict(identity, kind='cell', stage='relay_send',
                       monotonic_us='120', peer='aabbccdd', bytes='56')]
        receiver = [dict(rtp, stage='received', monotonic_us='235'),
                    dict(identity, kind='cell', stage='received',
                         monotonic_us='230', peer='10203040', bytes='56')]
        ipc = [dict(identity, stage=stage, monotonic_us=str(at),
                    dst='aabbccdd', local_slot='0', bytes='56')
               for stage, at in [('socket_written', 149), ('daemon_read', 140),
                                 ('handler_enter', 150), ('relay_queued', 160)]]
        return packet, source, receiver, ipc

    def test_exact_packet_cell_and_all_pipeline_stages_join(self):
        result = attribute(*self.fixture())
        self.assertEqual(result['cell_sequence'], 50)
        self.assertEqual(result['observations_us']['sdk_seal'], 110)
        self.assertEqual(result['native_enqueue_return_us'], 115)
        self.assertEqual(result['socket_written_us'], 149)
        self.assertAlmostEqual(sum(result['spans_ms'].values()), .15)

    def test_other_fanout_copy_is_not_the_receiving_peer_cell(self):
        args = self.fixture()
        args[1].append(dict(args[1][0], epoch='ffeeddccbbaa0099'))
        self.assertEqual(attribute(*args)['epoch'], '0011223344556677')

    def test_missing_or_duplicate_witnesses_are_rejected(self):
        for side in (1, 2, 3):
            for duplicate in (False, True):
                args = copy.deepcopy(self.fixture())
                if duplicate:
                    args[side].append(args[side][0])
                else:
                    args[side].pop(0)
                with self.assertRaisesRegex(ValueError, 'Missing or ambiguous'):
                    attribute(*args)

    def test_mismatched_lengths_destinations_and_ipc_sources_are_rejected(self):
        for key, value in [('bytes', '57'), ('dst', '01020304'), ('local_slot', '1')]:
            args = self.fixture()
            args[3][0][key] = value
            with self.assertRaisesRegex(ValueError, 'Different'):
                attribute(*args)
        args = self.fixture()
        args[2][1]['bytes'] = '57'
        with self.assertRaisesRegex(ValueError, 'Different sealed-cell lengths'):
            attribute(*args)

    def test_reversed_and_unknown_clocks_are_rejected(self):
        for side, row, at in [(1, 0, '130'), (2, 0, '220'),
                               (3, 0, '110'), (1, 0, '-1')]:
            args = self.fixture()
            args[side][row]['monotonic_us'] = at
            with self.assertRaises(ValueError):
                attribute(*args)

    def test_enqueue_and_socket_return_can_follow_downstream_work(self):
        args = self.fixture()
        args[0]['native_send']['admitted_us'] = 180
        args[3][0]['monotonic_us'] = '260'
        result = attribute(*args)
        self.assertEqual(result['native_enqueue_return_us'], 180)
        self.assertEqual(result['socket_written_us'], 260)

    def test_changed_rtp_or_sealed_identity_never_guesses_a_packet(self):
        for key, value in [('timestamp', '11'), ('payload_bytes', '21'),
                            ('epoch', '0011223344556678'), ('index', '1')]:
            args = self.fixture()
            args[2][0][key] = value
            with self.assertRaisesRegex(ValueError, 'Missing or ambiguous'):
                attribute(*args)

    def test_opted_in_route_requires_the_exact_authenticated_ciphertext(self):
        args = self.fixture()
        args[1][0]['sealed_sha256'] = args[2][0]['sealed_sha256'] = 'a'*64
        rows = [dict(stage=stage, node=node, peer=peer, monotonic_us=str(at),
                     opaque_bytes='56', opaque_sha256='a'*64)
                for stage, node, peer, at in [
                    ('transport_selected', '10203040', '55667788', 170),
                    ('dispatch_enter', '55667788', '10203040', 180),
                    ('dispatch_return', '55667788', '10203040', 181),
                    ('transport_selected', '55667788', 'aabbccdd', 190),
                    ('dispatch_enter', 'aabbccdd', '55667788', 220),
                    ('dispatch_return', 'aabbccdd', '55667788', 221),
                ]]
        self.assertEqual(len(attribute(*args, rows)['opaque_route']['hops']), 2)
        with self.assertRaisesRegex(ValueError, 'Missing'):
            attribute(*args, [])
        args[1][0]['sealed_sha256'] = 'b'*64
        with self.assertRaisesRegex(ValueError, 'Different endpoint ciphertext'):
            attribute(*args, rows)

    def test_sdk_writer_and_node_reader_are_joined_from_separate_process_logs(self):
        packet, source, receiver, ipc = self.fixture()
        def line(marker, row):
            return '[INFO fixture] ' + marker + ' ' + ' '.join(
                k+'='+v for k, v in row.items() if k != 'kind')+'\n'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for n in range(3):
                (root/f'worker-{n}').mkdir()
                (root/f'worker-{n}/summary.json').write_text(json.dumps({
                    'console_log_after_stop': {'ok': True}}))
            (root/'summary.json').write_text(json.dumps({
                'console_log_before_read': {'ok': True},
                'console_log_after_stop': {'ok': True}}))
            for n, rows in enumerate((source, receiver)):
                text = ''.join(line('media.rtp.cell' if row['kind'] == 'rtp'
                                    else 'media.cell.sample', row) for row in rows)
                if n == 0:
                    text += line('ipc.rt_trace.sealed_sample', ipc[0])
                (root/f'worker-{n}/native.log').write_text(text)
            (root/'native.log').write_text(''.join(
                line('ipc.rt_trace.sealed_sample', row) for row in ipc[1:]))
            with patch('analyze_group_sdk_packet.analyze_native', return_value={
                    'source': 0, 'receiver': 1, 'packet': packet}):
                result = analyze(root)
            self.assertEqual(result['sdk']['socket_written_us'], 149)
            self.assertEqual(len(result['sdk_log_sha256']), 3)
            state = json.loads((root/'summary.json').read_text())
            state['opaque_forward_trace'] = True
            (root/'summary.json').write_text(json.dumps(state))
            with patch('analyze_group_sdk_packet.analyze_native', return_value={
                    'source': 0, 'receiver': 1, 'packet': packet}):
                with self.assertRaisesRegex(ValueError, 'Missing opted-in'):
                    analyze(root)
            # An opted-in but unrelated trace must require full topology and
            # the selected packet's actual path, rather than silently skipping.
            with (root/'native.log').open('a') as stream:
                stream.write(line('delivery.opaque_trace', dict(
                    stage='transport_selected', node='10203040', peer='aabbccdd',
                    monotonic_us='170', opaque_bytes='56', opaque_sha256='b'*64)))
            ids = ['10203040'+'0'*56, 'aabbccdd'+'0'*56,
                   '55667788'+'0'*56, '77889900'+'0'*56]
            for n in range(4):
                (root/f'sessions-{n}.json').write_text(json.dumps({
                    'result': {'sessions': [{'node_id': node} for node in ids]}}))
            with patch('analyze_group_sdk_packet.analyze_native', return_value={
                    'source': 0, 'receiver': 1, 'packet': packet}):
                with self.assertRaisesRegex(ValueError, 'ciphertext digest'):
                    analyze(root)
                ids[-1] = ids[0][:8]+'1'*56
                (root/'sessions-0.json').write_text(json.dumps({
                    'result': {'sessions': [{'node_id': node} for node in ids]}}))
                with self.assertRaisesRegex(ValueError, 'fixture node identities'):
                    analyze(root)


if __name__ == '__main__':
    unittest.main()
