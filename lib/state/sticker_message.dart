// Sticker domain helpers (stickers epic, brick 1).
//
// A sticker is a SMALL IMAGE sent through the content path under the `.stkr`
// extension — the bytes are an ordinary decodable image (PNG/JPEG/WebP;
// animated WebP animates for free in Image.memory, which is why Lottie was
// rejected: stickers here are built FROM THE USER'S OWN PICTURES, not a
// designer JSON format). The extension only drives the bubble choice: the
// receiver renders the image NAKED (no bubble chrome), Telegram-style. An
// ordinary image micro-thumb rides the sidecar for render-before-download.

/// File extension a sticker is sent under.
const String kStickerFileExt = '.stkr';

/// Soft cap for sticker bytes: anything under the receiver's auto-download
/// cap lands instantly; imports downscale to fit (512 px longest side).
const int kStickerMaxBytes = 256 * 1024;
const int kStickerMaxDim = 512;

bool isStickerFileName(String? name) {
  if (name == null) return false;
  return name.toLowerCase().endsWith(kStickerFileExt);
}
