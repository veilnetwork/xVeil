#!/usr/bin/env python3
"""Three isolated group participants: real Opus/VP8 and three encrypted files.

Compatibility entrypoint for the full contention fixture. Each participant
owns a process, preventing the SDK remote-peer callback registry from replacing
another local participant's receiver. No physical microphone/speaker is opened.
"""
import argparse
import os
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', required=True, type=Path)
    parser.add_argument('--media', required=True, type=Path)
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--duration', type=int, default=360)
    parser.add_argument('--rate-kbps', type=int, default=1024)
    args = parser.parse_args()
    command = [sys.executable, str(Path(__file__).with_name('group-process-preflight.py')),
               '--sdk', str(args.sdk), '--media', str(args.media),
               '--directory', str(args.directory), '--duration', str(args.duration),
               '--rate-kbps', str(args.rate_kbps), '--adaptive', '--full-load']
    os.execv(sys.executable, command)


if __name__ == '__main__':
    main()
