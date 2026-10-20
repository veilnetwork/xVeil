#!/usr/bin/env python3
"""Install the explicit PCM probe in disposable app/SDK exports, never a repo.

This changes the capture/playout device and adds an authenticated QA endpoint.
It leaves production network, codec, adaptation and call-control code intact.
Native media must be built with VEIL_MEDIA_TEST_HOOKS=1 and the existing
native_pcm_driver.cc must be bundled as libxveil_pcm_driver.{so,dylib}.
"""
import argparse
from pathlib import Path
import shutil


def replace(path, before, after):
    text = path.read_text()
    if text.count(before) != 1:
        raise RuntimeError(f'Expected one overlay anchor in {path}: {before[:60]}')
    path.write_text(text.replace(before, after))


def prepare(app, sdk):
    repository = Path(__file__).resolve().parent.parent
    for target in [app, sdk]:
        if (not target.is_dir() or (target / '.git').exists()
                or target == repository or target.is_relative_to(repository)):
            raise ValueError('PCM overlay requires disposable exports outside the repository')
    plugin = sdk / 'flutter/veil_media'
    binding = plugin / 'lib/src/bindings.dart'
    replace(binding, ">>('veil_media_engine_create')",
            ">>(const bool.fromEnvironment('XVEIL_PCM_PROBE')\n"
            "            ? 'veil_media_test_codec_create_unstarted'\n"
            "            : 'veil_media_engine_create')")
    library = plugin / 'lib/veil_media.dart'
    replace(library, "import 'src/bindings.dart' as ffi;",
            "import 'src/bindings.dart' as ffi;\n"
            "import 'src/native.dart' as qa_native;\n"
            "import 'src/qa_pcm_probe.dart';\n"
            "export 'src/qa_pcm_probe.dart' show qaPcmSnapshot;")
    replace(library, '  VeilMediaEngine._(this._ptr);',
            '  VeilMediaEngine._(this._ptr);\n  QaPcmProbe? _qaPcm;')
    replace(library,
            '    return ffi.veilMediaEngineStartAudio(_ptr, send ? 1 : 0, recv ? 1 : 0) == 0;',
            '    final ok = ffi.veilMediaEngineStartAudio(_ptr, send ? 1 : 0, recv ? 1 : 0) == 0;\n'
            '    if (ok) _qaPcm ??= QaPcmProbe.prepare(qa_native.nativeLib, _ptr.cast<Void>());\n'
            '    return ok;')
    replace(library, '    return ffi.veilMediaEngineStopAudio(_ptr) == 0;',
            '    _qaPcm?.stop();\n    _qaPcm = null;\n'
            '    return ffi.veilMediaEngineStopAudio(_ptr) == 0;')
    replace(library,
            '    _disposed = true;\n    ffi.veilMediaEngineDestroy(_ptr);',
            '    _qaPcm?.stop();\n    _qaPcm = null;\n'
            '    _disposed = true;\n    ffi.veilMediaEngineDestroy(_ptr);')
    shutil.copy2(repository / 'scripts/physical_pcm_probe.dart',
                 plugin / 'lib/src/qa_pcm_probe.dart')
    hook = app / 'lib/debug/soak_hook.dart'
    replace(hook, "import 'dart:async';", "import 'dart:async';\n"
            "import 'package:veil_media/veil_media.dart' as qa_media;")
    replace(hook, "        case '/call_state':",
            "        case '/qa_pcm':\n"
            "          await _json(req, qa_media.qaPcmSnapshot(startAt:\n"
            "            double.tryParse(req.uri.queryParameters['start_at'] ?? '')));\n"
            "          return;\n"
            "        case '/call_state':")
    build = plugin / 'android/build_veil_media_so.sh'
    replace(build,
            "if src.endswith('veil_media_engine.cc') and os.environ.get('VEIL_MEDIA_CC_TRACE_BUILD') == '1':",
            "if src.endswith('veil_media_engine.cc') and os.environ.get('VEIL_MEDIA_TEST_HOOKS') == '1':\n"
            "    extra+=' -DVEIL_MEDIA_TEST_HOOKS=1'\n"
            "if src.endswith('veil_media_engine.cc') and os.environ.get('VEIL_MEDIA_CC_TRACE_BUILD') == '1':")


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app-root', type=Path, required=True)
    p.add_argument('--sdk-root', type=Path, required=True)
    args = p.parse_args()
    prepare(args.app_root.resolve(), args.sdk_root.resolve())
