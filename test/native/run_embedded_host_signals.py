#!/usr/bin/env python3
"""POSIX SDK host-signal regression plus real CLI shutdown/reload controls.

Requires separately qualified SDK/CLI bytes and their expected SHA-256 values.
No application windows, real identities, shared seeds or deployment config.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import tomllib


PROJECT = Path(__file__).resolve().parents[2]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def wait_health(cli: Path, config: Path, child: subprocess.Popen, log: Path) -> None:
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline and child.poll() is None:
        result = subprocess.run(
            [str(cli), '--config', str(config), 'node', 'health'],
            capture_output=True, text=True, timeout=5,
        )
        log.write_text(result.stdout + result.stderr)
        if result.returncode == 0 and 'status: ok' in result.stdout:
            return
        time.sleep(0.05)
    raise RuntimeError('admin startup precondition failed')


def stop_owned(child: subprocess.Popen) -> None:
    if child.poll() is not None:
        return
    if child.stdin and not child.stdin.closed:
        child.stdin.close()
    elif child.stdin is None:
        child.terminate()
    try:
        child.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=5)


def sdk_case(args, binary: Path, mode: str, evidence: Path) -> tuple[dict, str, str]:
    with tempfile.TemporaryDirectory(prefix='xvhs-', dir=args.temp_base) as directory:
        root = Path(directory)
        with (evidence / f'{mode}-stderr.log').open('w') as errors:
            child = subprocess.Popen(
                [str(binary), str(args.library),
                 str(PROJECT / 'test/native/fixtures/public_discovery_identity_1.toml'),
                 directory, mode],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors,
                text=True, bufsize=1, start_new_session=True,
            )
            try:
                ready = False
                deadline = time.monotonic() + 30
                with selectors.DefaultSelector() as selector:
                    selector.register(child.stdout, selectors.EVENT_READ)
                    while time.monotonic() < deadline:
                        if not selector.select(0.1):
                            if child.poll() is not None:
                                break
                            continue
                        line = child.stdout.readline()
                        if not line:
                            break
                        if line.startswith('{') and json.loads(line).get('event') == 'ready':
                            ready = True
                            break
                if not ready:
                    raise RuntimeError('SDK startup precondition failed')
                config_file = root / 'node.toml'
                config = config_file.read_text()
                global_config = tomllib.loads(config)['global']
                if (global_config['builtin_seed_policy'] != 'never'
                        or global_config['meeting_points'] != 'off'
                        or global_config['bootstrap'] is not False):
                    raise RuntimeError('fixture isolation precondition failed')
                wait_health(args.cli, config_file, child, evidence / f'{mode}-health.log')
                child.stdin.write('sample\n')
                child.stdin.flush()
                output, _ = child.communicate(timeout=20)
                (evidence / f'{mode}-result.log').write_text(output)
                values = [json.loads(line) for line in output.splitlines()
                          if line.startswith('{')]
                result = next((row for row in values if row.get('event') == 'result'), None)
                if result is None or result['stopResult'] != 0:
                    raise RuntimeError('SDK stop precondition failed')
                passed = (child.returncode == 0
                          and all(result['runningPreserved'])
                          and all(result['stoppedPreserved'])
                          and result['hostReceivedAfterStop'])
                return {'mode': mode, 'passed': passed, **result}, config, directory
            finally:
                stop_owned(child)


def cli_case(args, template: str, old_root: str, end_signal: int,
             reload_first: bool, evidence: Path) -> dict:
    name = 'hup-term' if reload_first else signal.Signals(end_signal).name.lower()
    with tempfile.TemporaryDirectory(prefix='xvhc-', dir=args.temp_base) as directory:
        root = Path(directory)
        config = root / 'node.toml'
        config.write_text(template.replace(old_root, directory))
        output_file = evidence / f'cli-{name}.log'
        with output_file.open('w') as output:
            child = subprocess.Popen(
                [str(args.cli), '--config', str(config), 'node', 'run', '--foreground'],
                cwd=root, stdout=output, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            try:
                wait_health(args.cli, config, child, evidence / f'cli-{name}-health.log')
                reloaded = False
                if reload_first:
                    os.kill(child.pid, signal.SIGHUP)
                    deadline = time.monotonic() + 20
                    while time.monotonic() < deadline and child.poll() is None:
                        if 'config reloaded via SIGHUP' in output_file.read_text():
                            reloaded = True
                            break
                        time.sleep(0.05)
                    if reloaded:
                        wait_health(args.cli, config, child,
                                    evidence / f'cli-{name}-after-reload-health.log')
                if child.poll() is None:
                    os.kill(child.pid, end_signal)
                code = child.wait(timeout=20)
                return {'mode': f'cli-{name}', 'passed': code == 0 and
                        (not reload_first or reloaded), 'exit': code,
                        'reloadRequested': reload_first, 'reloadObserved': reloaded}
            finally:
                stop_owned(child)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['library', 'cli']:
        parser.add_argument('--' + name, type=Path, required=True)
        parser.add_argument('--' + name + '-sha256', required=True)
    parser.add_argument('--evidence-dir', type=Path)
    args = parser.parse_args()
    if os.name != 'posix':
        parser.error('this host-signal probe requires POSIX')
    os.umask(0o077)
    args.library = args.library.resolve(strict=True)
    args.cli = args.cli.resolve(strict=True)
    if digest(args.library) != args.library_sha256 or digest(args.cli) != args.cli_sha256:
        raise RuntimeError('qualified native bytes do not match')
    args.temp_base = '/private/tmp' if sys.platform == 'darwin' else '/tmp'
    with tempfile.TemporaryDirectory(prefix='xvhs-tools-', dir=args.temp_base) as tools:
        evidence = args.evidence_dir or Path(tools) / 'evidence'
        evidence.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = evidence.lstat()
        if evidence.is_symlink() or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise RuntimeError('evidence directory must be private and owned')
        binary = Path(tools) / 'host-signals'
        command = ['clang++', '-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror',
                   str(PROJECT / 'test/native/embedded_host_signals.cpp'), '-o', str(binary)]
        if sys.platform != 'darwin':
            command.append('-ldl')
        with (evidence / 'compiler.log').open('w') as log:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
        results = []
        for mode in ['config', 'deferred']:
            result, template, previous = sdk_case(args, binary, mode, evidence)
            results.append(result)
            if mode == 'config':
                cli_template, cli_previous = template, previous
        for value, reload_first in [(signal.SIGINT, False), (signal.SIGTERM, False),
                                    (signal.SIGTERM, True)]:
            results.append(cli_case(args, cli_template, cli_previous, value,
                                    reload_first, evidence))
        summary = {'schema': 'xveil-embedded-host-signals/1', 'cases': results,
                   'passed': all(row['passed'] for row in results),
                   'ownedFixturesAndProcessesClosed': True,
                   'librarySha256': args.library_sha256, 'cliSha256': args.cli_sha256}
        (evidence / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary))
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        # Do not include private paths, token-bearing commands or native logs.
        print(json.dumps({'passed': False, 'preconditionError': type(error).__name__}))
        raise SystemExit(2)
