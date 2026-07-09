#!/usr/bin/env python3
"""Build the transparent tray icon assets from the design source.

The design source (assets/icon/tray_icon_source.png) is an opaque render with
a checkerboard "transparency" pattern baked in. This script recovers a real
alpha channel (distance from the two checker colors, then un-premultiply),
crops to content, and emits:

  assets/icon/tray_icon.png  128x128 RGBA (macOS menubar @2x headroom, Linux)
  assets/icon/tray_icon.ico  16/24/32/48 32-bit BMP entries (Windows LoadImage)

Pure stdlib (zlib/struct) so it runs on a bare macOS python3.

Usage: python3 tool/make_tray_icon.py [--preview DIR]
"""

import struct
import sys
import zlib

SRC = 'assets/icon/tray_icon_source.png'
OUT_PNG = 'assets/icon/tray_icon.png'
OUT_ICO = 'assets/icon/tray_icon.ico'

# Full opacity once a pixel is this far (RGB euclidean) from both checker
# colors. Lower = harder edges, higher = more of the soft glow survives.
FULL_ALPHA_DIST = 90.0


def read_png_rgb(path):
    with open(path, 'rb') as f:
        data = f.read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'not a png'
    pos = 8
    w = h = None
    color_type = None
    idat = b''
    while pos < len(data):
        (ln,) = struct.unpack('>I', data[pos:pos + 4])
        typ = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + ln]
        if typ == b'IHDR':
            w, h, depth, color_type, comp, filt, interlace = struct.unpack(
                '>IIBBBBB', body)
            assert depth == 8 and interlace == 0, 'unsupported png layout'
            assert color_type in (2, 6), 'need RGB(A) png'
        elif typ == b'IDAT':
            idat += body
        elif typ == b'IEND':
            break
        pos += 12 + ln
    raw = zlib.decompress(idat)
    bpp = 4 if color_type == 6 else 3
    stride = w * bpp
    out = bytearray(w * h * 3)
    prev = bytearray(stride)
    pos = 0
    for y in range(h):
        filt = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if filt == 1:  # Sub
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif filt == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif filt == 3:  # Average
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif filt == 4:  # Paeth
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        o = y * w * 3
        for x in range(w):
            i = x * bpp
            out[o] = line[i]
            out[o + 1] = line[i + 1]
            out[o + 2] = line[i + 2]
            o += 3
        prev = line
    return w, h, out


def write_png_rgba(path, w, h, rgba):
    def chunk(typ, body):
        c = struct.pack('>I', len(body)) + typ + body
        return c + struct.pack('>I', zlib.crc32(typ + body) & 0xFFFFFFFF)

    stride = w * 4
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += rgba[y * stride:(y + 1) * stride]
    body = zlib.compress(bytes(raw), 9)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b'IDAT', body))
        f.write(chunk(b'IEND', b''))


def checker_colors(w, h, rgb):
    """The two flat background colors, sampled from the four corners."""
    from collections import Counter
    cnt = Counter()
    for y0, x0 in ((0, 0), (0, w - 60), (h - 60, 0), (h - 60, w - 60)):
        for y in range(y0, y0 + 60):
            o = (y * w + x0) * 3
            for x in range(60):
                cnt[(rgb[o], rgb[o + 1], rgb[o + 2])] += 1
                o += 3
    first, _ = cnt.most_common(1)[0]
    second = None
    for c, _ in cnt.most_common(50):
        d = sum((a - b) ** 2 for a, b in zip(c, first)) ** 0.5
        if d > 12:
            second = c
            break
    assert second is not None, 'checkerboard colors not found'
    return first, second


def extract_alpha(w, h, rgb):
    ca, cb = checker_colors(w, h, rgb)
    out = bytearray(w * h * 4)
    for i in range(w * h):
        o3 = i * 3
        r, g, b = rgb[o3], rgb[o3 + 1], rgb[o3 + 2]
        da = ((r - ca[0]) ** 2 + (g - ca[1]) ** 2 + (b - ca[2]) ** 2) ** 0.5
        db = ((r - cb[0]) ** 2 + (g - cb[1]) ** 2 + (b - cb[2]) ** 2) ** 0.5
        d = min(da, db)
        a = d / FULL_ALPHA_DIST
        if a >= 1.0:
            a = 1.0
        o4 = i * 4
        if a <= 0.02:
            continue  # stays (0,0,0,0)
        bg = ca if da <= db else cb
        # The source pixel is fg*a + bg*(1-a); recover fg.
        inv = 1.0 - a
        fr = (r - bg[0] * inv) / a
        fg_ = (g - bg[1] * inv) / a
        fb = (b - bg[2] * inv) / a
        out[o4] = max(0, min(255, int(fr + 0.5)))
        out[o4 + 1] = max(0, min(255, int(fg_ + 0.5)))
        out[o4 + 2] = max(0, min(255, int(fb + 0.5)))
        out[o4 + 3] = int(a * 255 + 0.5)
    return out


def crop_square(w, h, rgba, margin_frac=0.04):
    # Frame on the clearly-visible artwork (the faint outer glow tail still
    # renders — it just doesn't inflate the canvas and shrink the glyph).
    minx, miny, maxx, maxy = w, h, -1, -1
    for y in range(h):
        o = y * w * 4 + 3
        for x in range(w):
            if rgba[o] > 40:
                if x < minx:
                    minx = x
                if x > maxx:
                    maxx = x
                if y < miny:
                    miny = y
                if y > maxy:
                    maxy = y
            o += 4
    assert maxx >= 0, 'empty alpha'
    bw, bh = maxx - minx + 1, maxy - miny + 1
    side = int(max(bw, bh) * (1 + margin_frac * 2))
    cx, cy = (minx + maxx) // 2, (miny + maxy) // 2
    out = bytearray(side * side * 4)
    for y in range(side):
        sy = cy - side // 2 + y
        if sy < 0 or sy >= h:
            continue
        for x in range(side):
            sx = cx - side // 2 + x
            if sx < 0 or sx >= w:
                continue
            so, do = (sy * w + sx) * 4, (y * side + x) * 4
            out[do:do + 4] = rgba[so:so + 4]
    return side, out


def resize(sw, rgba, dw):
    """Box-filter square resize on premultiplied components."""
    out = bytearray(dw * dw * 4)
    ratio = sw / dw
    for dy in range(dw):
        y0, y1 = dy * ratio, (dy + 1) * ratio
        for dx in range(dw):
            x0, x1 = dx * ratio, (dx + 1) * ratio
            r = g = b = a = area = 0.0
            sy = int(y0)
            while sy < y1 and sy < sw:
                wy = min(y1, sy + 1) - max(y0, sy)
                sx = int(x0)
                while sx < x1 and sx < sw:
                    wx = min(x1, sx + 1) - max(x0, sx)
                    wgt = wx * wy
                    o = (sy * sw + sx) * 4
                    pa = rgba[o + 3] / 255.0
                    r += rgba[o] * pa * wgt
                    g += rgba[o + 1] * pa * wgt
                    b += rgba[o + 2] * pa * wgt
                    a += pa * wgt
                    area += wgt
                    sx += 1
                sy += 1
            o = (dy * dw + dx) * 4
            if a > 1e-6:
                out[o] = min(255, int(r / a + 0.5))
                out[o + 1] = min(255, int(g / a + 0.5))
                out[o + 2] = min(255, int(b / a + 0.5))
                out[o + 3] = min(255, int(a / area * 255 + 0.5))
    return out


def write_ico(path, sizes_rgba):
    """sizes_rgba: list of (size, rgba). Classic 32-bit BMP entries so
    Windows LoadImage(IMAGE_ICON) accepts them on every version."""
    entries = []
    blobs = []
    offset = 6 + 16 * len(sizes_rgba)
    for s, rgba in sizes_rgba:
        and_stride = ((s + 31) // 32) * 4
        xor = bytearray()
        mask = bytearray()
        for y in range(s - 1, -1, -1):  # bottom-up
            row = bytearray()
            mrow = bytearray(and_stride)
            for x in range(s):
                o = (y * s + x) * 4
                row += bytes((rgba[o + 2], rgba[o + 1], rgba[o], rgba[o + 3]))
                if rgba[o + 3] < 128:
                    mrow[x >> 3] |= 0x80 >> (x & 7)
            xor += row
            mask += mrow
        header = struct.pack('<IiiHHIIiiII', 40, s, s * 2, 1, 32, 0,
                             len(xor) + len(mask), 0, 0, 0, 0)
        blob = header + xor + mask
        entries.append(struct.pack('<BBBBHHII', s % 256, s % 256, 0, 0, 1, 32,
                                   len(blob), offset))
        blobs.append(blob)
        offset += len(blob)
    with open(path, 'wb') as f:
        f.write(struct.pack('<HHH', 0, 1, len(sizes_rgba)))
        for e in entries:
            f.write(e)
        for b in blobs:
            f.write(b)


def composite_preview(path, size, rgba, bg):
    out = bytearray(size * size * 4)
    for i in range(size * size):
        o = i * 4
        a = rgba[o + 3] / 255.0
        for c in range(3):
            out[o + c] = int(rgba[o + c] * a + bg[c] * (1 - a) + 0.5)
        out[o + 3] = 255
    write_png_rgba(path, size, size, out)


def main():
    preview_dir = None
    if '--preview' in sys.argv:
        preview_dir = sys.argv[sys.argv.index('--preview') + 1]
    w, h, rgb = read_png_rgb(SRC)
    print(f'source {w}x{h}')
    rgba = extract_alpha(w, h, rgb)
    side, sq = crop_square(w, h, rgba)
    print(f'content square {side}')
    master = resize(side, sq, 128)
    write_png_rgba(OUT_PNG, 128, 128, master)
    print(f'wrote {OUT_PNG}')
    ico_sizes = [(s, resize(side, sq, s)) for s in (48, 32, 24, 16)]
    write_ico(OUT_ICO, ico_sizes)
    print(f'wrote {OUT_ICO}')
    if preview_dir:
        composite_preview(f'{preview_dir}/tray_on_dark.png', 128, master,
                          (34, 34, 34))
        composite_preview(f'{preview_dir}/tray_on_light.png', 128, master,
                          (238, 238, 238))
        print(f'previews in {preview_dir}')


if __name__ == '__main__':
    main()
