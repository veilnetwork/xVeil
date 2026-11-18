import json
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import unittest

from analyze_tcp_connect_candidates import EvidenceError, analyze
from normalize_tcp_connect_capture import normalize, parse_flows, parse_native


def native(context='Some(200)'):
    return [
        '[INFO transport.connect.context] context=200 peer_slot=0x00000009 '
        'scheme=obfs4-tcp monotonic_us=2000',
        'tcp_handshake connection=300 monotonic_us=3000 side=Client outcome=start '
        f'connect_context={context} socket=private-metadata',
        'tcp_handshake connection=300 monotonic_us=3001 side=Client outcome=linked '
        f'connect_context={context} attempt=Some(8) candidate=Some("primary")',
    ]


def packet(client=True, seq=100, ack=0, flags=2, size=0, client_port=45000):
    return dict(client=client, seq=seq, ack=ack, flags=flags, size=size, client_port=client_port)


def frame(row, link=276):
    source = bytes((198, 51, 100, 2)) if row['client'] else bytes((192, 0, 2, 1))
    dest = bytes((192, 0, 2, 1)) if row['client'] else bytes((198, 51, 100, 2))
    ihl, thl = row.get('ihl', 20), row.get('thl', 20)
    total = ihl + thl + row['size']
    ip = bytearray(ihl)
    ip[0] = 0x40 | (ihl // 4)
    ip[2:4] = struct.pack('!H', total)
    ip[6:8] = struct.pack('!H', row.get('fragment', 0))
    ip[9] = 6
    ip[12:16], ip[16:20] = source, dest
    tcp = bytearray(thl)
    ports = (row['client_port'], 5557) if row['client'] else (5557, row['client_port'])
    tcp[:12] = struct.pack('!HHII', *ports, row['seq'], row['ack'])
    tcp[12], tcp[13] = (thl // 4) << 4, row['flags']
    if link == 276: l2 = struct.pack('!H', 0x0800) + bytes(18)
    elif link == 113: l2 = bytes(14) + struct.pack('!H', 0x0800)
    else: l2 = bytes(12) + struct.pack('!H', 0x0800)
    return l2 + ip + tcp + bytes(row['size'])


def write_pcap(path, rows=None, endian='<', nano=False, link=276):
    rows = rows if rows is not None else [
        (1_100_000, packet()),
        (1_200_000, packet(False, seq=500, ack=101, flags=18)),
        (1_300_000, packet(seq=101, ack=501, flags=16, size=7)),
    ]
    factor = 1 if nano else 1000
    magic = {('<', False): b'\xd4\xc3\xb2\xa1', ('>', False): b'\xa1\xb2\xc3\xd4',
             ('<', True): b'\x4d\x3c\xb2\xa1', ('>', True): b'\xa1\xb2\x3c\x4d'}[endian, nano]
    data = magic + struct.pack(endian + 'HHIIII', 2, 4, 0, 0, 96, link)
    for ns, row in rows:
        raw = frame(row, link)
        snap = raw[:96]
        data += struct.pack(endian + 'IIII', ns // 1_000_000_000,
                            (ns % 1_000_000_000) // factor, len(snap), len(raw)) + snap
    path.write_bytes(data)


def clock(offset=0, resolution=1000, kind='monotonic'):
    return dict(kind=kind, resolution_ns=resolution, drift_ppb=0, samples=[
        dict(local_before_ns=t, local_after_ns=t,
             reference_before_ns=t+offset-2, reference_after_ns=t+offset+2)
        for t in (100_000, 10_000_000)])


def manifest(root):
    (root/'native.log').write_text('\n'.join(native()))
    write_pcap(root/'core.pcap')
    return {'schema': 'xveil-tcp-connect-capture/1', 'single_process_capture': True,
            'capture_started_before_trace': True, 'native_trace_complete': True,
            'native_log': 'native.log', 'verified_fixed_target_slots': [9],
            'slot_targets': [{'slot': 9, 'target': 1}],
            'clocks': {'phone': clock(), 'cores': [dict(clock(1_000_000, kind='realtime'), target=1)]},
            'cores': [dict(target=1, pcap='core.pcap', port=5557,
                           kernel_dropped_packets=0, capture_complete=True)]}


class NativeParseTests(unittest.TestCase):
    def test_real_hex_peer_slot_and_client_start_are_parsed_not_later_link_rows(self):
        contexts, starts = parse_native(native())
        self.assertEqual(contexts[0]['slot'], 9)
        self.assertEqual(starts, [{'id': 300, 'context': 200, 'start_ns': 3_000_000}])

    def test_auxiliary_reuses_context_but_has_an_independent_connection(self):
        lines = native() + [native()[1].replace('connection=300', 'connection=301')]
        contexts, starts = parse_native(lines)
        self.assertEqual(len(contexts), 1)
        self.assertEqual([s['context'] for s in starts], [200, 200])
        self.assertNotEqual(starts[0]['id'], starts[1]['id'])
        lines[-1] = lines[-1].replace('outcome=start', 'outcome=selected').replace('Some(200)', 'Some(201)')
        lines.insert(-1, native()[1].replace('connection=300', 'connection=301'))
        with self.assertRaises(EvidenceError): parse_native(lines)

    def test_legacy_context_none_and_server_observation_are_not_invented(self):
        lines = native('None') + ['tcp_handshake connection=301 monotonic_us=3000 '
                                  'side=Server outcome=start connect_context=None']
        _, starts = parse_native(lines)
        self.assertEqual(len(starts), 1)
        self.assertIsNone(starts[0]['context'])

    def test_duplicate_unknown_clock_bad_id_and_missing_start_fail_closed(self):
        for scenario in ('duplicate_start', 'duplicate_context', 'clock', 'slot', 'context', 'side', 'start'):
            lines = native()
            if scenario == 'duplicate_start': lines.append(lines[1])
            elif scenario == 'duplicate_context': lines.append(lines[0])
            elif scenario == 'clock': lines[1] = lines[1].replace('3000', 'unknown')
            elif scenario == 'slot': lines[0] = lines[0].replace('0x00000009', '9')
            elif scenario == 'context': lines[1] = lines[1].replace('Some(200)', 'bad')
            elif scenario == 'side': lines[1] = lines[1].replace('side=Client', 'side=unknown')
            else: del lines[1]
            with self.subTest(scenario=scenario), self.assertRaises(EvidenceError): parse_native(lines)


class PcapTests(unittest.TestCase):
    def test_all_classic_formats_and_links_have_same_flow_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)/'capture'
            for endian in ('<', '>'):
                for nano in (True, False):
                    for link in (1, 113, 276):
                        write_pcap(p, endian=endian, nano=nano, link=link)
                        flows, stats = parse_flows(p, 5557, 1)
                        with self.subTest(endian=endian, nano=nano, link=link):
                            self.assertEqual(flows, [dict(id=0, target=1, syn_ns=1_100_000,
                                                          synack_ns=1_200_000, client_payload_bytes=7)])
                            self.assertEqual(stats['resolution_ns'], 1 if nano else 1000)

    def test_retransmitted_payload_is_counted_once_including_sequence_wrap(self):
        rows = [(1_100_000, packet(seq=0xffffffff)),
                (1_200_000, packet(False, seq=500, ack=0, flags=18)),
                (1_300_000, packet(seq=0, flags=16, size=2000)),
                (1_400_000, packet(seq=5, flags=16, size=1000))]
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)/'capture';write_pcap(p, rows)
            flows, _ = parse_flows(p, 5557, 1)
            self.assertEqual(flows[0]['client_payload_bytes'], 2000)

    def test_header_only_snap_with_ip_and_tcp_options_uses_full_ip_length(self):
        rows = [(1_100_000, packet()), (1_200_000, packet(False, seq=500, ack=101, flags=18)),
                (1_300_000, dict(packet(seq=101, flags=16, size=500), ihl=24, thl=32))]
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)/'capture';write_pcap(p, rows)
            self.assertEqual(parse_flows(p, 5557, 1)[0][0]['client_payload_bytes'], 500)

    def test_missing_syn_or_synack_stays_incomplete_and_is_not_a_payload_zero_match(self):
        rows = [(1_100_000, packet()),
                (1_200_000, packet(False, seq=500, ack=101, flags=18, client_port=45001))]
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)/'capture';write_pcap(p, rows)
            flows, stats = parse_flows(p, 5557, 1)
            self.assertEqual(flows, [])
            self.assertEqual(stats['incomplete_tuple_groups'], 2)

    def test_reused_tuple_wrong_synack_fragments_and_fast_open_are_rejected(self):
        for scenario in ('reuse', 'synack', 'fragment', 'fast_open'):
            rows = [(1_100_000, packet()), (1_200_000, packet(False, seq=500, ack=101, flags=18))]
            if scenario == 'reuse': rows.append((1_400_000, packet(seq=300)))
            elif scenario == 'synack': rows[1][1]['ack'] = 200
            elif scenario == 'fragment': rows[0][1]['fragment'] = 0x2000
            else: rows[0][1]['size'] = 20
            with tempfile.TemporaryDirectory() as folder:
                p = Path(folder)/'capture';write_pcap(p, rows)
                with self.subTest(scenario=scenario), self.assertRaises(EvidenceError): parse_flows(p, 5557, 1)

    def test_tuple_history_before_its_syn_is_not_counted_as_new_payload(self):
        rows = [(1_000_000, packet(seq=101, flags=16, size=7)),
                (1_100_000, packet()), (1_200_000, packet(False, seq=500, ack=101, flags=18))]
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)/'capture';write_pcap(p, rows)
            with self.assertRaises(EvidenceError): parse_flows(p, 5557, 1)

    def test_truncated_bad_fraction_unsupported_protocol_and_pcapng_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)/'capture';write_pcap(p)
            original = p.read_bytes()
            for scenario in ('header', 'record', 'packet', 'fraction', 'ipv6', 'vlan', 'pcapng'):
                data = bytearray(original)
                if scenario == 'header': data = data[:20]
                elif scenario == 'record': data = data[:26]
                elif scenario == 'packet': data = data[:-1]
                elif scenario == 'fraction': data[28:32] = struct.pack('<I', 1_000_000)
                elif scenario == 'ipv6': data[40:42] = struct.pack('!H', 0x86dd)
                elif scenario == 'vlan': data[40:42] = struct.pack('!H', 0x8100)
                else: data[:4] = b'\x0a\x0d\x0d\x0a'
                p.write_bytes(data)
                with self.subTest(scenario=scenario), self.assertRaises(EvidenceError): parse_flows(p, 5557, 1)


class NormalizeTests(unittest.TestCase):
    def test_actual_log_and_pcap_formats_feed_candidate_analysis(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder);m = manifest(root)
            result, summary = normalize(m, root)
            self.assertEqual(summary['mutually_unique_temporal_candidates'], 1)
            self.assertEqual(summary['unique_candidates_without_server_payload'], 0)
            self.assertEqual(analyze(result)['eligible_connections'], 1)
            self.assertEqual(result['contexts'][0]['slot'], 9)
            self.assertEqual(result['normalization']['incomplete_server_tuple_groups'], 0)

    def test_scope_capture_drops_and_precision_are_required(self):
        for scenario in ('process', 'native', 'coverage', 'drops', 'incomplete', 'precision', 'native_precision', 'target_coverage'):
            with tempfile.TemporaryDirectory() as folder:
                root = Path(folder);m = manifest(root)
                if scenario == 'process': m['single_process_capture'] = False
                elif scenario == 'native': m['native_trace_complete'] = False
                elif scenario == 'coverage': m['capture_started_before_trace'] = False
                elif scenario == 'drops': m['cores'][0]['kernel_dropped_packets'] = 1
                elif scenario == 'incomplete': m['cores'][0]['capture_complete'] = False
                elif scenario == 'precision': m['clocks']['cores'][0]['resolution_ns'] = 1
                elif scenario == 'native_precision': m['clocks']['phone']['resolution_ns'] = 1
                else: m['cores'] = []
                with self.subTest(scenario=scenario), self.assertRaises(EvidenceError): normalize(m, root)

    def test_unverified_slot_never_becomes_eligible(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder);m = manifest(root);m['verified_fixed_target_slots'] = []
            _, summary = normalize(m, root)
            self.assertEqual(summary['eligible_connections'], 0)
            self.assertEqual(summary['mutually_unique_temporal_candidates'], 0)

    def test_cli_writes_private_file_once_and_only_aggregate_stdout(self):
        script = Path(__file__).with_name('normalize_tcp_connect_capture.py')
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder);m = manifest(root);mp = root/'manifest.json';mp.write_text(json.dumps(m))
            output = root/'PRIVATE_OUTPUT_CANARY.json'
            p = subprocess.run([sys.executable, str(script), str(mp), '--output', str(output)], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertNotIn('PRIVATE_OUTPUT_CANARY', p.stdout+p.stderr)
            self.assertNotIn('"contexts"', p.stdout)
            self.assertEqual(json.loads(p.stdout)['mutually_unique_temporal_candidates'], 1)
            previous = output.read_bytes()
            p = subprocess.run([sys.executable, str(script), str(mp), '--output', str(output)], capture_output=True, text=True)
            self.assertEqual(p.returncode, 2)
            self.assertEqual(output.read_bytes(), previous)
            self.assertNotIn('PRIVATE_OUTPUT_CANARY', p.stdout+p.stderr)

    def test_cli_never_follows_existing_output_symlink(self):
        script = Path(__file__).with_name('normalize_tcp_connect_capture.py')
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder);mp = root/'manifest.json'
            mp.write_text(json.dumps(manifest(root)))
            original = root/'existing.json';original.write_text('KEEP_PRIVATE_FILE')
            output = root/'output.json';output.symlink_to(original)
            p = subprocess.run([sys.executable, str(script), str(mp), '--output', str(output)], capture_output=True, text=True)
            self.assertEqual(p.returncode, 2)
            self.assertEqual(original.read_text(), 'KEEP_PRIVATE_FILE')
            self.assertEqual(p.stdout, '')

    def test_cli_errors_never_echo_raw_input_or_create_evidence(self):
        script = Path(__file__).with_name('normalize_tcp_connect_capture.py')
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder);mp = root/'PRIVATE_MANIFEST_CANARY.json';output = root/'out.json'
            mp.write_text('{"RAW_PRIVATE_JSON_CANARY": bad}')
            p = subprocess.run([sys.executable, str(script), str(mp), '--output', str(output)], capture_output=True, text=True)
            self.assertEqual(p.returncode, 2)
            self.assertFalse(output.exists())
            self.assertEqual(p.stdout, '')
            self.assertEqual(p.stderr.strip(), 'Invalid or incomplete private TCP capture; no evidence accepted')


if __name__ == '__main__': unittest.main()
