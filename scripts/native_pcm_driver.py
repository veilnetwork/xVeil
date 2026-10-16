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
    _fields_ += [(name, C.c_int32) for name in (
        'deadline_requested', 'deadline_result', 'deadline_active')]
    _fields_ += [(name, C.c_uint32) for name in (
        'deadline_period_ticks', 'deadline_computation_ticks', 'deadline_constraint_ticks')]
    _fields_ += [(name, C.c_uint32) for name in (
        'deadline_actual_period_ticks', 'deadline_actual_computation_ticks',
        'deadline_actual_constraint_ticks')]
    _fields_ += [(name, C.c_uint64) for name in ('deadline_checks', 'deadline_misses')]


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
                 priority='audio', group=False, local_group=None):
        if priority not in ('audio', 'default', 'deadline'):
            raise ValueError('Unknown synthetic audio scheduling mode')
        if local_group is not None and (type(local_group) is not int or not 0 <= local_group <= 2):
            raise ValueError('Local group participant must be 0, 1 or 2')
        if local_group is not None and group:
            raise ValueError('Select a local or a whole group clock')
        if len(engines) != (1 if local_group is not None else 3 if group else 2):
            raise ValueError('Synthetic clock requires two direct or three group engines')
        if priority == 'deadline' and sys.platform != 'darwin':
            raise ValueError('Deadline scheduling requires macOS')
        self.lib = C.CDLL(str(library))
        for name, expected in (('row_size', C.sizeof(Row)),
                               ('stats_size', C.sizeof(Stats))):
            size = getattr(self.lib, 'stand_pcm_' + name)
            size.argtypes, size.restype = [], C.c_size_t
            if size() != expected:
                raise RuntimeError('Native PCM driver ABI layout mismatch: ' + name)
        signatures = {
            'now': ([], C.c_double),
            'start': ([C.c_void_p] * (5 if group else 4) +
                      [C.c_double, C.c_int, C.c_int], C.c_void_p),
            'poll': ([C.c_void_p, C.POINTER(Row), C.c_size_t, C.POINTER(Stats)], C.c_size_t),
            'request_stop': ([C.c_void_p], None),
            'finished': ([C.c_void_p], C.c_int),
            'destroy': ([C.c_void_p], None),
        }
        for name, (args, result) in signatures.items():
            symbol = 'stand_group_pcm_start' if group and name == 'start' else 'stand_pcm_' + name
            if name == 'start' and local_group is not None:
                symbol = 'stand_group_local_pcm_start'
                args = [C.c_void_p] * 3 + [C.c_int, C.c_double, C.c_int, C.c_int]
            f = getattr(self.lib, symbol)
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
        self.handle = self._start(capture, playout, *engines,
                                  *([] if local_group is None else [local_group]), origin, period_ms,
                                  {'default': 0, 'audio': 1, 'deadline': 2}[priority])
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
