/// Overwriting secret buffers before they are released (audit XV-22).
///
/// ## What this actually buys, and what it does not
///
/// The two halves are NOT equally strong, and the difference is the whole
/// reason this file documents itself instead of just calling `fillRange`.
///
/// **Native buffers ([wipeNativeSecret]) — a real guarantee.** `calloc`
/// memory has a fixed address and is never relocated. Zeroing it before
/// `calloc.free` means the allocator hands that block to the next caller with
/// the secret already gone, and a later heap dump of that region finds zeros.
/// This is the case that matters most here: the veil node config carries the
/// Ed25519 PRIVATE KEY, and it is copied into a native buffer on every compose,
/// sign and apply-config.
///
/// **Dart buffers ([wipeSecretBytes]) — best effort, and only that.** Dart's
/// collector MOVES objects. A `Uint8List` that survived a scavenge was copied,
/// and the old copy sits in from-space until something else overwrites it —
/// zeroing the live object cannot reach it. So this shortens the window in
/// which a copy is readable; it does not close it.
///
/// **`String` — cannot be wiped at all.** Dart strings are immutable and
/// interned; there is no supported way to overwrite one. Every secret that
/// exists as a `String` (the node config TOML, an unlock password as typed) is
/// outside what this file can help with. The fix for those is not to hold them
/// as strings, which is a change to the code that produces them, not something
/// a wipe helper can retrofit.
///
/// **Neither half survives the OS.** Nothing here stops the kernel from having
/// paged a page to swap, included it in a core dump, or handed it to a
/// hibernation image. Those need mlock/madvise and are not reachable from Dart.
///
/// Do not write comments elsewhere that promise more than the above.
library;

import 'dart:ffi';
import 'dart:typed_data';

/// Zero [bytes] in place. Null and empty are no-ops.
///
/// Call it on the LAST reference, right before it goes out of scope or the
/// field holding it is nulled — a wipe that runs while another reference is
/// still live corrupts a value someone is about to read. See the library doc
/// for how much this is worth.
void wipeSecretBytes(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) return;
  bytes.fillRange(0, bytes.length, 0);
}

/// Zero [length] bytes at [p] before the buffer is freed.
///
/// Unlike the Dart side this is exact: the allocation does not move, so after
/// this the plaintext is gone from that address.
void wipeNativeSecret(Pointer<Uint8> p, int length) {
  if (length <= 0 || p == nullptr) return;
  p.asTypedList(length).fillRange(0, length, 0);
}
