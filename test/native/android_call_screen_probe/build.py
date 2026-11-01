#!/usr/bin/env python3
"""Build an isolated call-window probe; never installs over xVeil or uses keys."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New private directory outside the repository')
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    repo = here.parents[2]
    out = args.output.resolve()
    if out == repo or repo in out.parents or out.exists():
        parser.error('Choose a new directory outside the repository')
    os.umask(0o077)
    out.mkdir(parents=True)
    sdk = repo / 'third_party/veil/flutter/veil_flutter/android'
    source = out / 'app/src/main'
    kotlin = source / 'java/com/veil/veil_flutter'
    kotlin.mkdir(parents=True)
    proof = {}
    for name in ['CallScreenActivity.kt', 'CallActionCapability.kt', 'VeilDaemonService.kt']:
        original = sdk / 'src/main/kotlin/com/veil/veil_flutter' / name
        shutil.copy2(original, kotlin / name)
        proof[str(original.relative_to(repo))] = hashlib.sha256(original.read_bytes()).hexdigest()
    shutil.copy2(here / 'Harness.kt', kotlin / 'Harness.kt')
    shutil.copytree(sdk / 'src/main/res', source / 'res')
    for name in ['settings.gradle.kts', 'gradle.properties']:
        shutil.copy2(here / name, out / name)
    shutil.copy2(here / 'app.gradle.kts', out / 'app/build.gradle.kts')
    shutil.copy2(here / 'AndroidManifest.xml', source / 'AndroidManifest.xml')
    shutil.copy2(repo / 'android/local.properties', out / 'local.properties')
    settings = (repo / 'android/settings.gradle.kts').read_text()
    agp = re.search(r'id\("com.android.application"\) version "([^"]+)"', settings).group(1)
    (out / 'build.gradle.kts').write_text(
        f'plugins {{ id("com.android.application") version "{agp}" apply false }}\n')
    (out / 'source-proof.json').write_text(json.dumps(proof, indent=2))
    if not args.prepare_only:
        subprocess.run([str(repo / 'android/gradlew'), '-p', str(out),
                        ':app:assembleDebug', '--console=plain'], check=True,
                       env={**os.environ, 'TMPDIR': '/private/tmp/'})
    assert all(hashlib.sha256((repo / name).read_bytes()).hexdigest() == digest
               for name, digest in proof.items()), 'Source changed during probe build'


if __name__ == '__main__':
    main()
