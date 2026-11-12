#!/usr/bin/env python3
"""Compile the actual Android speech flags and check retained OpenMP metadata.

The fixture deliberately lives below the builder's home. Only counts and fixed
language labels are printed; neither paths nor compiler output are disclosed.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from check_aot_source_paths import current_home_path_count


def run(argv: list[str]) -> None:
    result = subprocess.run(argv, capture_output=True)
    if result.returncode:
        raise RuntimeError("native compiler fixture failed")


def check(ndk: Path) -> bool:
    workflow = Path(__file__).resolve().parents[1] / '.github/workflows/release.yml'
    text = workflow.read_text()
    block = re.search(
        r'(?ms)^      - name: whisper static libs\n(.*?)(?=^      - (?:name|uses):|\Z)', text)
    if block is None:
        raise ValueError('speech build step is missing')
    flags = {}
    for language in ('C', 'CXX'):
        values = re.findall(r'-DCMAKE_' + language + r'_FLAGS="([^"]+)"', block[1])
        if len(values) != 1 or '$GITHUB_WORKSPACE' not in values[0]:
            raise ValueError('speech compiler flags need review')
        flags[language] = values[0]
    toolchains = list((ndk / 'toolchains/llvm/prebuilt').glob('*/bin/llvm-strip'))
    cmake = shutil.which('cmake')
    if len(toolchains) != 1 or cmake is None:
        raise ValueError('NDK and CMake are required')
    with tempfile.TemporaryDirectory(prefix='xveil-openmp-', dir=Path.home()) as directory:
        root = Path(directory)
        source, build = root / 'source', root / 'build'
        source.mkdir()
        body = ('void probe(int *a) {\n#pragma omp parallel for\n'
                'for (int i=0; i<100; i++) a[i]=i;\n}\n')
        for suffix in ('c', 'cpp'):
            (source / ('probe.' + suffix)).write_text(body)
        (source / 'CMakeLists.txt').write_text(
            'cmake_minimum_required(VERSION 3.18)\nproject(PrivacyProbe C CXX)\n'
            'add_library(probe_c STATIC probe.c)\nadd_library(probe_cpp STATIC probe.cpp)\n'
            'target_compile_options(probe_c PRIVATE -fopenmp)\n'
            'target_compile_options(probe_cpp PRIVATE -fopenmp)\n')
        run([cmake, '-S', str(source), '-B', str(build),
             '-DCMAKE_TOOLCHAIN_FILE=' + str(ndk / 'build/cmake/android.toolchain.cmake'),
             '-DANDROID_ABI=arm64-v8a', '-DANDROID_PLATFORM=android-26',
             '-DCMAKE_BUILD_TYPE=Release',
             *['-DCMAKE_' + language + '_FLAGS=' + value.replace('$GITHUB_WORKSPACE', str(source))
               for language, value in flags.items()]])
        run([cmake, '--build', str(build), '--parallel', '2'])
        passed = True
        for language in ('c', 'cpp'):
            archive = build / ('libprobe_' + language + '.a')
            run([str(toolchains[0]), '--strip-debug', str(archive)])
            raw = archive.read_bytes()
            count = current_home_path_count(raw, str(Path.home()))
            retained = b'__kmpc_fork_call' in raw
            print(f'{language}: home_paths={count}, openmp_fork_retained={retained}')
            passed &= count == 0 and retained
        return passed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ndk', required=True, type=Path)
    args = parser.parse_args()
    try:
        return 0 if check(args.ndk.resolve(strict=True)) else 1
    except (OSError, ValueError, RuntimeError) as error:
        print('OpenMP path fixture failed: ' + type(error).__name__)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
