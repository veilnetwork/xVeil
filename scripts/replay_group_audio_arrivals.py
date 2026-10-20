#!/usr/bin/env python3
"""Replay owned group arrival metadata through real Opus/NetEq on a virtual clock.

Regenerates tones; never reads/stores encoded audio. This isolates receiver
policy from changes to the network workload. It does not reproduce the exact
original PCM or establish a physical/acoustic latency result.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

from analyze_group_audio_peak import trace_sections


def schedule(directory, source, receiver):
    summary = json.loads((directory / 'summary.json').read_text())
    if summary.get('separate_sdk_processes') is not True:
        raise ValueError('Requires an owned same-host group capture')
    origin = summary['origin_monotonic']
    codec = json.loads((directory / f'worker-{source}/codec-samples.json').read_text())
    offsets = {r['sender']['rtp_origin'] for r in codec}
    if len(offsets) != 1:
        raise ValueError('Missing or changing sender RTP origin')
    offset = offsets.pop()
    encoded = trace_sections(
        (directory / f'worker-{source}/playout-trace.log').read_text().splitlines(),
        'audio.encode.begin', 'audio.encode')
    ssrcs = {meta['ssrc'] for meta, _ in encoded}
    if len(ssrcs) != 1:
        raise ValueError('Ambiguous sender SSRC')
    arrivals = trace_sections(
        (directory / f'worker-{receiver}/playout-trace.log').read_text().splitlines(),
        'audio.rtp.ingress.begin', 'audio.rtp.ingress', ssrcs.pop())
    by_stamp = {}
    for _, row in arrivals:
        # Padding may reuse the preceding audio timestamp with another RTP
        # sequence. It is not a second arrival of that encoded speech packet.
        if row['payload_bytes'] == 0:
            continue
        if row['timestamp'] in by_stamp:
            raise ValueError('Ambiguous arrival timestamp')
        by_stamp[row['timestamp']] = row
    rows = []
    for _, row in encoded:
        stamp = (row['timestamp'] + offset) % 2**32
        first = row['first_us'] - origin * 1e6
        if not 0 <= first < summary['duration_seconds'] * 1e6:
            continue
        if row['blocks'] != 4:
            raise ValueError('This diagnostic currently requires 40-ms packets')
        arrival = by_stamp.get(stamp)
        if arrival is None or arrival['payload_bytes'] != row['bytes']:
            raise ValueError('Missing or contradictory packet arrival witness')
        rows.append((round(first), round(arrival['arrived_us'] - origin * 1e6),
                     row['blocks'], stamp, arrival['seq']))
    if not rows:
        raise ValueError('Missing packet schedule')
    return rows, summary['duration_seconds']


def build(output, media_source, webrtc_source, webrtc_out, log):
    out = webrtc_source / webrtc_out
    entries = json.loads((out / 'compile_commands.json').read_text())
    entry = next(r for r in entries if r['file'].endswith('call/call.cc'))
    command = shlex.split(entry['command']) if 'command' in entry else entry['arguments'][:]
    native = Path(__file__).with_name('audio_arrival_replay.cc')
    with tempfile.TemporaryDirectory(prefix='xveil-arrival-replay-',
                                     dir=os.environ.get('TMPDIR', '/private/tmp/')) as tmp:
        obj = Path(tmp) / 'replay.o'
        command[command.index('-o') + 1] = str(obj)
        if '-MF' in command:
            command[command.index('-MF') + 1] = str(obj.with_suffix('.d'))
        command = [str(native) if token.endswith('call/call.cc') else token
                   for token in command]
        command += ['-I' + str(media_source),
                    '-I' + str(webrtc_source / 'third_party/protobuf/src')]
        subprocess.run(command, cwd=entry['directory'], stdout=log, stderr=log, check=True)
        objects = [str(q) for name in ('libc++', 'libc++abi')
                   for q in (out / 'obj/buildtools/third_party' / name).rglob('*.o')]
        link = [command[0], str(obj), str(out / 'obj/libwebrtc.a'), *objects,
                '-Wl,-dead_strip', next(t for t in command if t.startswith('--target=')),
                '-isysroot', str(next((out / 'sdk/xcode_links').glob('MacOSX*.sdk'))),
                '-o', str(output)]
        for name in ('Foundation', 'CoreFoundation', 'CoreAudio', 'AudioToolbox',
                     'AudioUnit', 'CoreServices', 'IOKit', 'SystemConfiguration',
                     'Security', 'CoreMedia', 'CoreVideo', 'AVFoundation'):
            link += ['-framework', name]
        subprocess.run(link, cwd=entry['directory'], stdout=log, stderr=log, check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--source', type=int, choices=range(3), required=True)
    parser.add_argument('--receiver', type=int, choices=range(3), required=True)
    parser.add_argument('--output', type=Path, required=True)
    repo = Path(__file__).resolve().parent.parent
    parser.add_argument('--media-source', type=Path,
                        default=repo / 'third_party/veil/flutter/veil_media/src')
    parser.add_argument('--webrtc-source', type=Path,
                        default=Path.home() / 'Projects/veilnetwork/webrtc-checkout/src')
    parser.add_argument('--webrtc-out', default='out/mac-arm64')
    args = parser.parse_args()
    if args.source == args.receiver:
        parser.error('Source and receiver must differ')
    rows, duration = schedule(args.directory, args.source, args.receiver)
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    data = ''.join(','.join(map(str, row)) + '\n' for row in rows).encode()
    csv = args.output / 'arrivals.csv'
    csv.write_bytes(data)
    binary = args.output / 'replay'
    with (args.output / 'build.log').open('w') as log:
        # The parent capture is already complete; never build during a timed run.
        build(binary, args.media_source.resolve(), args.webrtc_source.resolve(),
              args.webrtc_out, log)
    result = json.loads(subprocess.check_output(
        [str(binary), str(csv), str(duration), str(args.source)], text=True))
    result.update(source=args.source, receiver=args.receiver,
                  generator_version=2,
                  tone_hz=([600, 900], [1300, 1700], [2100, 2500])[args.source],
                  replay_source_sha256=hashlib.sha256(
                      Path(__file__).with_name('audio_arrival_replay.cc').read_bytes()
                  ).hexdigest(),
                  sequence_complete=(result['edges'] == result['expected_edges'] and
                                     result['ordinal_mismatches'] == 0 and
                                     result['packets'] == len(rows)),
                  arrivals_sha256=hashlib.sha256(data).hexdigest(),
                  header_sha256={q.name: hashlib.sha256(q.read_bytes()).hexdigest()
                                 for q in args.media_source.glob('*.h')},
                  limits=['Regenerated mono 24-kbit Opus tones, not original encoded audio',
                          'Recorded ingress schedule quantized to 10-ms virtual render ticks',
                          'Standalone receiver; no new network, camera, speaker or microphone test',
                          'Preserves marker ordinals from capture start; does not alter raw gates'])
    (args.output / 'summary.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
