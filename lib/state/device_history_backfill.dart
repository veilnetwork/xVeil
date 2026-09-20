// Answering another of my devices when it asks for the history it never got.
//
// Linking starts FORWARD sync and nothing else: from the moment a device is
// signed into the registry the two converge, and everything from before stays
// on the device that has it. This walks that "before" and posts it as the
// events an online sibling would have sent anyway — the same vocabulary, the
// same keys, the same merge rule (`foldDeviceSync`). The receiving device needs
// no new code at all: `applyMirrorEvent` and the sync bridge already apply
// every kind this emits, whether it arrives live, out of a snapshot chunk or
// out of a mailbox drain.
//
// WHAT MAY NOT ROLL BACK. A message mirror is keyed by message id, so its real
// timestamp is safe and necessary — the timestamp IS where the message sits in
// the conversation. A CONTACT row is different: the container records what a
// contact's status is, never when it was decided, so there is no honest "when"
// to carry, and a replay stamped `now` would make every stale value the newest
// thing the fold has ever seen (an `accepted` contact put back to `blocked`,
// and nothing saying so — report27 X05, found on the archive path first). Those
// rows therefore carry a COUNTER, which loses to any real event and wins only
// where the receiving device has nothing at all. Fill a gap, never overwrite.

import 'dart:async';

import '../data/storage/storage.dart';
import '../domain/chat.dart' show Message;
import '../domain/device_history_ask.dart';
import '../domain/device_sync.dart';
import '../domain/inline_custom_emoji.dart';
import '../domain/media_object.dart';
// The ONE contact-preferences builder the app has — the same import the
// archive walk takes, and for the same reason: a field added to `Contact` and
// forgotten in a second copy of this list syncs on one path and not the other.
import 'device_sync_bridge.dart' show contactPrefsPayload;

/// The mirror event a stored [message] travels as, and the attachment
/// reference that authorizes another device to pull its bytes.
///
/// ONE builder for the live emit and for a replay, because the receiving side
/// cannot tell them apart and must not have to: a field added here reaches both
/// paths, and a field added to only one of two copies is how a mirror comes to
/// carry less than the message it mirrors.
({DeviceSyncEvent event, MediaObject? attachment}) deviceMirrorOf(
  String peerHex,
  Message message, {
  bool withFileBytes = true,
}) {
  final contentId = message.fileContentId ?? message.fileId;
  if (contentId == null) {
    return (
      event: DeviceSyncEvent(
        kind: DeviceSyncKind.msgMirror,
        key: message.id,
        tsMs: message.timestamp.millisecondsSinceEpoch,
        payload: {
          'peer': peerHex,
          'dir': message.direction.name,
          'body': message.body,
          if (message.customEmoji.isNotEmpty)
            'ce': encodeInlineCustomEmoji(message.customEmoji),
        },
      ),
      attachment: null,
    );
  }
  return (
    event: DeviceSyncEvent(
      kind: DeviceSyncKind.msgMirror,
      key: message.id,
      tsMs: message.timestamp.millisecondsSinceEpoch,
      payload: {
        'peer': peerHex,
        'dir': message.direction.name,
        'body': message.body,
        // The bytes stay where they are: the mirror carries the CONTENT ID and
        // the reference below is what lets the other device pull them.
        'cid': contentId,
        'fname': message.fileName,
        'fsize': message.fileSize,
        if (message.customEmoji.isNotEmpty)
          'ce': encodeInlineCustomEmoji(message.customEmoji),
      },
    ),
    // Without the reference the row still arrives and still reads as a file
    // message — it just cannot be downloaded. That is the honest shape of "not
    // the files", and it is why leaving them out loses no conversation.
    attachment: withFileBytes
        ? MediaObject(
            kind: 'file',
            dataB64: (message.thumb?.isNotEmpty ?? false)
                ? message.thumb!
                : 'AA==',
            w: 1,
            h: 1,
            cid: contentId,
          )
        : null,
  );
}

/// Whether [event] is a history ask THIS device must answer, and now.
///
/// Four refusals, and every one of them was a way to get this wrong:
///
///  * a payload this build cannot act on — a newer vocabulary, or a field that
///    did not survive the trip. Refused rather than guessed at, because the
///    guess would be "send everything".
///  * our OWN ask, echoed back by the log we posted it to.
///  * an ask addressed to a DIFFERENT device. Every device sees this row — the
///    group is a broadcast log — and without this check every one of them
///    would answer at once, each posting its own full copy into the same log.
///  * an ask ALREADY SERVED. The folded device-sync state is replayed into the
///    appliers on every bridge build, so an answered ask that left no record
///    would be answered again on every app start, for as long as its row lived
///    in the log.
///
/// Pure on purpose: the decision is the whole of the responder that can be
/// wrong, and inside a provider it could only be checked by standing up the
/// app.
DeviceHistoryAsk? historyAskToServe({
  required DeviceSyncEvent event,
  required String myDeviceHex,
  required int? alreadyServedMs,
}) {
  if (event.kind != DeviceSyncKind.historyAsk) return null;
  final ask = DeviceHistoryAsk.fromPayload(event.payload);
  if (ask == null) return null;
  if (event.key == myDeviceHex) return null;
  if (!ask.asks(myDeviceHex)) return null;
  if (alreadyServedMs != null && event.tsMs <= alreadyServedMs) return null;
  return ask;
}

/// Walk what this device holds and post it for the device that asked.
///
/// [post] is the device-group append (`GroupService.postDeviceEvent`); it
/// answers false when the post did not happen, and a replay that cannot post
/// stops rather than counting rows it never sent.
///
/// [cancelled] is checked between every row and every batch. A replay can be a
/// full copy of a year of conversations, so it must be interruptible at a
/// granularity finer than "when it ends".
///
/// [pause] is taken every [batch] events. The device group's log is append-only
/// and SHARED with every other device, so a full copy is the heaviest thing
/// this app can ask of it; pacing keeps the rest of the group's traffic — a
/// message, a call invite — moving while it runs.
Future<DeviceHistoryReplay> replayHistoryForAsk({
  required DeviceHistoryAsk ask,
  required Storage storage,
  required Future<bool> Function(
    DeviceSyncEvent event, {
    MediaObject? attachment,
  })
  post,
  bool Function()? cancelled,
  void Function(int sent)? onProgress,
  int batch = 25,
  Duration pause = const Duration(milliseconds: 150),
}) async {
  var conversations = 0, messages = 0, contacts = 0, calls = 0, readMarks = 0;
  var sent = 0;
  var stopped = false;

  // See the header: contact rows carry a counter so they can only ever fill a
  // gap. It starts at 1 rather than 0 because a zero timestamp reads as "no
  // value" in more than one place this event passes through.
  var fillOrder = 0;
  int nextFillStamp() => ++fillOrder;

  Future<bool> emit(DeviceSyncEvent e, {MediaObject? attachment}) async {
    if (cancelled?.call() ?? false) {
      stopped = true;
      return false;
    }
    if (!await post(e, attachment: attachment)) {
      stopped = true;
      return false;
    }
    sent++;
    onProgress?.call(sent);
    if (sent % batch == 0) await Future<void>.delayed(pause);
    return true;
  }

  final wanted = ask.peers?.toSet();
  for (final conversation in await storage.loadConversations()) {
    final peerHex = conversation.peer.nodeId.hex;
    if (wanted != null && !wanted.contains(peerHex)) continue;
    conversations++;

    // THE CONTACT FIRST, and its status as its own key.
    //
    // A device that receives the messages of a conversation without the
    // contact behind it refuses the next message that arrives in it — the
    // consent gate has nothing to consent with. Status rides its own key
    // namespace exactly as it does live, so an alias edit and a block cannot
    // overwrite one another.
    if (!await emit(
      DeviceSyncEvent(
        kind: DeviceSyncKind.contactUp,
        key: peerHex,
        tsMs: nextFillStamp(),
        payload: Map<String, dynamic>.from(
          contactPrefsPayload(conversation.peer),
        ),
      ),
    )) {
      break;
    }
    if (!await emit(
      DeviceSyncEvent(
        kind: DeviceSyncKind.contactUp,
        key: 's:$peerHex',
        tsMs: nextFillStamp(),
        payload: {'status': conversation.peer.status.name},
      ),
    )) {
      break;
    }
    contacts++;

    if (ask.readMarks) {
      final readAt = await storage.readMarker(conversation.id);
      if (readAt > 0) {
        // The watermark IS the timestamp, as in the live emit: two devices
        // that read independently converge on the later one, which is the
        // right answer and the only one that does not un-read a conversation.
        if (!await emit(
          DeviceSyncEvent(
            kind: DeviceSyncKind.readMark,
            key: conversation.id,
            tsMs: readAt,
            payload: const {},
          ),
        )) {
          break;
        }
        readMarks++;
      }
    }

    // NEWEST FIRST when the ask is bounded. "The last fifty" means the fifty
    // the person would see on opening the chat, not the fifty from the year it
    // started — and `loadMessages` returns oldest-first, so a plain take()
    // would hand back exactly the wrong end.
    var window = await storage.loadMessages(conversation.id);
    final cap = ask.perConversation;
    if (cap != null && window.length > cap) {
      window = window.sublist(window.length - cap);
    }
    var broke = false;
    for (final message in window) {
      final mirror = deviceMirrorOf(peerHex, message, withFileBytes: ask.files);
      if (!await emit(mirror.event, attachment: mirror.attachment)) {
        broke = true;
        break;
      }
      messages++;
    }
    if (broke) break;
  }

  if (!stopped && ask.callLog) {
    for (final entry in await storage.callLogEntries()) {
      if (!await emit(
        DeviceSyncEvent(
          kind: DeviceSyncKind.callLog,
          key: entry.id,
          // A call HAS a time and it is the row's own identity, so unlike a
          // contact there is an honest "when" to carry.
          tsMs: entry.atMs,
          payload: entry.toJson(),
        ),
      )) {
        break;
      }
      calls++;
    }
  }

  return DeviceHistoryReplay(
    conversations: conversations,
    messages: messages,
    contacts: contacts,
    calls: calls,
    readMarks: readMarks,
    stoppedEarly: stopped,
  );
}
