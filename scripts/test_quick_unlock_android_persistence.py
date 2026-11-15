#!/usr/bin/env python3
"""Qualify the native persistence probe on an explicitly selected QA emulator.

Never selects a physical phone or an existing application installation. The
probe APK is built separately from test/native/QuickUnlockPersistenceAndroidProbe.kt.
The production Flutter UI, physical biometric hardware and power loss are outside
this test's scope. --biometric requires virtual fingerprint 1 already enrolled.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

PACKAGE = 'network.veil.quickpersistenceprobe'
ACTIVITY = 'network.veil.xveil.QuickUnlockPersistenceAndroidProbe'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--aapt2', required=True)
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--cycles', type=int, default=5)
    parser.add_argument('--biometric', action='store_true')
    parser.add_argument('--removed-key', action='store_true',
                        help='Test raw channel presence/removal after deleting the synthetic Keystore key')
    parser.add_argument('--damaged-record', action='store_true',
                        help='Require refusal/preservation of a malformed QA preference file')
    parser.add_argument('--stale-cache', action='store_true',
                        help='Require refusal/preservation when the framework cache lost a sibling')
    args = parser.parse_args()
    require(re.fullmatch(r'emulator-[0-9]+', args.serial), 'QA emulator required')
    require(1 <= args.cycles <= 20, 'Invalid QA cycle count')
    require(not args.damaged_record or (args.removed_key and not args.biometric),
            'Damaged-file fixture requires non-biometric --removed-key mode')
    require(not args.stale_cache or (args.removed_key and not args.biometric and not args.damaged_record),
            'Stale-cache fixture requires independent non-biometric --removed-key mode')
    args.output.mkdir(parents=True, exist_ok=False)
    counter = 0

    def command(argv, check=True, input_data=None):
        nonlocal counter
        counter += 1
        result = subprocess.run(argv, input=input_data, capture_output=True, timeout=30)
        (args.output / f'command-{counter}-private.log').write_bytes(
            result.stdout + b'\n' + result.stderr)
        if check:
            require(result.returncode == 0, 'QA command failed; inspect private log')
        return result

    def adb(*argv, check=True, input_data=None):
        return command([args.adb, '-s', args.serial, *argv], check=check, input_data=input_data)

    avd = adb('emu', 'avd', 'name').stdout.decode().splitlines()
    require(avd and avd[0].strip() == 'xveil_persistence_qa', 'Wrong QA emulator')
    badging = command([args.aapt2, 'dump', 'badging', str(args.apk)]).stdout.decode()
    require(re.search(r"^package: name='" + re.escape(PACKAGE) + "'", badging),
            'Wrong probe package')
    require('application-debuggable' in badging, 'Debuggable probe required')
    require(not adb('shell', 'pm', 'path', PACKAGE, check=False).stdout.strip(),
            'Existing QA installation is preserved; use a fresh emulator')
    apk_sha = hashlib.sha256(args.apk.read_bytes()).hexdigest()
    api = int(adb('shell', 'getprop', 'ro.build.version.sdk').stdout.strip())
    seen_pids = set()
    results = []
    installed_by_test = False
    cleanup = {'stopped': False, 'uninstalled': False}
    try:
        installed_by_test = True
        adb('install', '--no-incremental', str(args.apk))
        path = adb('shell', 'pm', 'path', PACKAGE).stdout.decode().strip()
        require(path.startswith('package:'), 'Installed probe path missing')
        path = path[len('package:'):]
        require(re.fullmatch(r'[A-Za-z0-9_./=+~-]+', path), 'Invalid probe path')
        installed_sha = adb('shell', 'sha256sum', path).stdout.decode().split()[0]
        require(installed_sha == apk_sha, 'Installed APK provenance mismatch')
        for cycle in range(args.cycles):
            if args.removed_key and cycle:
                # Key destruction also invalidates the wrapped-key metadata.
                # Begin each independent scenario with a fresh QA installation.
                adb('uninstall', PACKAGE)
                adb('install', '--no-incremental', str(args.apk))
                reset_path = adb('shell', 'pm', 'path', PACKAGE).stdout.decode().strip()
                require(reset_path.startswith('package:'), 'Reset probe path missing')
                reset_path = reset_path[len('package:'):]
                require(re.fullmatch(r'[A-Za-z0-9_./=+~-]+', reset_path), 'Invalid reset probe path')
                require(adb('shell', 'sha256sum', reset_path).stdout.decode().split()[0] == apk_sha,
                        'Reset installed APK provenance mismatch')
            phases = (['write', 'invalidate', 'raw_present', 'raw_delete', 'raw_absent']
                      if args.removed_key else ['write', 'present', 'delete', 'absent'])
            if args.damaged_record:
                phases = ['write', 'invalidate', 'raw_contains_refused', 'raw_remove_refused']
            if args.stale_cache:
                phases = ['write', 'invalidate', 'raw_stale_remove_refused']
            for phase in phases:
                request = f'c{cycle}{phase.replace("_", "")}'
                if args.damaged_record and phase == 'raw_contains_refused':
                    file = 'shared_prefs/xveil_quick_pattern_v1.xml'
                    original = adb('exec-out', 'run-as', PACKAGE, 'cat', file).stdout
                    require(original.count(b'</map>') == 1 and b'<string' in original,
                            'Unexpected QA preference fixture')
                    damaged = original[:original.rfind(b'</map>')]
                    (args.output / f'fixture-{cycle}-original-private.xml').write_bytes(original)
                    (args.output / f'fixture-{cycle}-damaged-private.xml').write_bytes(damaged)
                    adb('exec-in', 'run-as', PACKAGE, 'tee', file, input_data=damaged)
                    require(adb('exec-out', 'run-as', PACKAGE, 'cat', file).stdout == damaged,
                            'QA damage fixture was not written')
                adb('shell', 'am', 'start', '-n', f'{PACKAGE}/{ACTIVITY}',
                    '--es', 'phase', phase, '--es', 'request', request,
                    '--ez', 'biometric', str(args.biometric).lower())
                deadline = time.monotonic() + 30
                report = None
                fingerprint_events = 0
                while time.monotonic() < deadline:
                    raw = adb('exec-out', 'run-as', PACKAGE, 'cat',
                              'files/persistence-qa-result.json', check=False)
                    try:
                        candidate = json.loads(raw.stdout)
                    except (ValueError, UnicodeDecodeError):
                        candidate = None
                    if isinstance(candidate, dict) and candidate.get('request') == request:
                        report = candidate
                        break
                    if args.biometric and (not args.removed_key or phase == 'write'):
                        adb('emu', 'finger', 'touch', '1')
                        fingerprint_events += 1
                    time.sleep(0.1)
                require(report is not None, 'Probe did not report; timeout is not a pass')
                require(report.get('schema') == 'xveil-android-persistence-qa/1'
                        and report.get('phase') == phase and report.get('passed') is True
                        and report.get('biometric') is args.biometric,
                        'Native persistence check failed')
                if args.removed_key and phase != 'write':
                    require(report.get('missing_key_verified') is True,
                            'Keystore absence was not verified')
                if args.damaged_record and phase.endswith('_refused'):
                    require(adb('exec-out', 'run-as', PACKAGE, 'cat', file).stdout == damaged,
                            'Refused operation changed damaged bytes')
                pid = report.get('pid')
                require(type(pid) is int and pid > 0 and pid not in seen_pids,
                        'Fresh probe process not established')
                require(adb('exec-out', 'run-as', PACKAGE, 'cat',
                            f'/proc/{pid}/cmdline').stdout.split(b'\0')[0] == PACKAGE.encode(),
                        'Probe process identity changed')
                top = adb('shell', 'dumpsys', 'activity', 'activities').stdout.decode()
                require(any(('topResumedActivity' in line or 'mResumedActivity' in line)
                            and ACTIVITY in line for line in top.splitlines()),
                        'Probe is not foreground before kill')
                seen_pids.add(pid)
                # run-as cannot kill a different application's UID. No stop,
                # finish or lifecycle request is used before this SIGKILL.
                adb('shell', 'run-as', PACKAGE, 'kill', '-9', str(pid))
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    alive = adb('shell', 'pidof', PACKAGE, check=False).stdout.strip()
                    if not alive:
                        break
                    time.sleep(0.1)
                require(not alive, 'Killed probe process remains or restarted')
                results.append({'cycle': cycle + 1, 'phase': phase, 'passed': True,
                                'fresh_process': True, 'sigkill_confirmed': True,
                                'fingerprint_events': fingerprint_events})
        require(hashlib.sha256(args.apk.read_bytes()).hexdigest() == apk_sha,
                'Probe APK changed during the run')
    finally:
        if installed_by_test:
            adb('shell', 'am', 'force-stop', PACKAGE, check=False)
            cleanup['stopped'] = not adb('shell', 'pidof', PACKAGE, check=False).stdout.strip()
            adb('uninstall', PACKAGE, check=False)
            cleanup['uninstalled'] = not adb('shell', 'pm', 'path', PACKAGE,
                                            check=False).stdout.strip()
        (args.output / 'cleanup-private.json').write_text(json.dumps(cleanup, indent=2))
    require(cleanup['stopped'] and cleanup['uninstalled'], 'QA cleanup incomplete')
    summary = {'schema': 'xveil-android-persistence-qualification/1',
               'android_api': api, 'cycles': args.cycles, 'checks': results,
               'apk_sha256': apk_sha, 'cleanup': cleanup,
               'physical_device': False, 'biometric_authentication': args.biometric}
    summary['removed_key'] = args.removed_key
    summary['damaged_record'] = args.damaged_record
    summary['stale_cache'] = args.stale_cache
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({'passed': True, 'cycles': args.cycles,
                      'fresh_process_checks': len(results), 'cleanup': cleanup}))


if __name__ == '__main__':
    main()
