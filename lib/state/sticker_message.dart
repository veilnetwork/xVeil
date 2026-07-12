// Sticker domain helpers (stickers epic, brick 1).
//
// A sticker is a SMALL IMAGE sent through the content path under the `.stkr`
// extension — the bytes are an ordinary decodable image (PNG/JPEG/WebP;
// animated WebP animates for free in Image.memory, which is why Lottie was
// rejected: stickers here are built FROM THE USER'S OWN PICTURES, not a
// designer JSON format). The extension only drives the bubble choice: the
// receiver renders the image NAKED (no bubble chrome), Telegram-style. An
// ordinary image micro-thumb rides the sidecar for render-before-download.

import 'dart:convert';
import 'dart:typed_data';

// File extension a sticker is sent under.
const String kStickerFileExt = '.stkr';

/// Soft cap for sticker bytes: anything under the receiver's auto-download
/// cap lands instantly; imports downscale to fit (512 px longest side).
const int kStickerMaxBytes = 256 * 1024;
const int kStickerMaxDim = 512;

bool isStickerFileName(String? name) {
  if (name == null) return false;
  return name.toLowerCase().endsWith(kStickerFileExt);
}

/// Extension a shared sticker PACK travels under (a whole collection in one
/// file, so the receiver gets an install card instead of a naked image).
const String kStickerPackFileExt = '.stkpack';
const int kStickerPackMaxItems = 200;

bool isStickerPackFileName(String? name) {
  if (name == null) return false;
  return name.toLowerCase().endsWith(kStickerPackFileExt);
}

/// A decoded shared pack: its display name and each sticker's raw bytes.
class StickerPackBundle {
  const StickerPackBundle({required this.name, required this.images});
  final String name;
  final List<Uint8List> images;
}

/// Serialize a pack into the self-describing STKP1 container:
///   0 : "STKP" magic (4)
///   4 : u8  version = 1
///   5 : u16 LE nameLen ; name (UTF-8)
///     : u16 LE itemCount
///     : itemCount x [ u32 LE len ][ len image bytes ]
/// Not a standard format — it stays in-app (the images are ordinary
/// PNG/WebP the receiver decodes with the platform), like VOICE_OPUS/VNOTE1.
Uint8List encodeStickerPack(String name, List<Uint8List> images) {
  final out = BytesBuilder();
  final nameBytes = utf8.encode(name);
  out.add(ascii.encode('STKP'));
  out.addByte(1);
  out.add(_u16le(nameBytes.length & 0xffff));
  out.add(nameBytes.length > 0xffff
      ? nameBytes.sublist(0, 0xffff)
      : nameBytes);
  final count = images.length > kStickerPackMaxItems
      ? kStickerPackMaxItems
      : images.length;
  out.add(_u16le(count));
  for (var i = 0; i < count; i++) {
    out.add(_u32le(images[i].length));
    out.add(images[i]);
  }
  return out.toBytes();
}

/// Decode an STKP1 container. Strict bounds checks (the blob is network-
/// received); returns null on any inconsistency.
StickerPackBundle? decodeStickerPack(Uint8List b) {
  if (b.length < 9) return null;
  if (!(b[0] == 0x53 && b[1] == 0x54 && b[2] == 0x4B && b[3] == 0x50)) {
    return null; // "STKP"
  }
  if (b[4] != 1) return null;
  var off = 5;
  final nameLen = b[off] | (b[off + 1] << 8);
  off += 2;
  if (off + nameLen > b.length) return null;
  final name = utf8.decode(b.sublist(off, off + nameLen), allowMalformed: true);
  off += nameLen;
  if (off + 2 > b.length) return null;
  final count = b[off] | (b[off + 1] << 8);
  off += 2;
  if (count > kStickerPackMaxItems) return null;
  final images = <Uint8List>[];
  for (var i = 0; i < count; i++) {
    if (off + 4 > b.length) return null;
    final len = b[off] |
        (b[off + 1] << 8) |
        (b[off + 2] << 16) |
        (b[off + 3] << 24);
    off += 4;
    if (len <= 0 || off + len > b.length) return null;
    images.add(Uint8List.sublistView(b, off, off + len));
    off += len;
  }
  if (off != b.length) return null; // trailing garbage
  return StickerPackBundle(name: name, images: images);
}

Uint8List _u16le(int x) => Uint8List.fromList([x & 0xff, (x >> 8) & 0xff]);
Uint8List _u32le(int x) => Uint8List.fromList(
    [x & 0xff, (x >> 8) & 0xff, (x >> 16) & 0xff, (x >> 24) & 0xff]);
