import copy
import unittest

from analyze_group_delivery_tail import delivered_packets, partition


def witnesses():
    packet = dict(encoded_monotonic_us=1000,
                  native_send=dict(attempted_us=1100),
                  ingress=dict(arrived_us=90200))
    sdk = dict(epoch='0123456789abcdef', cell_sequence=7,
               receiver_sdk_peer='11111111', source_sdk_peer='33333333',
               observations_us=dict(sdk_seal=1200, sdk_send_pump=1250,
                                    daemon_read=1300, handler_enter=1350,
                                    sdk_authenticated=90100),
               opaque_route=dict(hops=[
                   dict(source='11111111', receiver='22222222',
                        selected_us=1450, dispatched_us=50000),
                   dict(source='22222222', receiver='33333333',
                        selected_us=51000, dispatched_us=90000)]))
    source = dict(epoch=sdk['epoch'], cell_sequence=7,
                  observations_us=dict(budget_admit=1400, datagram_accepted=1500))
    return packet, sdk, source


class DeliveryPartitionTest(unittest.TestCase):
    def test_each_microsecond_belongs_to_one_causal_stage(self):
        result = partition(*witnesses())
        self.assertEqual([r['duration_ms'] for r in result['stages']],
                         [0.1, 0.4, 48.5, 1, 39, 0.1, 0.1])
        self.assertEqual(result['encoded_to_ingress_ms'], 89.2)
        self.assertEqual(result['transport_and_link_ms'], 87.5)
        self.assertEqual(result['relay_dispatch_to_selection_ms'], 1)
        self.assertEqual(result['stages'][2]['start_observation'], 'datagram_accepted')
        self.assertEqual(result['stages'][4]['start_observation'], 'transport_selected')

    def test_missing_hop_observations_cannot_be_called_network_delay(self):
        packet, sdk, source = witnesses()
        del sdk['opaque_route']
        with self.assertRaisesRegex(ValueError, 'Missing authenticated opaque route'):
            partition(packet, sdk, source)

    def test_mixed_cell_or_destination_is_rejected(self):
        for side, name, value in [('source', 'cell_sequence', 8),
                                  ('sdk', 'source_sdk_peer', '44444444')]:
            packet, sdk, source = witnesses()
            (source if side == 'source' else sdk)[name] = value
            with self.assertRaises(ValueError):
                partition(packet, sdk, source)

    def test_post_completion_observation_after_arrival_is_not_a_causal_start(self):
        packet, sdk, source = witnesses()
        source['observations_us']['datagram_accepted'] = 50001
        with self.assertRaisesRegex(ValueError, 'causal source transport clocks'):
            partition(packet, sdk, source)

    def test_relay_queue_never_gets_a_negative_duration(self):
        packet, sdk, source = witnesses()
        sdk['opaque_route']['hops'][1]['selected_us'] = 49999
        with self.assertRaisesRegex(ValueError, 'Reversed stage clocks'):
            partition(packet, sdk, source)

    def test_disconnected_or_cyclic_hops_are_rejected(self):
        for changes in [dict(source='44444444'), dict(receiver='11111111')]:
            packet, sdk, source = witnesses()
            sdk = copy.deepcopy(sdk)
            sdk['opaque_route']['hops'][1].update(changes)
            # Keep the final endpoint witness consistent for the cycle case.
            sdk['source_sdk_peer'] = sdk['opaque_route']['hops'][-1]['receiver']
            with self.assertRaises(ValueError):
                partition(packet, sdk, source)


class DeliveredPacketSelectionTest(unittest.TestCase):
    def setUp(self):
        self.encoded = [(dict(ssrc=11), dict(ssrc=11, first_us=6000000,
            encoded_us=6040000, timestamp=300, blocks=4, bytes=119))]
        self.send = dict(channel=8, seq=7, timestamp=100, attempted_us=6040010,
                         admitted_us=6040020, accepted=1, packet_bytes=139)
        self.ingress = dict(timestamp=100, seq=7, payload_bytes=119,
                            arrived_us=6100000, drained_us=6100020)

    def select(self, *, sends=None, ingress=None, start_seconds=5):
        return delivered_packets(self.encoded,
            [(dict(ssrc=11), row) for row in (sends if sends is not None else [self.send])],
            [(dict(ssrc=11), row) for row in (ingress if ingress is not None else [self.ingress])],
            offset=2**32-200, channel=8, origin=0, duration=360,
            start_seconds=start_seconds)

    def test_exact_offset_wrap_and_actual_fanout_channel(self):
        wrong_channel = dict(self.send, channel=7, accepted=0)
        rows, missing = self.select(sends=[wrong_channel, self.send])
        self.assertEqual(missing, 0)
        self.assertEqual(rows[0]['rtp_timestamp'], 100)
        self.assertEqual(rows[0]['encoded_to_ingress_ms'], 60)
        self.assertEqual(rows[0]['native_send']['channel'], 8)

    def test_padding_is_not_another_speech_arrival(self):
        rows, missing = self.select(ingress=[self.ingress,
            dict(self.ingress, payload_bytes=0, seq=8)])
        self.assertEqual((len(rows), missing), (1, 0))

    def test_duplicate_or_mismatched_witnesses_are_rejected(self):
        for changes in [dict(payload_bytes=120), dict(arrived_us=6040001)]:
            with self.assertRaises(ValueError):
                self.select(ingress=[dict(self.ingress, **changes)])
        with self.assertRaisesRegex(ValueError, 'Ambiguous received RTP timestamp'):
            self.select(ingress=[self.ingress, self.ingress])
        with self.assertRaisesRegex(ValueError, 'contradictory native packet witness'):
            self.select(sends=[dict(self.send, accepted=0)])

    def test_missing_packets_remain_explicit(self):
        self.encoded.append((dict(ssrc=11), dict(self.encoded[0][1],
            timestamp=2220, first_us=6040000, encoded_us=6080000)))
        rows, missing = self.select()
        self.assertEqual((len(rows), missing), (1, 1))

    def test_phase_window_uses_original_encoder_input_clock(self):
        later = dict(self.encoded[0][1], timestamp=1260, first_us=8000000,
                     encoded_us=8040000)
        self.encoded.append((dict(ssrc=11), later))
        later_send = dict(self.send, seq=8, timestamp=1060,
                          attempted_us=8040010, admitted_us=8040020)
        later_ingress = dict(self.ingress, timestamp=1060, seq=8,
                             arrived_us=8100000, drained_us=8100020)
        rows, missing = self.select(sends=[self.send, later_send],
            ingress=[self.ingress, later_ingress], start_seconds=7)
        self.assertEqual((len(rows), missing), (1, 0))
        self.assertEqual(rows[0]['encoder_first_input_seconds'], 8)


if __name__ == '__main__':
    unittest.main()
