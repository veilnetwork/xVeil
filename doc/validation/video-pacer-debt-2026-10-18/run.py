#!/usr/bin/env python3
"""Reproduce rate-cut pacing debt against the pinned local WebRTC archive."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description="Pacing rate-cut regression; unpatched baseline is expected to fail.")
parser.add_argument("--pacing-source", type=Path)
args = parser.parse_args()
source = Path(os.environ.get('WEBRTC_SRC', Path.home() / 'Projects/veilnetwork/webrtc-checkout/src'))
out = source / os.environ.get('WEBRTC_OUT', 'out/mac-arm64')
commands = json.loads((out / 'compile_commands.json').read_text())
entry = next(row for row in commands if row['file'].endswith('call/call.cc'))
command = shlex.split(entry['command']) if 'command' in entry else entry['arguments'][:]
with tempfile.TemporaryDirectory(prefix='veil-video-cc-', dir=os.environ.get('TMPDIR', '/private/tmp/')) as tmp:
    temp = Path(tmp)
    command[command.index('-o') + 1] = str(temp / 'smoke.o')
    if '-MF' in command:
        command[command.index('-MF') + 1] = str(temp / 'smoke.d')
    command = [str(root / 'repro.cc')
               if token.endswith('call/call.cc') else token for token in command]
    command += ['-Werror', '-I' + str(root / 'src'), '-I' + str(source / 'third_party/protobuf/src')]
    subprocess.run(command, cwd=entry['directory'], check=True)
    extra_objects = []
    if args.pacing_source:
        pacing_entry = next(row for row in commands if row['file'].endswith('modules/pacing/pacing_controller.cc'))
        pacing_command = shlex.split(pacing_entry['command']) if 'command' in pacing_entry else pacing_entry['arguments'][:]
        pacing_command[pacing_command.index('-o') + 1] = str(temp / 'pacing.o')
        if '-MF' in pacing_command:
            pacing_command[pacing_command.index('-MF') + 1] = str(temp / 'pacing.d')
        pacing_command = [str(args.pacing_source.resolve()) if token.endswith('modules/pacing/pacing_controller.cc') else token for token in pacing_command]
        subprocess.run(pacing_command, cwd=pacing_entry['directory'], check=True)
        extra_objects.append(str(temp / 'pacing.o'))
    clang = command[0]
    target = next(token for token in command if token.startswith('--target='))
    sdk = next((out / 'sdk/xcode_links').glob('MacOSX*.sdk'))
    objects = [str(obj) for name in ['libc++', 'libc++abi']
               for obj in (out / 'obj/buildtools/third_party' / name).rglob('*.o')]
    link = [clang, str(temp / 'smoke.o'), *extra_objects, str(out / 'obj/libwebrtc.a'), *objects,
            '-Wl,-dead_strip', target, '-isysroot', str(sdk), '-o', str(temp / 'smoke')]
    for framework in ['Foundation', 'CoreFoundation', 'CoreAudio', 'AudioToolbox',
                      'AudioUnit', 'CoreServices', 'IOKit', 'SystemConfiguration',
                      'Security', 'CoreMedia', 'CoreVideo', 'AVFoundation']:
        link += ['-framework', framework]
    subprocess.run(link, cwd=entry['directory'], check=True)
    subprocess.run([str(temp / 'smoke')], check=True)
