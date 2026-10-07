#!/usr/bin/env python3
"""Packaging regressions for native dependencies read from ELF program headers."""

import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import builder
from xveil_elf import needed_libraries


def elf(libraries=(), *, wide=True, endian="<"):
    # Minimal shared object with no section headers, as a stripped loader may
    # see it. Virtual addresses deliberately differ from file offsets.
    data = bytearray(1024)
    data[:7] = b"\x7fELF" + bytes([2 if wide else 1, 1 if endian == "<" else 2, 1])
    base, dynamic_at, strings_at = 0x10000, 256, 512
    table = b"\0"
    offsets = []
    for name in libraries:
        offsets.append(len(table))
        table += name.encode("ascii") + b"\0"
    data[strings_at:strings_at + len(table)] = table
    entries = [(1, offset) for offset in offsets] + [(5, base + strings_at), (10, len(table)), (0, 0)]
    dynamic = b"".join(struct.pack(endian + ("qQ" if wide else "iI"), *entry) for entry in entries)
    data[dynamic_at:dynamic_at + len(dynamic)] = dynamic
    if wide:
        struct.pack_into(endian + "Q", data, 32, 64)
        struct.pack_into(endian + "HHH", data, 52, 64, 56, 2)
        fmt = endian + "IIQQQQQQ"
        struct.pack_into(fmt, data, 64, 1, 4, 0, base, base, len(data), len(data), 4096)
        struct.pack_into(fmt, data, 120, 2, 4, dynamic_at, base + dynamic_at, base + dynamic_at, len(dynamic), len(dynamic), 8)
    else:
        struct.pack_into(endian + "I", data, 28, 52)
        struct.pack_into(endian + "HHH", data, 40, 52, 32, 2)
        fmt = endian + "IIIIIIII"
        struct.pack_into(fmt, data, 52, 1, 0, base, base, len(data), len(data), 4, 4096)
        struct.pack_into(fmt, data, 84, 2, dynamic_at, base + dynamic_at, base + dynamic_at, len(dynamic), len(dynamic), 4, 4)
    return bytes(data)


class NativeDependencies(unittest.TestCase):
    def test_stripped_32_and_64_bit_loader_addresses(self):
        for wide in (False, True):
            for endian in ("<", ">"):
                with self.subTest(wide=wide, endian=endian):
                    self.assertEqual(needed_libraries(elf(["libc.so", "libc++_shared.so"], wide=wide, endian=endian)), ["libc.so", "libc++_shared.so"])

    def problems(self, members):
        with tempfile.TemporaryDirectory() as tmp:
            apk = os.path.join(tmp, "test.apk")
            with zipfile.ZipFile(apk, "w") as bundle:
                for path, data in members.items():
                    bundle.writestr(path, data)
            return builder._android_native_dependency_problems(bundle_path=apk, abi="arm64-v8a")

    def test_transitive_runtime_must_be_in_the_same_abi(self):
        members = {
            "lib/arm64-v8a/libffi.so": elf(["libbridge.so", "libc.so"]),
            "lib/arm64-v8a/libbridge.so": elf(["libc++_shared.so"]),
            "lib/x86_64/libc++_shared.so": elf(["libc.so"]),
        }
        self.assertEqual(self.problems(members), ["arm64-v8a: libbridge.so needs missing libc++_shared.so"])
        members["lib/arm64-v8a/libc++_shared.so"] = elf(["libc.so", "libdl.so"])
        self.assertEqual(self.problems(members), [])

    def test_unreadable_library_fails_the_gate(self):
        for data in (b"not ELF", elf(["libc.so"])[:300]):
            with self.subTest(length=len(data)):
                errors = self.problems({"lib/arm64-v8a/libffi.so": data})
                self.assertEqual(len(errors), 1)
                self.assertIn("cannot read libffi.so's loader dependencies", errors[0])


if __name__ == "__main__":
    unittest.main()
