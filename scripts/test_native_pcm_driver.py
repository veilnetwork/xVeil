"""The synthetic source must keep running while Python owns the GIL."""
import ctypes as C
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

from native_pcm_driver import NativePcmDriver, Row, Stats


class NativeClockTests(unittest.TestCase):
    def test_stale_layout_cannot_start_a_native_writer(self):
        for mismatch in ('row_size', 'stats_size'):
            library = Mock()
            library.stand_pcm_row_size.return_value = C.sizeof(Row)
            library.stand_pcm_stats_size.return_value = C.sizeof(Stats)
            getattr(library, 'stand_pcm_' + mismatch).return_value += 8
            with self.subTest(mismatch=mismatch), patch(
                    'native_pcm_driver.C.CDLL', return_value=library):
                with self.assertRaisesRegex(RuntimeError, 'ABI layout mismatch'):
                    NativePcmDriver('unused', None, None, [None, None], 0, 1010)
            library.stand_pcm_start.assert_not_called()

    def test_python_polling_cannot_stop_capture_and_shutdown_joins_it(self):
        self._exercise_clock('audio')

    @unittest.skipUnless(sys.platform == 'darwin', 'Mach time constraints require macOS')
    def test_deadline_policy_is_applied_read_back_and_stopped(self):
        self._exercise_clock('deadline')

    def test_invalid_priority_cannot_start_a_writer(self):
        with patch('native_pcm_driver.C.CDLL') as load:
            with self.assertRaises(ValueError):
                NativePcmDriver('unused', None, None, [None, None], 0, 1010,
                                priority='unexpected')
            load.assert_not_called()

    def _exercise_clock(self, priority):
        source = Path(__file__).with_name('native_pcm_driver.cc')
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            fixture = directory / 'fixture.cc'
            fixture.write_text('''
#include "''' + str(source) + '''"
#include <atomic>
struct Fake { std::atomic<int> calls{0}; };
Fake devices[2];
extern "C" void* fake_device(int i) { return &devices[i]; }
extern "C" int fake_calls(int i) { return devices[i].calls.load(); }
extern "C" int fake_capture(void* device, int) {
  ++static_cast<Fake*>(device)->calls;
  return 0;
}
extern "C" int fake_playout(void*, int16_t* out, size_t capacity) {
  if (capacity != 480) return -1;
  for (size_t i = 0; i < capacity; ++i) out[i] = (i / 48) % 2 ? 12000 : -12000;
  return 480;
}
''')
            library = directory / ('clock.dylib' if sys.platform == 'darwin' else 'clock.so')
            subprocess.run(['clang++', '-std=c++20', '-O2', '-pthread', '-fPIC',
                            '-dynamiclib' if sys.platform == 'darwin' else '-shared',
                            str(fixture), '-o', str(library)], check=True)
            native = C.CDLL(str(library))
            native.fake_device.argtypes, native.fake_device.restype = [C.c_int], C.c_void_p
            native.fake_calls.argtypes, native.fake_calls.restype = [C.c_int], C.c_int
            driver = NativePcmDriver(library, native.fake_capture, native.fake_playout,
                                     [native.fake_device(i) for i in range(2)],
                                     time.monotonic(), 1010, priority=priority)
            try:
                previous = native.fake_calls(0)
                interval = sys.getswitchinterval()
                try:
                    sys.setswitchinterval(.5)
                    deadline = time.monotonic() + .12
                    while time.monotonic() < deadline:
                        pass  # No sleeps, ctypes calls, or deliberate GIL release.
                finally:
                    sys.setswitchinterval(interval)
                self.assertGreaterEqual(native.fake_calls(0) - previous, 2)
                rows = driver.stop()
                self.assertEqual(len(rows), driver.stats.ticks * 2)
                self.assertEqual(driver.stats.dropped_rows, 0)
                self.assertEqual(driver.stats.timer_error, 0)
                self.assertEqual(list(driver.stats.failures), [0, 0])
                self.assertGreater(driver.stats.max_callback_ms, 0)
                self.assertGreater(driver.stats.max_publication_ms, 0)
                self.assertGreaterEqual(driver.stats.max_wake_lateness_ms, 0)
                if sys.platform == 'darwin':
                    self.assertEqual(driver.stats.qos_supported, 1)
                    self.assertEqual(driver.stats.qos_result, 0)
                    self.assertEqual(driver.stats.qos_actual, driver.stats.qos_requested)
                    self.assertNotEqual(driver.stats.qos_actual, 0)
                if priority == 'deadline':
                    self.assertEqual(driver.stats.deadline_requested, 1)
                    self.assertEqual(driver.stats.deadline_result, 0)
                    self.assertEqual(driver.stats.deadline_active, 1)
                    self.assertGreaterEqual(driver.stats.deadline_checks, 2)
                    self.assertEqual(driver.stats.deadline_misses, 0)
                    self.assertLess(driver.stats.deadline_computation_ticks,
                                    driver.stats.deadline_constraint_ticks)
                    self.assertLess(driver.stats.deadline_constraint_ticks,
                                    driver.stats.deadline_period_ticks)
                else:
                    self.assertEqual(driver.stats.deadline_requested, 0)
                    self.assertEqual(driver.stats.deadline_checks, 0)
                for row in rows:
                    self.assertLessEqual(0, row['source_at'])
                    self.assertLessEqual(row['source_at'], row['t'])
                    self.assertEqual(row['rms'], 12000)
                calls = native.fake_calls(0)
                time.sleep(.025)
                self.assertEqual(native.fake_calls(0), calls)
                self.assertIsNone(driver.handle)
                self.assertEqual(driver.stop(), [])
            finally:
                driver.stop()


if __name__ == '__main__':
    unittest.main()
