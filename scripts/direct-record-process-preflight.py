#!/usr/bin/env python3
"""Check direct reliable application delivery through the actual SDK API.

Uses a fresh, loopback-only four-node star and the direct root/leaf link.
This checks payloads, sender provenance and the actual child-admission trace;
it is separate from the three-process media contention qualification.
"""
import argparse
import collections
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import threading
import time
import traceback

from group_codec_sdk import GroupSdk, P, E


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    # Bounded metadata only. No payloads, keys or backtraces are logged.
    os.environ['VEIL_DIAG_FRAME_METADATA'] = '4/3,4/7,4/8,4/9,3/3'
    fixture = GroupSdk(args.sdk, args.directory)
    log = (fixture.root / 'native.log').open('w')
    os.dup2(log.fileno(), 2)
    result = {'ok': False, 'pid': os.getpid(), 'sdk_sha256':
              hashlib.sha256(args.sdk.read_bytes()).hexdigest(), 'errors': []}
    condition = threading.Condition()
    received = [collections.Counter(), collections.Counter()]
    provenance = [set(), set()]
    expected = []
    try:
        fixture.start(transport_only=True)
        result['link_node_prefixes'] = [node[:8] for node in fixture.node_ids[:2]]
        bindings = [fixture.bind_app(-1, 'direct-records', 3),
                    fixture.bind_app(0, 'direct-records', 3)]
        identities = [C.create_string_buffer(bytes.fromhex(fixture.node_ids[n]))
                      for n in [0, 1]]
        apps = [binding[1] for binding in bindings]
        app_ids = [binding[2] for binding in bindings]
        receive_type = C.CFUNCTYPE(None, P, P, P, C.c_uint8, C.c_uint64, P, C.c_size_t)
        receive_handler = fixture.fn('veil_app_set_recv_handler', [P, receive_type, P, E], C.c_int)
        free = fixture.fn('veil_free_buf', [P, C.c_size_t], None)
        send = fixture.fn('veil_send', [P, P, P, C.c_uint32, P, C.c_size_t, E], C.c_int)

        def receiver(index):
            @receive_type
            def callback(_, node, app, trust, reply, data, size):
                try:
                    sender = 1 - index
                    if (C.string_at(node, 32) != identities[sender].raw[:32] or
                            C.string_at(app, 32) != app_ids[sender].raw[:32] or trust < 2):
                        raise ValueError('Direct sender identity/application/provenance changed')
                    digest = hashlib.sha256(C.string_at(data, size)).hexdigest()
                    with condition:
                        received[index][digest] += 1
                        provenance[index].add(int(trust))
                        condition.notify_all()
                except Exception:
                    with condition:
                        result['errors'].append(traceback.format_exc())
                        condition.notify_all()
                finally:
                    free(node, 64 + size)
            return callback

        for index in range(2):
            callback = receiver(index)
            fixture.callbacks.append(callback)
            if fixture.checked(receive_handler, apps[index], callback, None):
                raise RuntimeError('Application receive callback refused')
        # Messages before and after the complete file catch both small-record
        # delivery and a file that would otherwise silently swallow a later send.
        for source in range(2):
            target = 1 - source
            payloads = [f'direct-before-{source}'.encode(),
                        bytes((n * 17 + source) % 256 for n in range(512 * 1024)),
                        f'direct-after-{source}'.encode()]
            for payload in payloads:
                digest = hashlib.sha256(payload).hexdigest()
                expected.append({'receiver': target, 'sha256': digest, 'bytes': len(payload)})
                buffer = C.create_string_buffer(payload)
                began = time.monotonic()
                if fixture.checked(send, apps[source], identities[target], app_ids[target],
                                   3, buffer, len(payload)):
                    raise RuntimeError('Direct send enqueue refused')
                with condition:
                    until = time.monotonic() + 30
                    while received[target][digest] == 0 and not result['errors']:
                        remaining = until - time.monotonic()
                        if remaining <= 0:
                            raise RuntimeError('Direct payload did not arrive in 30 seconds')
                        condition.wait(min(1, remaining))
                expected[-1]['delivery_seconds'] = time.monotonic() - began
                if result['errors']:
                    raise RuntimeError('Receive callback failed')
        # Observe an ordinary quiet tail for duplicate deliveries.
        with condition:
            condition.wait(1)
        for row in expected:
            if received[row['receiver']][row['sha256']] != 1:
                raise RuntimeError('Direct message missing or duplicated')
        if sum(map(lambda counts: sum(counts.values()), received)) != len(expected):
            raise RuntimeError('Unexpected extra application message')
        result['messages'] = expected
        result['sender_provenance'] = [sorted(v) for v in provenance]
        result['ok'] = True
    except Exception:
        result['errors'].append(traceback.format_exc())
    finally:
        fixture.close()
        result['node_stop_results'] = fixture.stop_results
        result['closed'] = fixture.closed and fixture.stop_results == [0, 0, 0, 0]
        result['remaining_sockets'] = len(list(fixture.root.glob('[0-3]/*.sock')))
        log.flush()
        rows = (fixture.root / 'native.log').read_text(errors='replace').splitlines()
        prefixes = result.get('link_node_prefixes', [])
        owned = [line for line in rows if len(prefixes) == 2 and
                 any(f' node={a} dst={b} ' in line
                     for a, b in [prefixes, prefixes[::-1]])]
        child = [line for line in owned if 'via=child_admitted' in line and 'family=4 ' in line]
        result['direct_child_records'] = len(child)
        result['direct_child_chunk_records'] = sum(' type=9 ' in line for line in child)
        # Large sealed sends retain their existing addressed Forward chunks.
        # AppSendChunk is the distinct format for arbitrary unsealed bytes;
        # these ordinary SDK sends negotiate encryption and do not select it.
        result['sealed_file_child_records'] = sum(
            'via=child_admitted' in line and 'family=3 type=3 ' in line for line in owned)
        result['ok'] &= (result['closed'] and result['remaining_sockets'] == 0 and
                         result['direct_child_records'] > 0 and
                         result['sealed_file_child_records'] > 0)
        (fixture.root / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
