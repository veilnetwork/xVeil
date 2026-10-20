#!/usr/bin/env python3
"""Run Camera2 size selection checks with Kotlin/JVM tools from the Gradle cache."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path(os.environ.get('GRADLE_USER_HOME', Path.home() / '.gradle')) / 'caches/modules-2/files-2.1'
MODULES = [
    ('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.3.20'),
    ('org.jetbrains.kotlin', 'kotlin-stdlib', '2.3.20'),
    ('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.3.20'),
    ('org.jetbrains.kotlin', 'kotlin-reflect', '1.6.10'),
    ('org.jetbrains.kotlin', 'kotlin-daemon-embeddable', '2.3.20'),
    ('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.8.0'),
    ('org.jetbrains.intellij.deps', 'trove4j', '1.0.20200330'),
    ('org.jetbrains', 'annotations', '13.0'),
]

jars = []
for group, name, version in MODULES:
    artifact = next((CACHE / group / name / version).glob('*/*.jar'), None)
    if artifact is None:
        raise SystemExit(f'Missing cached Kotlin check dependency {name}:{version}; no dependencies are downloaded by this check.')
    jars.append(str(artifact))
classpath = os.pathsep.join(jars)
java_home = os.environ.get('JAVA_HOME')
java = str(Path(java_home) / 'bin/java') if java_home else None
if not java:
    bundled = Path('/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java')
    java = str(bundled) if bundled.exists() else shutil.which('java')
if not java:
    raise SystemExit('A JDK is required; set JAVA_HOME.')

temp_root = '/private/tmp/' if sys.platform == 'darwin' else os.environ.get('TMPDIR')
with tempfile.TemporaryDirectory(prefix='xveil-camera-size-', dir=temp_root) as output:
    subprocess.run([
        java, '-cp', classpath, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
        '-no-stdlib', '-no-reflect', '-classpath', classpath,
        '-jvm-target', '17', '-d', output,
        str(ROOT / 'android/app/src/main/kotlin/network/veil/xveil/CallCameraSizePolicy.kt'),
        str(ROOT / 'test/native/CallCameraSizePolicySmoke.kt'),
    ], check=True)
    subprocess.run([
        java, '-cp', output + os.pathsep + classpath,
        'network.veil.xveil.CallCameraSizePolicySmokeKt',
    ], check=True)
