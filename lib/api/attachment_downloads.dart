// What `GET /v1/files/download` is allowed to hand over.
//
// The route took a `fileId` and read it straight out of the store. The store
// is not an attachment store: the same namespace holds `groups.index` and
// `group:<hex>` — whose JSON carries epoch keys in `kk`/`ckk` — and
// `cloud.capabilities.registry.v2`, whose rows carry a provider's private
// seed. A read-only bearer token, which is meant to read messages, could ask
// for those by name and receive them (report24 A4-1).
//
// A denylist of today's internal names would be a promise about names nobody
// has written yet. This asks the opposite question — is this id something a
// MESSAGE or the cloud index actually references — so a blob that is not
// somebody's attachment is not downloadable no matter what it is called.
//
// ## The cost, and why it is bounded this way
//
// The provenance set comes from [Storage.sharedContentReferenceSnapshot],
// which walks the message log. Doing that per request would turn a download
// loop into a scan loop, so the answer is cached for [ttl]. A MISS refreshes
// at most once every [refreshFloor] — enough that an attachment which arrived
// a second ago becomes downloadable without a wait, while a caller asking for
// ids that do not exist cannot drive a scan per request.

import '../data/storage/storage.dart';
import 'api_server.dart';
import 'blob_sources.dart';

/// Serves stored blobs, but only those a message or the cloud index references.
class AttachmentDownloads {
  AttachmentDownloads(
    this._storage, {
    Duration ttl = const Duration(seconds: 30),
    Duration refreshFloor = const Duration(seconds: 5),
    int Function()? nowMs,
  }) : _ttl = ttl.inMilliseconds,
       _floor = refreshFloor.inMilliseconds,
       _now = nowMs ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final Storage _storage;
  final int _ttl;
  final int _floor;
  final int Function() _now;

  Set<String> _referenced = const {};
  int _refreshedAtMs = -1 << 40;

  /// Whether [fileId] is an attachment this identity actually holds a
  /// reference to.
  Future<bool> mayServe(String fileId) async {
    if (fileId.isEmpty) return false;
    final age = _now() - _refreshedAtMs;
    if (age > _ttl) await _refresh();
    if (_referenced.contains(fileId)) return true;
    // A miss on a stale-ish set may simply be an attachment that arrived after
    // the last walk. One refresh, no more often than the floor allows.
    if (_now() - _refreshedAtMs > _floor) {
      await _refresh();
      return _referenced.contains(fileId);
    }
    return false;
  }

  /// [storedBlobSource], gated by [mayServe]. Null reads exactly like "no such
  /// file", which is what an unauthorised id should look like from outside.
  Future<ApiBlobSource?> open(
    String fileId, {
    String contentType = 'application/octet-stream',
  }) async {
    if (!await mayServe(fileId)) return null;
    return storedBlobSource(_storage, fileId, contentType: contentType);
  }

  Future<void> _refresh() async {
    try {
      final snapshot = await _storage.sharedContentReferenceSnapshot();
      _referenced = snapshot.referencedContentIds;
    } catch (_) {
      // Leave the previous answer in place: failing open would serve the very
      // blobs this exists to withhold, and failing closed on a transient error
      // would break ordinary downloads.
    }
    _refreshedAtMs = _now();
  }
}
