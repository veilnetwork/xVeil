#!/usr/bin/env python3
"""Opt-in physical-camera/codec probe for an isolated Windows media DLL.

Compile windows_camera_loopback_transport.cpp as veilclient_ffi.dll in an owned
scratch directory; never place that synthetic transport in an application.
No app window, profile, real network, audio capture/playout or recording is used.
Camera pixels remain only in transient native/Python frame buffers.
"""
from __future__ import annotations

import argparse
import ctypes as c
import json
import os
from pathlib import Path
import sys
import threading
import time


def probe(media_path: Path, shim_path: Path, capture_diagnostics=False) -> list[dict]:
    # This process must fail on a loader error without an OS error dialog.
    kernel = c.WinDLL('kernel32', use_last_error=True)
    kernel.SetErrorMode.argtypes = [c.c_uint]
    kernel.SetErrorMode.restype = c.c_uint
    kernel.SetErrorMode(0x8003)  # FAILCRITICALERRORS | NOGPFAULT | NOOPENFILE
    for key in list(os.environ):
        if key.startswith('VEIL_MEDIA_'):
            os.environ.pop(key)
    shim = c.CDLL(str(shim_path.resolve(strict=True)))
    counter = shim.probe_packet_count
    counter.argtypes, counter.restype = [], c.c_int64
    media = c.CDLL(str(media_path.resolve(strict=True)))
    ptr, u8ptr = c.c_void_p, c.POINTER(c.c_uint8)

    def bind(name, args, result):
        fn = getattr(media, 'veil_media_engine_' + name)
        fn.argtypes, fn.restype = args, result
        return fn

    create = bind('create', [c.c_uint64, u8ptr, u8ptr], ptr)
    destroy = bind('destroy', [ptr], None)
    video = bind('start_video', [ptr, c.c_int, c.c_int, c.c_int, c.c_int], c.c_int)
    stop_video = bind('stop_video', [ptr], c.c_int)
    camera = bind('start_camera', [ptr, c.c_int, c.c_int, c.c_int], c.c_int)
    camera_device = bind('start_camera_device',
                         [ptr, c.c_char_p, c.c_int, c.c_int, c.c_int], c.c_int)
    stop_camera = bind('stop_camera', [ptr], c.c_int)
    mute = bind('set_mic_muted', [ptr, c.c_int], c.c_int)
    frame_args = [ptr, u8ptr, c.c_int, c.POINTER(c.c_int), c.POINTER(c.c_int)]
    local = bind('get_local_video_frame', frame_args, c.c_int)
    remote = bind('get_video_frame', frame_args, c.c_int)
    stats = bind('get_stats', [ptr], ptr)
    free = media.veil_media_free_string
    free.argtypes, free.restype = [ptr], None
    a, b = (c.c_uint8 * 32)(*[1] * 32), (c.c_uint8 * 32)(*[2] * 32)
    # Fixed capacity, no resizing based on untrusted frame dimensions.
    pixels = (c.c_uint8 * (1920 * 1080 * 4))()
    width, height = c.c_int(), c.c_int()

    def require(value):
        if not value:
            raise RuntimeError('Camera component control failed')

    def read_stats(engine):
        value = stats(engine)
        require(value)
        try:
            return json.loads(c.string_at(value))
        finally:
            free(value)

    def advance(sender, receiver, previous):
        last_local, last_remote = previous
        seen_local = seen_remote = 0
        until = time.monotonic() + 12
        while time.monotonic() < until:
            seq = local(sender, pixels, len(pixels), c.byref(width), c.byref(height))
            require(seq >= 0)
            if seq > last_local:
                last_local = seq
                seen_local += 1
            seq = remote(receiver, pixels, len(pixels), c.byref(width), c.byref(height))
            require(seq >= 0)
            if seq > last_remote:
                last_remote = seq
                seen_remote += 1
            if seen_local >= 10 and seen_remote >= 10:
                return (last_local, last_remote), (seen_local, seen_remote)
            time.sleep(.03)
        raise RuntimeError('Fresh camera/decoder progress deadline expired')

    results = []
    for w, h, fps, kbps in [(352, 198, 15, 150), (640, 360, 60, 900)]:
        sender = receiver = None
        packets_before = counter()
        try:
            receiver = create(43, b, a)
            sender = create(42, a, b)
            require(receiver and sender)
            require(mute(sender, 1) == 0 and mute(receiver, 1) == 0)
            require(video(receiver, 0, 1, kbps, fps) == 0)
            require(video(sender, 1, 0, kbps, fps) == 0)
            require(camera(sender, w, h, fps) == 0)
            previous, first = advance(sender, receiver, (0, 0))
            if capture_diagnostics:
                state = read_stats(sender)
                require(state.get('camera_capture_status') == 2)
                require(state['camera_capture_reads'] >= state['camera_capture_samples'] >=
                        state['camera_capture_frames'] > 0)
            require(stop_camera(sender) == 0)
            if capture_diagnostics:
                state = read_stats(sender)
                require(state.get('camera_capture_status') == 3 and
                        state['camera_capture_frames'] > 0)
                # Explicitly select a nonexistent source, never disable or
                # reconfigure a real device. Releasing the failed object must
                # retain its reason and reset the previous attempt's counters.
                require(camera_device(sender, b'xveil-qa-nonexistent-camera', w, h, fps) != 0)
                state = read_stats(sender)
                require(state.get('camera_capture_status') == 4 and
                        state.get('camera_capture_hresult') == -1)
                require(all(state.get('camera_capture_' + key) == 0
                            for key in ['reads', 'samples', 'frames', 'dropped']))
            require(camera(sender, w, h, fps) == 0)
            _, second = advance(sender, receiver, previous)
            state = read_stats(sender)
            require(state.get('camera_capturing') == 1 and state.get('mic_muted') == 1)
            if capture_diagnostics:
                require(state.get('camera_capture_status') == 2 and
                        state.get('camera_capture_frames', 0) > 0)
            packets = counter() - packets_before
            require(packets > 0)
            require(stop_camera(sender) == 0)
            require(stop_video(sender) == 0 and stop_video(receiver) == 0)
            results.append(dict(requestedWidth=w, requestedHeight=h,
                                requestedFps=fps, requestedKbps=kbps,
                                localUpdatesBeforeRestart=first[0],
                                decodedUpdatesBeforeRestart=first[1],
                                localUpdatesAfterRestart=second[0],
                                decodedUpdatesAfterRestart=second[1],
                                nativeDatagramAttempts=packets,
                                cameraRunningBeforeStop=True,
                                microphoneMuted=True,
                                **({'captureDiagnosticsChecked': True}
                                   if capture_diagnostics else {})))
        finally:
            if sender:
                destroy(sender)
            if receiver:
                destroy(receiver)
    # Native platform workers live until process exit. Do not unload the DLLs.
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--media-dll', type=Path, required=True)
    parser.add_argument('--transport-shim', type=Path, required=True)
    parser.add_argument('--use-physical-camera', action='store_true')
    parser.add_argument('--expect-capture-diagnostics', action='store_true',
                        help='Verify numeric capture evidence, failed-source retention and restart')
    args = parser.parse_args()
    if sys.platform != 'win32' or not args.use_physical_camera:
        parser.error('Requires Windows and explicit --use-physical-camera')
    # Synchronous FFI may block even Python/Dart-level operation deadlines.
    # CDLL releases the GIL; an external process-tree watchdog is also advised.
    watchdog = threading.Timer(60, lambda: os._exit(124))
    watchdog.daemon = True
    watchdog.start()
    try:
        result = probe(args.media_dll, args.transport_shim,
                       args.expect_capture_diagnostics)
        print(json.dumps(dict(success=True, cases=result)))
        return 0
    except Exception as error:
        # No paths, device names, native diagnostics or frame bytes in output.
        print(json.dumps(dict(success=False, failureType=type(error).__name__)))
        return 1
    finally:
        watchdog.cancel()


if __name__ == '__main__':
    raise SystemExit(main())
