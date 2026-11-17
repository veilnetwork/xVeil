#!/usr/bin/env python3
"""Build an Activity-free, synthetic-media Android instrumentation package."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New private directory outside the checkout')
    parser.add_argument('--flutter-sdk', required=True, type=Path)
    parser.add_argument('--android-sdk', required=True, type=Path)
    parser.add_argument('--java-home', required=True, type=Path)
    parser.add_argument('--runtime', action='append', required=True, type=Path,
                        help='Embedding runtime dependency JAR/AAR; repeat for each dependency')
    parser.add_argument('--build-tools', default='35.0.0')
    parser.add_argument('--platform', default='android-35')
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    repo = here.parents[2]
    out = args.output.resolve()
    if out.exists() or out == repo or repo in out.parents:
        parser.error('Output must be new and outside the repository')
    os.umask(0o077)
    out.mkdir(parents=True)
    env = {**os.environ, 'JAVA_HOME': str(args.java_home.resolve()),
           'TMPDIR': '/private/tmp/'}
    tools = args.android_sdk / 'build-tools' / args.build_tools
    android = args.android_sdk / 'platforms' / args.platform / 'android.jar'
    java = args.java_home / 'bin'
    flutter_jar = args.flutter_sdk / 'bin/cache/artifacts/engine/android-arm64/flutter.jar'

    def run(*command):
        subprocess.run([str(value) for value in command], cwd=repo, env=env, check=True)

    # Verify the checkout's Dart inputs did not change during compilation.
    names = subprocess.check_output(
        ['git', 'ls-files', '--recurse-submodules', '-z', '--', '*.dart',
         '*pubspec.yaml', '*pubspec.lock'], cwd=repo).decode().split('\0')
    inputs = {repo / name for name in names if name and (repo / name).is_file()}
    inputs.update([here / 'probe.dart', here / 'Probe.java', Path(__file__).resolve()])
    sources = {str(path.relative_to(repo)): digest(path) for path in sorted(inputs)}
    (out / 'classes').mkdir()
    (out / 'dex').mkdir()
    assets = out / 'assets/flutter_assets'
    run(args.flutter_sdk / 'bin/flutter', 'build', 'bundle', '--debug', '--no-pub',
        '--target-platform', 'android-arm64', '--target', here / 'probe.dart',
        '--asset-dir', assets, '--depfile', out / 'kernel.d')
    with zipfile.ZipFile(flutter_jar) as source, zipfile.ZipFile(
            out / 'flutter-classes.jar', 'w', zipfile.ZIP_DEFLATED) as target:
        for name in source.namelist():
            if name.endswith('.class'):
                target.writestr(name, source.read(name))
    dependencies = []
    for index, path in enumerate(args.runtime):
        if path.suffix == '.aar':
            jar = out / f'runtime-{index}.jar'
            with zipfile.ZipFile(path) as archive:
                jar.write_bytes(archive.read('classes.jar'))
        else:
            jar = path
        dependencies.append(jar)
    run(java / 'javac', '-source', '8', '-target', '8', '-classpath',
        os.pathsep.join(map(str, [android, out / 'flutter-classes.jar'])),
        '-d', out / 'classes', here / 'Probe.java')
    run(java / 'jar', 'cf', out / 'probe.jar', '-C', out / 'classes', '.')
    run(tools / 'd8', '--min-api', '26', '--lib', android, '--output', out / 'dex',
        out / 'flutter-classes.jar', out / 'probe.jar', *dependencies)
    (out / 'AndroidManifest.xml').write_text('''<manifest
 xmlns:android="http://schemas.android.com/apk/res/android"
 package="network.veil.qa.headless.screenlifetime">
 <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="30"/>
 <application android:label="Headless media QA" android:debuggable="true"
              android:extractNativeLibs="true"/>
 <instrumentation android:name="qa.Probe"
     android:targetPackage="network.veil.qa.headless.screenlifetime"
     android:functionalTest="true"/>
</manifest>''')
    run(tools / 'aapt2', 'link', '-o', out / 'base.apk', '--manifest',
        out / 'AndroidManifest.xml', '-I', android, '-A', out / 'assets')
    with zipfile.ZipFile(out / 'base.apk', 'a', zipfile.ZIP_DEFLATED) as apk, \
            zipfile.ZipFile(flutter_jar) as engine:
        apk.writestr('classes.dex', (out / 'dex/classes.dex').read_bytes())
        apk.writestr('lib/arm64-v8a/libflutter.so',
                     engine.read('lib/arm64-v8a/libflutter.so'))
    run(tools / 'zipalign', '-f', '4', out / 'base.apk', out / 'aligned.apk')
    run(java / 'keytool', '-genkeypair', '-keystore', out / 'qa.keystore',
        '-storepass', 'android', '-keypass', 'android', '-alias', 'qa',
        '-keyalg', 'RSA', '-keysize', '2048', '-validity', '30', '-dname', 'CN=QA')
    run(tools / 'apksigner', 'sign', '--ks', out / 'qa.keystore', '--ks-pass',
        'pass:android', '--out', out / 'probe.apk', out / 'aligned.apk')
    assert all(digest(repo / name) == sha for name, sha in sources.items()), \
        'Source changed during the build'
    proof = {'sources': sources, 'flutter_jar': digest(flutter_jar),
             'runtime': [{'name': p.name, 'sha256': digest(p)} for p in args.runtime],
             'kernel': digest(assets / 'kernel_blob.bin'), 'apk': digest(out / 'probe.apk')}
    (out / 'source-proof.json').write_text(json.dumps(proof, indent=2))
    # Retain one installable APK, not three copies of the debug engine.
    for name in ['base.apk', 'aligned.apk']:
        (out / name).unlink()
    print('Built isolated probe.apk; nothing installed or launched')


if __name__ == '__main__':
    main()
