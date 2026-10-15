"""Private synthetic-ADM clock independent of the Python GIL and stats polling."""
import ctypes as C
from pathlib import Path
import subprocess
import sys
import time


class Row(C.Structure):
    _fields_ = [(name, C.c_double) for name in
                ('t', 'source_at', 'rms', 'freq', 'interval_ms')] + [
                    ('source_tick', C.c_uint64), ('side', C.c_uint32),
                    ('source_freq', C.c_uint32)]


class Stats(C.Structure):
    _fields_ = [('max_interval_ms', C.c_double),
                ('late_intervals', C.c_uint64), ('dropped_rows', C.c_uint64),
                ('failures', C.c_uint64 * 2), ('ticks', C.c_uint64)] + [
                    (name, C.c_double) for name in (
                        'max_wake_lateness_ms', 'max_callback_ms',
                        'max_publication_ms')] + [
                            (name, C.c_int32) for name in (
                                'qos_supported', 'qos_result', 'qos_requested', 'qos_actual',
                                'timer_error')]


def build(directory):
    source = Path(__file__).with_suffix('.cc')
    library = directory / ('native_pcm_driver.dylib' if sys.platform == 'darwin'
                           else 'native_pcm_driver.so')
    subprocess.run(['clang++', '-std=c++20', '-O2', '-Wall', '-Wextra', '-Werror',
                    '-pthread', '-dynamiclib' if sys.platform == 'darwin' else '-shared',
                    '-fPIC', str(source), '-o', str(library)], check=True)
    return library


class NativePcmDriver:
    def __init__(self, library, capture, playout, engines, origin, period_ms,
                 priority='audio'):
        self.lib = C.CDLL(str(library))
        signatures = {
            'now': ([], C.c_double),
            'start': ([C.c_void_p] * 4 + [C.c_double, C.c_int, C.c_int], C.c_void_p),
            'poll': ([C.c_void_p, C.POINTER(Row), C.c_size_t, C.POINTER(Stats)], C.c_size_t),
            'request_stop': ([C.c_void_p], None),
            'finished': ([C.c_void_p], C.c_int),
            'destroy': ([C.c_void_p], None),
        }
        for name, (args, result) in signatures.items():
            f = getattr(self.lib, 'stand_pcm_' + name)
            f.argtypes, f.restype = args, result
            setattr(self, '_' + name, f)
        # Do not assume two monotonic clock APIs share an epoch. Both sides
        # must bracket the same clock on this host; no guessed offset is used.
        before = time.monotonic()
        native = self._now()
        after = time.monotonic()
        if not before - 1e-6 <= native <= after + 1e-6:
            raise RuntimeError('Native/Python monotonic clocks do not share an epoch')
        self.clock_check_span_us = (after - before) * 1e6
        self.buffer = (Row * 1024)()
        self.stats = Stats()
        self._keepalive = (capture, playout, engines)
        self.handle = self._start(capture, playout, *engines, origin, period_ms,
                                  int(priority == 'audio'))
        if not self.handle:
            raise RuntimeError('Native PCM driver rejected its arguments')

    def drain(self):
        rows = []
        while self.handle:
            count = self._poll(self.handle, self.buffer, len(self.buffer), C.byref(self.stats))
            rows.extend({name: getattr(row, name) for name, _ in Row._fields_}
                        for row in self.buffer[:count])
            if count < len(self.buffer):
                break
        return rows

    def stop(self):
        if not self.handle:
            return []
        self._request_stop(self.handle)
        deadline = time.monotonic() + 5
        while not self._finished(self.handle):
            if time.monotonic() >= deadline:
                # Keep engines/library alive: an in-flight callback owns them.
                raise RuntimeError('Native PCM driver did not stop within five seconds')
            time.sleep(.001)
        rows = self.drain()
        self._destroy(self.handle)
        self.handle = None
        return rows
