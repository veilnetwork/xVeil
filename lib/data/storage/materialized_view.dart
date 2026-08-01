// The on-disk layout of a materialized view (the cloud index, its replica
// claims, its seen-revision map), in ONE place.
//
// The layout was already spelled out twice — once by the writer in
// `CloudService`, once by the GC reachability scan in `HiddenVolumeStorage`,
// which reads the index directly to learn which content is still referenced.
// While a view was a single blob the duplication was survivable. Paging made
// it load-bearing: a reader that does not know about pages sees an EMPTY index
// and concludes nothing is referenced, and the thing on the other end of that
// conclusion is a garbage collector.
//
// So the layout lives here, parameterised by the two accessors each layer
// already has, rather than being restated by whoever needs it next.

import 'dart:convert';
import 'dart:typed_data';

/// Bytes per page.
///
/// A view used to be ONE stored blob, which the deniable file store caps at
/// `kMaxStoredFileBytes` (~3.6 MB). Reaching that did not degrade gracefully:
/// the index simply could no longer be written, so every later mutation failed
/// and the device's picture of the account drifted from the account. Pages sit
/// an order of magnitude under the cap.
const int kMaterializedPageBytes = 512 * 1024;

/// Hard ceiling for one view, across all its pages.
///
/// Not the store's limit — paging removed that — but a deliberate one. A view
/// this large is a symptom (runaway history, a replication loop) and should
/// say so where a human can read it, rather than growing until some other
/// resource gives out first.
const int kMaterializedViewMaxBytes = 64 * 1024 * 1024;

/// Reads a settings value, or null.
typedef ViewSettingReader = Future<String?> Function(String key);

/// Reads a stored file, or null.
typedef ViewFileReader = Future<Uint8List?> Function(String fileId);

/// Publish [value] as the new authoritative copy of the view at [key].
///
/// ## The commit protocol
///
/// Writes go to the INACTIVE slot, in this exact order:
///
/// 1. every page,
/// 2. the page count for that slot,
/// 3. the `key.active` pointer.
///
/// The order is the whole guarantee, so it is pinned by a test rather than
/// left to a comment. A crash before (2) leaves a slot the reader cannot open;
/// a crash before (3) leaves the previous generation authoritative. Both are
/// recoverable. Flipping (3) early is not: a slot that already held MORE pages
/// than the new generation would then be read as fresh page 0 concatenated
/// with stale pages 1..n — a document that parses, and is wrong.
///
/// Throws [StateError] past [kMaterializedViewMaxBytes].
Future<void> writeMaterializedViewWith({
  required String key,
  required String value,
  required ViewSettingReader getSetting,
  required Future<void> Function(String key, String value) putSetting,
  required Future<void> Function(String fileId, Uint8List bytes) storeFile,
  required Future<bool> Function(String fileId) hasFile,
}) async {
  var active = await getSetting('$key.active');
  if (active == 'a' || active == 'b') {
    final other = active == 'a' ? 'b' : 'a';
    final activePresent = await materializedSlotPresent(
      key: key,
      slot: active!,
      getSetting: getSetting,
      hasFile: hasFile,
    );
    final otherPresent = await materializedSlotPresent(
      key: key,
      slot: other,
      getSetting: getSetting,
      hasFile: hasFile,
    );
    if (!activePresent && otherPresent) {
      // The pointer survived but its slot did not. Treat the readable fallback
      // as active so we never overwrite the only valid copy.
      active = other;
    }
  }
  final next = active == 'a' ? 'b' : 'a';
  final bytes = Uint8List.fromList(utf8.encode(value));

  // Quota BEFORE writing anything. Past this the view is not merely large, it
  // is a symptom — and failing here names it, where the old behaviour was a
  // raw `PayloadTooLarge` thrown out of the store with nothing to act on.
  if (bytes.length > kMaterializedViewMaxBytes) {
    throw StateError(
      'cloud view "$key" is ${bytes.length} bytes, over the '
      '$kMaterializedViewMaxBytes-byte quota',
    );
  }

  final pageCount = bytes.isEmpty
      ? 0
      : (bytes.length + kMaterializedPageBytes - 1) ~/ kMaterializedPageBytes;
  for (var i = 0; i < pageCount; i++) {
    final start = i * kMaterializedPageBytes;
    final end = start + kMaterializedPageBytes;
    await storeFile(
      '$key.$next.p$i',
      Uint8List.sublistView(
        bytes,
        start,
        end > bytes.length ? bytes.length : end,
      ),
    );
  }
  await putSetting('$key.$next.pages', '$pageCount');
  await putSetting('$key.active', next);
}

/// Read the view at [key]: the active slot first, then its predecessor.
///
/// [accept] rejects a slot whose contents are the wrong shape, so a
/// half-written or malformed slot falls through instead of being returned.
Future<String?> readMaterializedView({
  required String key,
  required ViewSettingReader getSetting,
  required ViewFileReader loadFile,
  bool Function(String decoded)? accept,
}) async {
  final active = await getSetting('$key.active');
  final slots = active == 'a' || active == 'b'
      ? [active!, active == 'a' ? 'b' : 'a']
      : const ['a', 'b'];
  for (final slot in slots) {
    final decoded = await readMaterializedSlot(
      key: key,
      slot: slot,
      getSetting: getSetting,
      loadFile: loadFile,
    );
    if (decoded == null) continue;
    if (accept == null || accept(decoded)) return decoded;
  }
  return null;
}

/// Read ONE slot, paged or legacy-whole, or null if it holds no usable view.
///
/// A slot written before paging is a single blob at `key.slot` with no page
/// count, and it stays readable: an upgrade must not look like a wiped index,
/// because the reconcile that follows would treat every cloud item as new —
/// and the GC scan would treat every blob it named as unreferenced.
Future<String?> readMaterializedSlot({
  required String key,
  required String slot,
  required ViewSettingReader getSetting,
  required ViewFileReader loadFile,
}) async {
  final countRaw = await getSetting('$key.$slot.pages');
  if (countRaw == null) {
    final whole = await loadFile('$key.$slot');
    return whole == null ? null : utf8.decode(whole, allowMalformed: true);
  }
  final pages = int.tryParse(countRaw);
  if (pages == null || pages < 0) return null;
  final buf = BytesBuilder(copy: false);
  for (var i = 0; i < pages; i++) {
    final page = await loadFile('$key.$slot.p$i');
    // A missing page makes the WHOLE slot unusable. Returning the prefix would
    // hand back a truncated document that either fails to parse or — far worse
    // — parses to a SHORTER index, which reconcile reads as mass deletion and
    // the GC scan reads as "these blobs are unreferenced".
    if (page == null) return null;
    buf.add(page);
  }
  return utf8.decode(buf.toBytes(), allowMalformed: true);
}

/// Whether [slot] currently holds something readable.
Future<bool> materializedSlotPresent({
  required String key,
  required String slot,
  required ViewSettingReader getSetting,
  required Future<bool> Function(String fileId) hasFile,
}) async {
  final countRaw = await getSetting('$key.$slot.pages');
  if (countRaw == null) return hasFile('$key.$slot');
  final pages = int.tryParse(countRaw);
  if (pages == null) return false;
  if (pages == 0) return true;
  return hasFile('$key.$slot.p0');
}
