#!/usr/bin/env python3
"""Normalize one private native TCP trace and IPv4 header capture for analysis.

No network, device, or application is accessed. The manifest's clock brackets,
peer target snapshots, trace coverage and fixed-target proofs are supplied by the
operator. Only --output receives normalized private evidence; stdout is counts.
"""
import argparse
from collections import defaultdict
import ipaddress
import json
import os
from pathlib import Path
import re
import struct
import sys

from analyze_tcp_connect_candidates import EvidenceError, analyze, integer


FIELDS = re.compile(r'\b(\w+)=([^\s]+)')


def decimal(value):
    if not isinstance(value, str) or not value.isdecimal() or not value.isascii():
        raise EvidenceError('Missing numeric trace field')
    return int(value)


def parse_native(lines):
    contexts, starts = {}, {}
    for line in lines:
        if 'transport.connect.context' in line:
            f = dict(FIELDS.findall(line))
            key = decimal(f.get('context'))
            slot = f.get('peer_slot', '')
            if not re.fullmatch(r'0x[0-9a-fA-F]{8}', slot):
                raise EvidenceError('Unsupported local peer slot format')
            if key in contexts:
                raise EvidenceError('Duplicate logical context in process scope')
            contexts[key] = {'id': key, 'slot': int(slot, 16),
                             'start_ns': decimal(f.get('monotonic_us')) * 1000,
                             'scheme': f.get('scheme')}
        elif 'tcp_handshake ' in line:
            f = dict(FIELDS.findall(line))
            if f.get('side') not in ('Client', 'Server') or f.get('outcome') not in (
                    'start', 'linked', 'selected', 'complete', 'incomplete'):
                raise EvidenceError('Malformed TCP observation')
            if f['side'] == 'Server':
                continue
            key = decimal(f.get('connection'))
            context = f.get('connect_context', 'None')
            if context == 'None':
                context_id = None
            else:
                match = re.fullmatch(r'Some\(([0-9]+)\)', context)
                if not match:
                    raise EvidenceError('Unsupported connect context field')
                context_id = int(match[1])
            if f['outcome'] != 'start':
                if key not in starts:
                    raise EvidenceError('TCP observation has no captured start')
                if starts[key]['context'] != context_id:
                    raise EvidenceError('TCP observation changed logical context')
                continue
            if key in starts:
                raise EvidenceError('Duplicate TCP start in process scope')
            starts[key] = {'id': key, 'context': context_id,
                           'start_ns': decimal(f.get('monotonic_us')) * 1000}
    return list(contexts.values()), list(starts.values())


def pcap_packets(path, port):
    """Classic PCAP only: Ethernet, Linux SLL/SLL2 and IPv4/TCP header snaps.

    Returned TCP data length is IP total length minus headers, including when
    payload was intentionally not captured. It is not a wire segment/MTU count.
    """
    port = integer(port)
    if not 1 <= port <= 65535:
        raise EvidenceError('Invalid capture port')
    magics = {b'\xd4\xc3\xb2\xa1': ('<', 1000), b'\xa1\xb2\xc3\xd4': ('>', 1000),
              b'\x4d\x3c\xb2\xa1': ('<', 1), b'\xa1\xb2\x3c\x4d': ('>', 1)}
    with Path(path).open('rb') as source:
        header = source.read(24)
        if len(header) != 24 or header[:4] not in magics:
            raise EvidenceError('Unsupported or truncated PCAP header')
        endian, factor = magics[header[:4]]
        major, minor = struct.unpack(endian + 'HH', header[4:8])
        snaplen, link = struct.unpack(endian + 'II', header[16:24])
        if (major, minor) != (2, 4) or link not in (1, 113, 276) or not 40 <= snaplen <= 1_048_576:
            raise EvidenceError('Unsupported PCAP format or snapshot size')
        while True:
            record = source.read(16)
            if not record:
                break
            if len(record) != 16:
                raise EvidenceError('Truncated PCAP record header')
            sec, fraction, size, wire = struct.unpack(endian + 'IIII', record)
            if size > snaplen or size > wire or fraction >= 1_000_000_000 // factor:
                raise EvidenceError('Invalid PCAP record length or timestamp')
            frame = source.read(size)
            if len(frame) != size:
                raise EvidenceError('Truncated PCAP record data')
            l2 = {1: 14, 113: 16, 276: 20}[link]
            if len(frame) < l2:
                raise EvidenceError('Truncated link header')
            proto = struct.unpack('!H', frame[:2] if link == 276 else frame[l2-2:l2])[0]
            # The present controlled targets use IPv4 literals. Reject IPv6,
            # rather than silently pretending those competing flows don't exist.
            if proto in (0x8100, 0x88a8):
                raise EvidenceError('VLAN capture needs a separate normalizer')
            if proto == 0x86dd:
                raise EvidenceError('IPv6 capture needs a separate normalizer')
            if proto != 0x0800:
                continue
            ip = frame[l2:]
            if len(ip) < 20 or ip[0] >> 4 != 4:
                raise EvidenceError('Truncated or invalid IPv4 header')
            ihl = (ip[0] & 15) * 4
            total = struct.unpack('!H', ip[2:4])[0]
            if ihl < 20 or total < ihl or l2 + total > wire:
                raise EvidenceError('Invalid IPv4 header length')
            if ip[9] != 6:
                continue
            if struct.unpack('!H', ip[6:8])[0] & 0x3fff:
                raise EvidenceError('Fragmented TCP capture cannot be normalized')
            tcp = ip[ihl:]
            if len(tcp) < 20:
                raise EvidenceError('TCP fixed header was not captured')
            sp, dp, seq, ack = struct.unpack('!HHII', tcp[:12])
            thl = (tcp[12] >> 4) * 4
            if not 20 <= thl <= 60 or total < ihl + thl:
                raise EvidenceError('Invalid TCP header length')
            if port not in (sp, dp):
                continue
            if sp == dp:
                raise EvidenceError('Ambiguous server-port direction')
            src, dst = str(ipaddress.ip_address(ip[12:16])), str(ipaddress.ip_address(ip[16:20]))
            client = dp == port
            key = (src, sp, dst, dp) if client else (dst, dp, src, sp)
            yield {'key': key, 'client': client, 'at_ns': sec * 1_000_000_000 + fraction * factor,
                   'seq': seq, 'ack': ack, 'flags': tcp[13], 'length': total - ihl - thl,
                   'resolution_ns': factor}


def union_size(ranges):
    size, end = 0, None
    for lo, hi in sorted(ranges):
        if end is None or lo > end:
            size += hi - lo
            end = hi
        elif hi > end:
            size += hi - end
            end = hi
    return size


def parse_flows(path, port, target, first_id=0):
    groups = defaultdict(list)
    resolution = None
    for packet in pcap_packets(path, port):
        groups[packet['key']].append(packet)
        resolution = packet['resolution_ns']
    flows = []
    incomplete = 0
    for rows in groups.values():
        syns = [r for r in rows if r['client'] and r['flags'] & 2 and not r['flags'] & 16]
        if not syns:
            incomplete += 1
            continue
        isns = {r['seq'] for r in syns}
        if len(isns) != 1:
            raise EvidenceError('Reused TCP tuple cannot be assigned one flow')
        isn = next(iter(isns))
        syn = min(r['at_ns'] for r in syns)
        if any(r['at_ns'] < syn for r in rows):
            raise EvidenceError('Tuple has history predating its captured SYN')
        replies = [r for r in rows if not r['client'] and r['flags'] & 2 and r['flags'] & 16]
        if not replies:
            incomplete += 1
            continue
        if any(r['ack'] != (isn + 1) & 0xffffffff for r in replies):
            raise EvidenceError('SYNACK refers to a different tuple generation')
        if len({r['seq'] for r in replies}) != 1:
            raise EvidenceError('Multiple server sequence origins for tuple')
        synack = min(r['at_ns'] for r in replies)
        if synack < syn:
            raise EvidenceError('PCAP clocks reverse handshake order')
        ranges = []
        for row in rows:
            if row['client'] and row['length']:
                if row['flags'] & 2:
                    raise EvidenceError('TCP Fast Open requires separate normalization')
                offset = (row['seq'] - ((isn + 1) & 0xffffffff)) & 0xffffffff
                if offset >= 2**31 or offset + row['length'] >= 2**31:
                    raise EvidenceError('TCP sequence is outside short-capture scope')
                ranges.append((offset, offset + row['length']))
        flows.append({'id': first_id + len(flows), 'target': integer(target),
                      'syn_ns': syn, 'synack_ns': synack,
                      'client_payload_bytes': union_size(ranges)})
    return flows, {'incomplete_tuple_groups': incomplete, 'resolution_ns': resolution}


def normalize(manifest, base):
    if manifest.get('schema') != 'xveil-tcp-connect-capture/1':
        raise EvidenceError('Unsupported capture manifest')
    if (manifest.get('single_process_capture') is not True or
            manifest.get('capture_started_before_trace') is not True or
            manifest.get('native_trace_complete') is not True):
        raise EvidenceError('Process and capture coverage not verified')
    contexts, connections = parse_native((base / manifest['native_log']).read_text().splitlines())
    verified = {integer(v) for v in manifest['verified_fixed_target_slots']}
    for row in contexts:
        row['fixed_target_direct_only'] = row['slot'] in verified and row['scheme'] == 'obfs4-tcp'
        del row['scheme']
    result = {'schema': 'xveil-tcp-connect-evidence/1', 'single_process_capture': True,
              'clocks': manifest['clocks'], 'slot_targets': manifest['slot_targets'],
              'contexts': contexts, 'connections': connections, 'flows': []}
    stats = []
    seen = set()
    for core in manifest['cores']:
        target = integer(core['target'])
        if target in seen:
            raise EvidenceError('Repeated Core capture target')
        seen.add(target)
        if integer(core['kernel_dropped_packets']) != 0 or core.get('capture_complete') is not True:
            raise EvidenceError('Incomplete or dropped PCAP capture')
        flows, info = parse_flows(base / core['pcap'], integer(core['port']), target,
                                 first_id=len(result['flows']))
        clock = [c for c in result['clocks']['cores'] if c['target'] == target]
        if len(clock) != 1:
            raise EvidenceError('Core capture has no unique clock calibration')
        if info['resolution_ns'] is not None and clock[0]['resolution_ns'] < info['resolution_ns']:
            raise EvidenceError('PCAP precision exceeds declared clock precision')
        result['flows'].extend(flows)
        stats.append(info['incomplete_tuple_groups'])
    if seen != {integer(c['target']) for c in result['clocks']['cores']}:
        raise EvidenceError('Clock and PCAP target coverage differ')
    if result['clocks']['phone']['resolution_ns'] < 1000:
        raise EvidenceError('Native trace timestamps have microsecond precision')
    result['normalization'] = {'incomplete_server_tuple_groups': sum(stats),
                               'pcap_target_count': len(seen),
                               'ipv4_header_capture_only': True}
    summary = analyze(result)
    summary['incomplete_server_tuple_groups'] = sum(stats)
    return result, summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--output', required=True, type=Path,
                        help='New private evidence file; existing files are never replaced')
    args = parser.parse_args()
    fd = None
    try:
        evidence, summary = normalize(json.loads(args.manifest.read_text()), args.manifest.parent)
        encoded = (json.dumps(evidence, indent=2) + '\n').encode()
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as target:
            fd = None
            target.write(encoded)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError, OverflowError):
        print('Invalid or incomplete private TCP capture; no evidence accepted', file=sys.stderr)
        return 2
    finally:
        if fd is not None:
            os.close(fd)
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
