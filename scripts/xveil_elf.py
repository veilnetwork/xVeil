"""Read ELF loader dependencies without requiring host binutils or an NDK."""

import struct


def needed_libraries(data: bytes) -> list[str]:
    if len(data) < 16 or data[:4] != b"\x7fELF" or data[4] not in (1, 2) or data[5] not in (1, 2):
        raise ValueError("invalid ELF header")
    wide = data[4] == 2
    endian = "<" if data[5] == 1 else ">"

    def read(fmt: str, offset: int):
        size = struct.calcsize(endian + fmt)
        if offset < 0 or offset + size > len(data):
            raise ValueError("truncated ELF")
        return struct.unpack_from(endian + fmt, data, offset)

    phoff = read("Q" if wide else "I", 32 if wide else 28)[0]
    stride, count = read("HH", 54 if wide else 42)
    if stride < (56 if wide else 32) or count > 4096 or phoff + stride * count > len(data):
        raise ValueError("invalid ELF program headers")
    loads = []
    dynamic = None
    for index in range(count):
        at = phoff + index * stride
        kind = read("I", at)[0]
        if kind not in (1, 2):
            continue
        offset, address = read("QQ" if wide else "II", at + (8 if wide else 4))
        size = read("Q" if wide else "I", at + (32 if wide else 16))[0]
        if offset + size > len(data):
            raise ValueError("truncated ELF segment")
        if kind == 1:
            loads.append((address, offset, size))
        else:
            dynamic = (offset, size)
    if dynamic is None:
        raise ValueError("ELF shared library has no dynamic segment")
    needed = []
    strings = string_size = None
    offset, size = dynamic
    entry_size = 16 if wide else 8
    terminated = False
    for at in range(offset, offset + size - entry_size + 1, entry_size):
        tag, value = read("qQ" if wide else "iI", at)
        if tag == 0:
            terminated = True
            break
        if tag == 1:
            needed.append(value)
        elif tag == 5:
            strings = value
        elif tag == 10:
            string_size = value
    if not terminated:
        raise ValueError("unterminated ELF dynamic segment")
    if not needed:
        return []
    if strings is None or string_size is None:
        raise ValueError("ELF dependencies have no string table")
    for address, offset, size in loads:
        delta = strings - address
        if 0 <= delta and delta + string_size <= size:
            table = data[offset + delta : offset + delta + string_size]
            break
    else:
        raise ValueError("ELF string table is outside loaded segments")
    names = []
    for at in needed:
        end = table.find(b"\0", at)
        if at >= len(table) or end < 0:
            raise ValueError("invalid ELF dependency name")
        name = table[at:end].decode("ascii")
        if not name or "/" in name or "\\" in name:
            raise ValueError("ELF dependency is not a library filename")
        if name not in names:
            names.append(name)
    return names
