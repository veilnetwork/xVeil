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
/// A version-2 container also carries the author trailer — [authorId] /
/// [authorPubKey] / [signature] plus [signedBytes], the exact prefix the
/// signature covers (kept as a view so verification never reparses).
class StickerPackBundle {
  const StickerPackBundle({
    required this.name,
    required this.images,
    this.authorId,
    this.authorPubKey,
    this.signature,
    this.signedBytes,
  });
  final String name;
  final List<Uint8List> images;
  final Uint8List? authorId; // 32-byte veil node id (v2 only)
  final Uint8List? authorPubKey; // 32-byte ed25519 key (v2 only)
  final Uint8List? signature; // 64-byte ed25519 signature (v2 only)
  final Uint8List? signedBytes; // bytes[0 .. authorId] the signature covers

  /// True for a v2 container. Says nothing about VALIDITY — verification is a
  /// separate (native-crypto) step; a legacy v1 pack is simply unsigned.
  bool get isSigned => signature != null;
}

/// Size of the v2 author trailer: node id (32) + pubkey (32) + signature (64).
const int _kPackSigTrailer = 128;

/// Serialize a pack into the self-describing STKP container:
///   0 : "STKP" magic (4)
///   4 : u8  version = 1 (unsigned) | 2 (signed)
///   5 : u16 LE nameLen ; name (UTF-8)
///     : u16 LE itemCount
///     : itemCount x [ u32 LE len ][ len image bytes ]
///   v2 only, appended:
///     : author node id (32)
///     : author ed25519 public key (32)
///     : ed25519 signature (64) over EVERYTHING before the public key
///       (magic..items + author id — the pubkey is already bound to the node
///       id inside the native verifier via node_id == BLAKE3(pubKey), so
///       covering the id transitively covers the key)
/// Not a standard format — it stays in-app (the images are ordinary
/// PNG/WebP the receiver decodes with the platform), like VOICE_OPUS/VNOTE1.
Uint8List encodeStickerPack(String name, List<Uint8List> images) =>
    _encodePackBody(name, images, version: 1);

/// Serialize + sign: the v2 body with the author trailer. [sign] is the raw
/// ed25519 primitive (native identity behind it) — it returns the signature
/// AND the public key so one call fills the whole trailer. Throws whatever
/// the signer throws (a share flow bug, not network input).
Future<Uint8List> encodeSignedStickerPack(
  String name,
  List<Uint8List> images, {
  required Uint8List authorId,
  required Future<({Uint8List signature, Uint8List publicKey})> Function(
    Uint8List message,
  ) sign,
}) async {
  final out = BytesBuilder()
    ..add(_encodePackBody(name, images, version: 2))
    ..add(authorId);
  final covered = out.toBytes();
  final res = await sign(covered);
  out
    ..add(res.publicKey)
    ..add(res.signature);
  return out.toBytes();
}

Uint8List _encodePackBody(
  String name,
  List<Uint8List> images, {
  required int version,
}) {
  final out = BytesBuilder();
  final nameBytes = utf8.encode(name);
  out.add(ascii.encode('STKP'));
  out.addByte(version);
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

/// Decode an STKP container (v1 legacy-unsigned or v2 signed). Strict bounds
/// checks (the blob is network-received); returns null on any inconsistency.
/// Decoding does NOT verify the v2 signature — that needs native crypto and
/// happens at install time.
StickerPackBundle? decodeStickerPack(Uint8List b) {
  if (b.length < 9) return null;
  if (!(b[0] == 0x53 && b[1] == 0x54 && b[2] == 0x4B && b[3] == 0x50)) {
    return null; // "STKP"
  }
  final version = b[4];
  if (version != 1 && version != 2) return null;
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
  if (version == 1) {
    if (off != b.length) return null; // trailing garbage
    return StickerPackBundle(name: name, images: images);
  }
  // v2: exactly the fixed author trailer must remain.
  if (off + _kPackSigTrailer != b.length) return null;
  return StickerPackBundle(
    name: name,
    images: images,
    authorId: Uint8List.sublistView(b, off, off + 32),
    authorPubKey: Uint8List.sublistView(b, off + 32, off + 64),
    signature: Uint8List.sublistView(b, off + 64, off + 128),
    signedBytes: Uint8List.sublistView(b, 0, off + 32),
  );
}

Uint8List _u16le(int x) => Uint8List.fromList([x & 0xff, (x >> 8) & 0xff]);
Uint8List _u32le(int x) => Uint8List.fromList(
    [x & 0xff, (x >> 8) & 0xff, (x >> 16) & 0xff, (x >> 24) & 0xff]);
