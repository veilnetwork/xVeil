#!/usr/bin/env python3
"""Check immutable action refs and cargo install commands; no YAML dependency.

Join shell continuations before tokenizing, so flags on a following line count
for the same command, but flags on a later command do not. This is a source
policy gate, not a shell interpreter; computed install commands need review.
"""
import argparse
from pathlib import Path
import re
import shlex
import sys


def check(text):
    errors = []
    for number, line in enumerate(text.splitlines(), 1):
        action = re.match(r'''\s*(?:-\s*)?uses:\s*['"]?([^\s'"#]+)''', line)
        if action:
            ref = action[1]
            if not ref.startswith('./') and not re.fullmatch(r'[^@]+@[0-9a-fA-F]{40}', ref):
                if not re.fullmatch(r'docker://[^@]+@sha256:[0-9a-fA-F]{64}', ref):
                    errors.append((number, 'action must use a full commit SHA (or image digest)'))
    logical = re.sub(r'(?:\\|`)\r?\n\s*', ' ', text)
    for number, line in enumerate(logical.splitlines(), 1):
        if 'cargo' not in line or line.lstrip().startswith('#'):
            continue
        try:
            lexer = shlex.shlex(line, posix=True, punctuation_chars=';&|')
            lexer.whitespace_split = True
            tokens = list(lexer)
        except ValueError:
            # YAML/PowerShell quoting outside run blocks is not shell syntax.
            if re.search(r'\bcargo\s+install\b', line):
                errors.append((number, 'cannot parse cargo install; keep the command explicit'))
            continue
        for i in range(len(tokens)-1):
            if tokens[i:i+2] != ['cargo', 'install']:
                continue
            command = []
            for token in tokens[i+2:]:
                if token in (';', '&&', '||', '|', '&'):
                    break
                command.append(token)
            version = any((t.startswith('--version=') and len(t) > 10) or
                          (t == '--version' and j+1 < len(command) and not command[j+1].startswith('-'))
                          for j, t in enumerate(command))
            if not version or '--locked' not in command:
                errors.append((number, 'cargo install requires --version VALUE and --locked in the same command'))
    return errors


def self_test():
    assert not check('run: cargo install thing \\\n  --version ^1.2 --locked')
    assert not check('run: cargo install thing `\n  --version=1.2 --locked')
    assert check('run: cargo install thing; echo --version 1 --locked')
    assert check('run: cargo install thing --version --locked')
    assert not check('# cargo install ignored\nrun: echo "cargo install ignored"')
    assert check('- uses: actions/checkout@v4')
    assert not check('- uses: actions/checkout@' + 'a'*40)
    assert not check('- uses: ./local')
    print('workflow pin self-tests passed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    directory = args.root / '.github/workflows'
    files = sorted([*directory.glob('*.yml'), *directory.glob('*.yaml')])
    if not directory.is_dir() or not files:
        print(f'error: no workflows found at {directory}', file=sys.stderr)
        return 1
    failed = False
    for path in files:
        for number, error in check(path.read_text()):
            print(f'::error file={path},line={number}::{error}')
            failed = True
    if not failed:
        print('workflow actions and cargo installs are pinned')
    return int(failed)

if __name__ == '__main__':
    sys.exit(main())
