#!/usr/bin/env python3
"""Join one owned group PCM peak to authenticated SDK/IPC cell witnesses."""
import argparse
import hashlib
import json
from itertools import chain
from pathlib import Path
import re

from analyze_group_audio_peak import analyze as analyze_native
from opaque_packet_route import attribute_route


def records(path, marker):
    with path.open() as stream:
        for line in stream:
            if marker not in line:
                continue
            yield dict(re.findall(r'(\w+)=([^\s]+)', line.split(marker, 1)[1]))


def unique(rows, label):
    rows = list(rows)
    if len(rows) != 1:
        raise ValueError('Missing or ambiguous ' + label)
    return rows[0]


def cell(row):
    epoch, sequence = row['epoch'], int(row['seq'])
    if not re.fullmatch('[0-9a-f]{16}', epoch) or sequence <= 0:
        raise ValueError('Invalid sealed-cell identity')
    return epoch, sequence


def clock(row):
    value = int(row['monotonic_us'])
    if value < 0:
        raise ValueError('Unknown local clock')
    return value


def attribute(packet, source_rows, receiver_rows, ipc_rows, opaque_rows=None):
    """Logs must be complete and share the fixture's local monotonic clock."""
    key = (packet['ssrc'], packet['rtp_sequence'], packet['rtp_timestamp'],
           packet['ingress']['payload_bytes'])

    def rtp_key(row):
        return tuple(int(row[name]) for name in
                     ('ssrc', 'rtp_seq', 'timestamp', 'payload_bytes'))

    receiver_rows = list(receiver_rows)
    received = unique((row for row in receiver_rows
                       if row.get('kind') == 'rtp' and
                       row['stage'] == 'received' and rtp_key(row) == key),
                      'authenticated RTP witness')
    identity = cell(received)
    source_rows = list(source_rows)
    sealed = unique((row for row in source_rows
                     if row.get('kind') == 'rtp' and row['stage'] == 'sealed' and
                     cell(row) == identity and rtp_key(row) == key and
                     row['index'] == received['index']), 'source RTP seal')
    sent = unique((row for row in source_rows
                   if row.get('kind') == 'cell' and row['stage'] == 'relay_send' and
                   cell(row) == identity), 'source SDK pump')
    receipt = unique((row for row in receiver_rows
                      if row.get('kind') == 'cell' and row['stage'] == 'received' and
                      cell(row) == identity), 'authenticated SDK receipt')
    if int(sent['bytes']) != int(receipt['bytes']):
        raise ValueError('Different sealed-cell lengths')
    ipc_rows = [row for row in ipc_rows if cell(row) == identity]
    stages = {}
    for name in ('socket_written', 'daemon_read', 'handler_enter', 'relay_queued'):
        stages[name] = unique((row for row in ipc_rows if row['stage'] == name),
                              'IPC ' + name)
        if stages[name]['dst'] != sent['peer'] or int(stages[name]['bytes']) != int(sent['bytes']):
            raise ValueError('Different IPC destination or sealed-cell length')
    if len({row['local_slot'] for row in stages.values()}) != 1:
        raise ValueError('Different local IPC sources')
    # Socket-written is observed after write completion. A daemon may already
    # have read/handled the frame then; do not manufacture a causal ordering.
    if clock(stages['socket_written']) < clock(sent):
        raise ValueError('Socket completion precedes send pump')
    names = ('native_attempt', 'sdk_seal', 'sdk_send_pump', 'daemon_read',
             'handler_enter', 'relay_queued', 'sdk_authenticated', 'native_ingress')
    times = (packet['native_send']['attempted_us'], clock(sealed), clock(sent),
             clock(stages['daemon_read']), clock(stages['handler_enter']),
             clock(stages['relay_queued']), clock(receipt),
             packet['ingress']['arrived_us'])
    if list(times) != sorted(times) or not clock(receipt) <= clock(received) <= times[-1]:
        raise ValueError('Invalid SDK pipeline clock order')
    result = {
        'epoch': identity[0], 'cell_sequence': identity[1],
        'rtp_index_in_cell': int(received['index']),
        'source_sdk_peer': sent['peer'], 'receiver_sdk_peer': receipt['peer'],
        'sealed_bytes': int(sent['bytes']),
        'observations_us': dict(zip(names, times)),
        'socket_written_us': clock(stages['socket_written']),
        'rtp_authenticated_metadata_us': clock(received),
        'native_enqueue_return_us': packet['native_send']['admitted_us'],
        'spans_ms': {a + '_to_' + b: (end-start)/1000
                     for a, b, start, end in zip(names, names[1:], times, times[1:])},
    }
    if opaque_rows is not None:
        digest = received.get('sealed_sha256', '')
        if sealed.get('sealed_sha256') != digest:
            raise ValueError('Different endpoint ciphertext digest')
        result['opaque_route'] = attribute_route(
            digest, opaque_rows, source=receipt['peer'], receiver=sent['peer'],
            sealed_us=clock(sealed), received_us=clock(received),
            sealed_bytes=int(sent['bytes']))
    return result


def analyze(directory):
    native = analyze_native(directory)
    summary = json.loads((directory/'summary.json').read_text())
    consoles = [summary['console_log_before_read'], summary['console_log_after_stop']]
    for worker in range(3):
        state = json.loads((directory/f'worker-{worker}/summary.json').read_text())
        consoles += [value for key, value in state.items()
                     if key.startswith('console_log')]
    if not consoles or any(not value.get('ok') for value in consoles):
        raise ValueError('Incomplete console capture')
    paths = [directory/f'worker-{native[side]}/native.log' for side in ('source', 'receiver')]
    ipc_path = directory/'native.log'
    key = (native['packet']['ssrc'], native['packet']['rtp_sequence'],
           native['packet']['rtp_timestamp'], native['packet']['ingress']['payload_bytes'])

    def endpoints(path):
        # Keep only this RTP tuple first, then only its candidate cells. Large
        # opt-in traces are streamed; packet payloads are never loaded/stored.
        rtp = [dict(row, kind='rtp') for row in records(path, 'media.rtp.cell ')
               if tuple(int(row[n]) for n in ('ssrc', 'rtp_seq', 'timestamp', 'payload_bytes')) == key]
        identities = {cell(row) for row in rtp}
        return rtp + [dict(row, kind='cell') for row in records(path, 'media.cell.sample ')
                      if cell(row) in identities]

    source, receiver = map(endpoints, paths)
    identities = {cell(row) for row in receiver if row['kind'] == 'rtp'}
    ipc = [row for path in (paths[0], ipc_path)
           for row in records(path, 'ipc.rt_trace.sealed_sample ')
           if cell(row) in identities]
    # Older captures can lack the opt-in generic forwarding trace. If present,
    # require a complete join for this exact packet; do not silently fall back.
    opaque = records(ipc_path, 'delivery.opaque_trace ')
    first = next(opaque, None)
    if summary.get('opaque_forward_trace') is True and first is None:
        raise ValueError('Missing opted-in opaque forwarding trace')
    topology_paths = []
    if first is not None:
        opaque = chain((first,), opaque)
        topology_paths = [directory/f'sessions-{index}.json' for index in range(4)]
        identities = {row['node_id'].removeprefix('0x')
                      for path in topology_paths
                      for row in json.loads(path.read_text())['result']['sessions']}
        if (len(identities) != 4 or
                not all(re.fullmatch('[0-9a-f]{64}', node) for node in identities) or
                len({node[:8] for node in identities}) != 4):
            raise ValueError('Missing or ambiguous fixture node identities')
    else:
        opaque = None
    result = attribute(native['packet'], source, receiver, ipc, opaque)
    if first is not None:
        prefixes = {node[:8] for node in identities}
        if any(hop[side] not in prefixes for hop in result['opaque_route']['hops']
               for side in ('source', 'receiver')):
            raise ValueError('Opaque route leaves the owned fixture')
        result['opaque_route']['unique_fixture_node_prefixes_verified'] = True
    hashes = {}
    for path in [*paths, ipc_path, *topology_paths]:
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024*1024), b''):
                digest.update(chunk)
        hashes[str(path.relative_to(directory))] = digest.hexdigest()
    return {'native': native, 'sdk': result, 'sdk_log_sha256': hashes,
            'limits': ['Owned same-host clocks; no remote/acoustic latency inference',
                       'Relay-queued is source-node admission, not proof of wire send',
                       'Socket-written and native-enqueue-return are post-completion observations; concurrency can place them after downstream work',
                       'This join changes no original quality gate or capture verdict']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    print(json.dumps(analyze(parser.parse_args().directory), indent=2))
