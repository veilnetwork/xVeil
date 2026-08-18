// The `/v1` view of a 1:1 (direct) message and its file, in ONE place.
//
// Two runtimes serve this API — the GUI controller (`lib/state/api_server.dart`)
// and the headless daemon (`lib/headless/headless_runtime.dart`) — and each
// spelled the message JSON out for itself. They agreed on five fields and then
// made the same mistake on the sixth: both emitted the file handle as
// `if (m.fileId != null) 'fileId': m.fileId`, and a RECEIVED large file has no
// fileId yet. A receiver's row for an offered file is exactly
// `fileContentId != null && fileId == null` (see [Message.fileContentId]), so
// over the API such a file arrived as `{"body":"📎 x.bin","fileName":"x.bin"}`
// — visibly a file, with nothing on it to act on — and `GET /v1/files/download`
// 404'd on every id the caller could reach for. The sender's own row for the
// same file DID carry a handle, which is why this survived: it looks right from
// the side that sent it.
//
// One serializer now, so the twins cannot disagree about it again, and one
// fetch step so the handle leads somewhere.

import '../core/ids.dart';
import '../data/storage/storage.dart';
import '../domain/chat.dart';
import '../state/messaging_core.dart';

/// The `/v1` JSON for one 1:1 message.
///
/// [downloaded] is whether the blob is actually in the local store. It is a
/// parameter rather than something derived from [m] because it CANNOT be
/// derived: a completed content-path download stores the bytes under the
/// content hash and never rewrites the message row (see
/// `_surfaceFileOffer` — "the downloaded state is derived from
/// hasFile(contentId), so no message rewrite is needed"). So `fileId == null`
/// does not mean "not here", and a caller that guessed from the row alone
/// would be wrong for every received file. [apiMessagesJson] asks the store.
Map<String, dynamic> apiMessageJson(Message m, {required bool downloaded}) => {
  'id': m.id,
  'body': m.body,
  'direction': m.direction.name,
  'sentAt': m.timestamp.millisecondsSinceEpoch,
  'status': m.status.name,
  if (m.fileName != null) 'fileName': m.fileName,
  // The two file handles, and both go in. `fileId` keys the blob in the local
  // store (a small/inline file, or one we sent ourselves); `fileContentId` is
  // the manifest hash an OFFER carries before the opt-in download. Either is
  // accepted by `GET /v1/files/download`, so a caller takes
  // `fileId ?? fileContentId` — the same idiom every UI call site uses.
  if (m.fileId != null) 'fileId': m.fileId,
  if (m.fileContentId != null) 'fileContentId': m.fileContentId,
  // Known from the OFFER descriptor BEFORE any bytes move — which is the whole
  // point of it being on the message: it is what a receiver decides on.
  if (m.fileSize != null) 'fileSize': m.fileSize,
  // Micro-thumbnail of an image, already inside the message (budget-bound to
  // one datagram), so handing it over costs nothing and saves a fetch for a
  // caller that only wanted to look.
  if (m.thumb != null) 'thumb': m.thumb,
  if (m.isFile) 'fileDownloaded': downloaded,
};

/// The `/v1` JSON for a run of 1:1 messages, asking [storage] which of their
/// blobs are actually held. Only file rows are probed.
Future<List<Map<String, dynamic>>> apiMessagesJson(
  Iterable<Message> messages,
  Storage storage,
) async {
  final out = <Map<String, dynamic>>[];
  for (final m in messages) {
    final key = m.fileId ?? m.fileContentId;
    out.add(
      apiMessageJson(
        m,
        downloaded: key != null && await directFileHeld(storage, key),
      ),
    );
  }
  return out;
}

/// Is the blob behind a 1:1 file handle in the local store?
///
/// Swallows a storage failure into "no": a locked or unavailable container
/// must not turn a message listing into an error, and "not here" is the safe
/// answer — the caller's next move is a fetch, which is idempotent.
Future<bool> directFileHeld(Storage storage, String key) async {
  try {
    return await storage.hasFile(key);
  } catch (_) {
    return false;
  }
}

/// Start the opt-in download of the file OFFERED by [messageId] in the
/// conversation with [peerHex]. Returns null once a fetch is under way (or the
/// bytes were already held), else an error string for the API edge to map.
///
/// The 1:1 twin of [GroupApiAdapter.fetchFile], and deliberately the same
/// shape: the caller names a CONVERSATION and a MESSAGE, never a bare content
/// hash. A bare hash would make this a content oracle — ask for any id and
/// learn from the answer whether this node holds it. Here the id can only come
/// from a message already stored in that conversation, which the caller can
/// already read.
///
/// No `fileRoots` check, matching the group fetch. That grant is about reading
/// a path off the HOST's disk to send it out; pulling a file the peer already
/// offered INTO this node's own store touches no host path at all. A token
/// denied local-file access can still fetch, exactly as it can for a group.
Future<String?> fetchDirectFile(
  Storage storage,
  MessagingService messaging,
  String peerHex,
  String messageId,
) async {
  final NodeId peer;
  try {
    peer = NodeId.fromHex(peerHex);
  } catch (_) {
    return 'invalid peer';
  }
  final Message? row;
  try {
    // By id, not by loading the conversation and walking it. `loadMessages`
    // projects the whole log, filters it to this peer and sorts the result into
    // display order — work an authenticated caller could ask for on every fetch
    // of every file, to read one field off one row it had already named.
    row = await storage.loadMessageById(peer.hex, messageId);
  } catch (_) {
    return 'message attachment load failed';
  }
  // The hash used to REQUEST the bytes: for an offered incoming file that is
  // fileContentId; for our OWN sent file (whose source may be gone) it is
  // fileId, and falling back lets the node pull its own file back from the
  // recipient — content-addressed, so their copy is bit-identical.
  final cid = row?.fileContentId ?? row?.fileId;
  if (cid == null) return 'message attachment not found';
  // Idempotent: already held is success, not a redundant network round.
  if (await directFileHeld(storage, cid)) return null;
  final ContentDownloadResult result;
  try {
    result = await messaging.downloadContent(peer, cid);
  } catch (_) {
    return 'file fetch failed';
  }
  return switch (result) {
    // `requestedReoffer` is a started fetch too: the manifest handle was gone
    // (a restart drops it while the offer MESSAGE survives), so the sender was
    // asked to re-advertise and the download resumes by itself when it does.
    ContentDownloadResult.started ||
    ContentDownloadResult.requestedReoffer => null,
    ContentDownloadResult.noOffer => 'file fetch unavailable',
  };
}
